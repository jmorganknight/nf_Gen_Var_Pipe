nextflow.enable.dsl = 2

process RUN_PGX_ENGINE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${meta?.sample_id ?: 'UNKNOWN'}"

    input:
    tuple val(meta), path(vcf)
    path thresholds_yaml
    path references_yaml
    path pgx_engine_script

    output:
    tuple val(meta), path('pgx_branch_payload.json'), emit: payload

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta ?: [:])
    def metaJsonB64 = metaJson.bytes.encodeBase64().toString()

    """
    set -euo pipefail

    python3 "${pgx_engine_script}" \
        --meta-json-b64 '${metaJsonB64}' \
        --vcf "${vcf}" \
        --thresholds "${thresholds_yaml}" \
        --references "${references_yaml}" \
        --output pgx_branch_payload.json
    """
}

workflow PGX_BRANCH_ENGINE {
    take:
    ch_branch_input
    ch_thresholds_yaml
    ch_references_yaml

    main:
    def chPgxEngineScript = channel.value(file("${projectDir}/bin/stage5_pgx_branch_engine.py"))
    RUN_PGX_ENGINE(ch_branch_input, ch_thresholds_yaml, ch_references_yaml, chPgxEngineScript)
    def chBranchOutput = RUN_PGX_ENGINE.out.payload.map { meta, payloadFile ->
        def payloadText = payloadFile.text.trim()
        def payload = new groovy.json.JsonSlurper().parseText(payloadText)
        tuple(meta, payload.summary.status.toString(), payloadText)
    }

    emit:
    branch_output = chBranchOutput
}
