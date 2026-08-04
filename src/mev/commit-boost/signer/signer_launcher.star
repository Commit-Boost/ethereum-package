shared_utils = import_module("../../../shared_utils/shared_utils.star")
constants = import_module("../../../package_io/constants.star")
static_files = import_module("../../../static_files/static_files.star")

# Where the validator-keystore artifact is mounted. We consume the TEKU
# sub-directories, NOT the lighthouse `keys/` + `secrets/` pair: the keystore
# generator runs `chmod 0600 -R secrets`, which strips the execute bit from the
# DIRECTORY, and Kurtosis does not chown files-artifacts on mount. The
# commit-boost image runs as uid 10001, so it cannot traverse `secrets/` and CB's
# loader (a `filter_map` + `warn!`) would silently load ZERO keys while the
# process stayed healthy. Verified live on an enclave:
#   secrets       600 root:root  drw-------
#   teku-secrets  755 root:root  drwxr-xr-x
#   teku-keys     777 root:root  drwxrwxrwx
# This is also the pair the package's own web3signer launcher already relies on.
SIGNER_KEYS_MOUNTPOINT = "/keystores"
SIGNER_CONFIG_MOUNTPOINT = "/config"
SIGNER_CONFIG_FILENAME = "cb-config.toml"

SIGNER_PORT_NUM = 20000
SIGNER_PORT_ID = "signer"
SIGNER_METRICS_PORT_NUM = 9091
SIGNER_METRICS_PORT_ID = "metrics"

# A `wait` on the port turns the silent-exit class into a LOUD `kurtosis run`
# failure: with an empty `modules` list the signer logs a warning and returns
# Ok(()) BEFORE binding the listener, so the container exits 0 and Kurtosis would
# otherwise read that as a clean shutdown rather than a failure.
SIGNER_USED_PORTS = {
    SIGNER_PORT_ID: shared_utils.new_port_spec(
        SIGNER_PORT_NUM,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
        wait="30s",
    ),
    SIGNER_METRICS_PORT_ID: shared_utils.new_port_spec(
        SIGNER_METRICS_PORT_NUM,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    ),
}

MIN_CPU = 10
MAX_CPU = 500
MIN_MEMORY = 16
MAX_MEMORY = 512

# Fixed devnet secrets. NOT security-sensitive: this is a throwaway devnet whose
# validator keys come from a published mnemonic. Fixed values keep the harness's
# JWT minting reproducible.
DEFAULT_MODULE_ID = "TEST_MODULE"
DEFAULT_MODULE_JWT = "b3d1f5a4c8e2079b6d4f1a3c5e7b9d2f"
DEFAULT_ADMIN_JWT = "a1c3e5f7b9d2468ace0213579bdf4680"


def launch(
    plan,
    service_name,
    mev_params,
    node_keystore_files,
    el_cl_genesis_data,
    final_genesis_timestamp,
    network,
    relay_endpoints,
    node_selectors,
    index,
):
    """Launch a Commit-Boost SIGNER container.

    Renders its own copy of the CB config from the same template the PBS sidecar
    uses, so no artifact has to be threaded between launchers. The rendered text
    is identical; only the mount target differs.
    """
    if node_keystore_files == None:
        # No validator keys for this participant (validator_count == 0) - there
        # is nothing for a signer to load, so do not launch one.
        return None

    config_artifact = _render_config(
        plan,
        service_name,
        mev_params,
        network,
        relay_endpoints,
        final_genesis_timestamp,
    )

    keys_dir = shared_utils.path_join(
        SIGNER_KEYS_MOUNTPOINT, node_keystore_files.teku_keys_relative_dirpath
    )
    secrets_dir = shared_utils.path_join(
        SIGNER_KEYS_MOUNTPOINT, node_keystore_files.teku_secrets_relative_dirpath
    )

    config = ServiceConfig(
        image=mev_params.mev_boost_image,
        # The image's own CMD is ["pbs"]; the ENTRYPOINT stays
        # /usr/local/bin/commit-boost. Overriding cmd is how the same image
        # becomes the signer - exactly what CB's compose generator does.
        cmd=["signer"],
        ports=SIGNER_USED_PORTS,
        files={
            SIGNER_CONFIG_MOUNTPOINT: config_artifact,
            constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS: el_cl_genesis_data.files_artifact_uuid,
            SIGNER_KEYS_MOUNTPOINT: node_keystore_files.files_artifact_uuid,
        },
        env_vars={
            "CB_CONFIG": shared_utils.path_join(
                SIGNER_CONFIG_MOUNTPOINT, SIGNER_CONFIG_FILENAME
            ),
            # module_id=secret pairs. Every id here MUST have a matching
            # [[modules]] entry in the config or startup fails.
            "CB_JWTS": "{0}={1}".format(DEFAULT_MODULE_ID, DEFAULT_MODULE_JWT),
            # Required even though the harness never calls the admin routes.
            "CB_SIGNER_ADMIN_JWT": DEFAULT_ADMIN_JWT,
            # THE DEVNET TRAP: [signer].host defaults to 127.0.0.1, which is
            # unreachable from another container. Bind the unspecified address.
            "CB_SIGNER_ENDPOINT": "0.0.0.0:{0}".format(SIGNER_PORT_NUM),
            # These OVERRIDE the config's placeholder paths. They have to be env
            # vars: the paths are per-participant (node-<idx>-keystores/...) and
            # the config template only carries .Network/.Port/.Relays/.Timestamp.
            "CB_SIGNER_LOADER_KEYS_DIR": keys_dir,
            "CB_SIGNER_LOADER_SECRETS_DIR": secrets_dir,
            "CB_METRICS_PORT": str(SIGNER_METRICS_PORT_NUM),
            # Default is 300s. Three wrong-secret negative probes would otherwise
            # rate-limit the harness's own source IP for five minutes and poison
            # every positive assertion that follows.
            "CB_SIGNER_JWT_AUTH_FAIL_TIMEOUT_SECONDS": "5",
        },
        min_cpu=MIN_CPU,
        max_cpu=MAX_CPU,
        min_memory=MIN_MEMORY,
        max_memory=MAX_MEMORY,
        node_selectors=node_selectors,
    )

    signer_service = plan.add_service(service_name, config)

    return struct(
        service_name=signer_service.name,
        ip_addr=signer_service.ip_address,
        port=SIGNER_PORT_NUM,
        url="http://{0}:{1}".format(signer_service.name, SIGNER_PORT_NUM),
        module_id=DEFAULT_MODULE_ID,
        module_jwt=DEFAULT_MODULE_JWT,
    )


def _render_config(
    plan, service_name, mev_params, network, relay_endpoints, final_genesis_timestamp
):
    """Render the CB config for this signer from the same template PBS uses."""
    template = mev_params.commit_boost_config
    if template == None or template == "":
        template = read_file(static_files.COMMIT_BOOST_CONFIG_FILEPATH)

    template_data = {
        "Network": network
        if network in constants.PUBLIC_NETWORKS
        else "/network-configs/config.yaml",
        "Port": SIGNER_PORT_NUM,
        "Relays": relay_endpoints,
        "Timestamp": final_genesis_timestamp,
    }

    return plan.render_templates(
        {
            SIGNER_CONFIG_FILENAME: shared_utils.new_template_and_data(
                template, template_data
            )
        },
        "cb-signer-config-" + service_name,
    )
