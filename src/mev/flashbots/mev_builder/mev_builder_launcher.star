shared_utils = import_module("../../../shared_utils/shared_utils.star")
input_parser = import_module("../../../package_io/input_parser.star")
static_files = import_module("../../../static_files/static_files.star")
constants = import_module("../../../package_io/constants.star")
flashbots_relay = import_module("../mev_relay/mev_relay_launcher.star")
helix_relay = import_module("../../helix/helix_relay_launcher.star")
lighthouse = import_module("../../../cl/lighthouse/lighthouse_launcher.star")
# MEV Builder flags

MEV_BUILDER_CONFIG_FILENAME = "config.toml"
MEV_BUILDER_MOUNT_DIRPATH_ON_SERVICE = "/config/"
MEV_BUILDER_FILES_ARTIFACT_NAME = "mev-rbuilder-config"
MEV_FILE_PATH_ON_CONTAINER = (
    MEV_BUILDER_MOUNT_DIRPATH_ON_SERVICE + MEV_BUILDER_CONFIG_FILENAME
)


def new_builder_config(
    plan,
    relay_list,
    network_params,
    fee_recipient,
    mnemonic,
    mev_params,
    participants,
    global_node_selectors,
):
    """
    Generate rbuilder config file.

    Args:
        relay_list: List of relay name strings (e.g., ["flashbots"], ["flashbots", "helix"])
    """
    num_of_participants = shared_utils.zfill_custom(
        len(participants), len(str(len(participants)))
    )
    builder_template_data = new_builder_config_template_data(
        network_params,
        constants.DEFAULT_MEV_PUBKEY,
        constants.DEFAULT_MEV_SECRET_KEY[2:],  # drop the 0x prefix
        mnemonic,
        fee_recipient,
        mev_params.mev_builder_extra_data,
        num_of_participants,
        mev_params.mev_builder_subsidy,
        relay_list,
        len(participants),
    )
    flashbots_builder_config_template = read_file(
        static_files.FLASHBOTS_RBUILDER_CONFIG_FILEPATH
    )

    template_and_data = shared_utils.new_template_and_data(
        flashbots_builder_config_template, builder_template_data
    )

    template_and_data_by_rel_dest_filepath = {}
    template_and_data_by_rel_dest_filepath[
        MEV_BUILDER_CONFIG_FILENAME
    ] = template_and_data

    config_files_artifact_name = plan.render_templates(
        template_and_data_by_rel_dest_filepath, MEV_BUILDER_FILES_ARTIFACT_NAME
    )

    config_file_path = shared_utils.path_join(
        MEV_BUILDER_MOUNT_DIRPATH_ON_SERVICE, MEV_BUILDER_CONFIG_FILENAME
    )

    return config_files_artifact_name


def new_builder_config_template_data(
    network_params,
    pubkey,
    secret,
    mnemonic,
    fee_recipient,
    extra_data,
    num_of_participants,
    subsidy,
    relay_list,
    participant_count,
):
    """
    Build template data using the resolved relay list directly.

    Args:
        relay_list: List of relay name strings (e.g., ["helix", "helix"])
        participant_count: Raw participant count (int). main.star launches each
            relay service with index = participant_count + relay_index (its
            per-instance suffix), so the helix Service names below MUST use the
            SAME base to point at the real services.
    """
    relays = []
    # Mirror main.star's relay dispatch loop: relay_index increments for every
    # non-"none" relay, and each helix/flashbots/mev-rs service is launched with
    # index = participant_count + relay_index. We reuse that suffix verbatim so
    # the rbuilder Service names resolve to the actual launched services.
    relay_index = 0
    for relay_name in relay_list:
        if relay_name == "none":
            continue
        elif relay_name == "flashbots":
            relays.append(
                {
                    "Name": "flashbots",
                    "Service": "mev-relay-api",
                    "Port": flashbots_relay.MEV_RELAY_ENDPOINT_PORT,
                    "Priority": relay_index,
                }
            )
        elif relay_name == "helix":
            suffix = participant_count + relay_index
            relays.append(
                {
                    "Name": "helix-{}".format(suffix),
                    "Service": "helix-relay-{}".format(suffix),
                    "Port": helix_relay.HELIX_RELAY_ENDPOINT_PORT,
                    "Priority": relay_index,
                }
            )
        # mev-rs relay is not supported in rbuilder config (different protocol),
        # but it still consumes a relay_index slot in main.star's loop.
        relay_index += 1

    # Build enabled_relays string for the config: "relay1", "relay2"
    enabled_relays = ", ".join(['"{}"'.format(r["Name"]) for r in relays])

    return {
        "Network": network_params.network
        if network_params.network in constants.PUBLIC_NETWORKS
        else "/network-configs/genesis.json",
        "DataDir": "/data/reth/execution-data",
        "CLEndpoint": "http://cl-{0}-{1}-{2}:{3}".format(
            num_of_participants,
            constants.CL_TYPE.lighthouse,
            constants.EL_TYPE.reth_builder,
            lighthouse.BEACON_HTTP_PORT_NUM,
        ),
        "GenesisForkVersion": constants.GENESIS_FORK_VERSION,
        "Relays": relays,
        "EnabledRelays": enabled_relays,
        "PublicKey": pubkey,
        "SecretKey": secret,
        "Mnemonic": mnemonic,
        "FeeRecipient": fee_recipient,
        "ExtraData": extra_data,
        "Subsidy": subsidy,
    }
