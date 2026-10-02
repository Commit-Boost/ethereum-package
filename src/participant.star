def new_participant(
    el_type,
    cl_type,
    vc_type,
    remote_signer_type,
    el_context,
    cl_context,
    vc_context,
    remote_signer_context,
    snooper_el_engine_context,
    snooper_beacon_context,
    snooper_el_rpc_context,
    ethereum_metrics_exporter_context,
    xatu_sentry_context,
    node_keystore_files,
):
    return struct(
        el_type=el_type,
        cl_type=cl_type,
        vc_type=vc_type,
        remote_signer_type=remote_signer_type,
        el_context=el_context,
        cl_context=cl_context,
        vc_context=vc_context,
        remote_signer_context=remote_signer_context,
        snooper_el_engine_context=snooper_el_engine_context,
        snooper_beacon_context=snooper_beacon_context,
        snooper_el_rpc_context=snooper_el_rpc_context,
        ethereum_metrics_exporter_context=ethereum_metrics_exporter_context,
        xatu_sentry_context=xatu_sentry_context,
        # The participant's validator keystores (None when it has none), so a
        # service launched after the network, like the Commit-Boost signer, can
        # mount the keys the validator client uses.
        node_keystore_files=node_keystore_files,
    )
