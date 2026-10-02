shared_utils = import_module("../../../shared_utils/shared_utils.star")
constants = import_module("../../../package_io/constants.star")

SIGNER_CONFIG_MOUNTPOINT = "/config"
SIGNER_CONFIG_FILENAME = "cb-config.toml"
# The validator keystores are mounted here, and the signer loads the TEKU
# sub-directories rather than the raw `keys/` + `secrets/` pair: the keystore
# generator runs `chmod 0600 -R` on `secrets/`, which strips the execute bit from
# the directory itself, and files artifacts keep root ownership on mount. The
# commit-boost image runs as uid 10001, cannot traverse `secrets/`, and its
# loader skips unreadable keystores with a warning, so the signer would come up
# healthy holding zero keys. `teku-keys` and `teku-secrets` are world-readable.
SIGNER_KEYS_MOUNTPOINT = "/keystores"

SIGNER_PORT_NUM = 20000
SIGNER_PORT_ID = "signer"
SIGNER_METRICS_PORT_NUM = 9091
SIGNER_METRICS_PORT_ID = "metrics"

# The wait makes a signer that never binds fail the run: with no [[modules]] in
# the config, commit-boost logs a warning and exits 0 before it listens.
USED_PORTS = {
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

# Fixed devnet credentials, so a test harness can mint module JWTs without
# reading them back from the enclave. The config must declare a [[modules]]
# entry with this id, or the signer refuses to start.
DEFAULT_MODULE_ID = "TEST_MODULE"
DEFAULT_MODULE_JWT = "b3d1f5a4c8e2079b6d4f1a3c5e7b9d2f"
DEFAULT_ADMIN_JWT = "a1c3e5f7b9d2468ace0213579bdf4680"


def launch(
    plan,
    service_name,
    mev_params,
    config_files_artifact,
    node_keystore_files,
    el_cl_genesis_data,
    index,
    global_node_selectors,
    global_tolerations,
):
    """Launch a Commit-Boost signer that holds one participant's validator keys.

    It runs the PBS sidecar's image with the `signer` subcommand and mounts the
    sidecar's own rendered config, so both read the same file. The config is
    expected to carry the [signer] and [[modules]] sections.
    """
    if node_keystore_files == None:
        # No validator keys for this participant, so nothing for a signer to load.
        return None

    tolerations = shared_utils.get_tolerations(global_tolerations=global_tolerations)

    config = ServiceConfig(
        image=mev_params.mev_boost_image,
        # The image's entrypoint is the commit-boost binary and its default
        # command is `pbs`.
        cmd=["signer"],
        ports=USED_PORTS,
        files={
            SIGNER_CONFIG_MOUNTPOINT: config_files_artifact,
            constants.GENESIS_DATA_MOUNTPOINT_ON_CLIENTS: el_cl_genesis_data,
            SIGNER_KEYS_MOUNTPOINT: node_keystore_files.files_artifact_uuid,
        },
        env_vars={
            "CB_CONFIG": shared_utils.path_join(
                SIGNER_CONFIG_MOUNTPOINT, SIGNER_CONFIG_FILENAME
            ),
            "CB_JWTS": "{0}={1}".format(DEFAULT_MODULE_ID, DEFAULT_MODULE_JWT),
            "CB_SIGNER_ADMIN_JWT": DEFAULT_ADMIN_JWT,
            # [signer].host defaults to 127.0.0.1, unreachable from other services.
            "CB_SIGNER_ENDPOINT": "0.0.0.0:{0}".format(SIGNER_PORT_NUM),
            # The key paths are per participant, so they override the config's.
            "CB_SIGNER_LOADER_KEYS_DIR": shared_utils.path_join(
                SIGNER_KEYS_MOUNTPOINT, node_keystore_files.teku_keys_relative_dirpath
            ),
            "CB_SIGNER_LOADER_SECRETS_DIR": shared_utils.path_join(
                SIGNER_KEYS_MOUNTPOINT,
                node_keystore_files.teku_secrets_relative_dirpath,
            ),
            "CB_METRICS_PORT": str(SIGNER_METRICS_PORT_NUM),
            # The default lockout is 300s; a few failed auth attempts from a test
            # client would otherwise block its address for five minutes.
            "CB_SIGNER_JWT_AUTH_FAIL_TIMEOUT_SECONDS": "5",
        },
        min_cpu=MIN_CPU,
        max_cpu=MAX_CPU,
        min_memory=MIN_MEMORY,
        max_memory=MAX_MEMORY,
        node_selectors=global_node_selectors,
        tolerations=tolerations,
        labels={constants.NODE_INDEX_LABEL_KEY: str(index + 1)},
    )

    signer_service = plan.add_service(service_name, config)

    return struct(
        service_name=signer_service.name,
        url="http://{0}:{1}".format(signer_service.name, SIGNER_PORT_NUM),
        module_id=DEFAULT_MODULE_ID,
        module_jwt=DEFAULT_MODULE_JWT,
    )
