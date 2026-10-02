def new_mev_boost_context(private_ip_address, port, config_files_artifact):
    return struct(
        private_ip_address=private_ip_address,
        port=port,
        # The rendered /config artifact, so a signer can mount the same config.
        config_files_artifact=config_files_artifact,
    )


def mev_boost_endpoint(mev_boost_context):
    return "http://{0}:{1}".format(
        mev_boost_context.private_ip_address, mev_boost_context.port
    )
