nextflow.enable.dsl = 2

process RUN_SF_ENGINE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${meta?.sample_id ?: 'UNKNOWN'}"

    input:
    tuple val(meta), path(vcf)
    path thresholds_yaml
    path references_yaml
    path references_validated_signal
    path sf_engine_script

    output:
    tuple val(meta), path('sf_branch_payload.json'), emit: payload

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta ?: [:])
    def metaJsonB64 = metaJson.bytes.encodeBase64().toString()

    """
    set -euo pipefail

    python3 "${sf_engine_script}" \
        --meta-json-b64 '${metaJsonB64}' \
        --vcf "${vcf}" \
        --thresholds "${thresholds_yaml}" \
        --references "${references_yaml}" \
        --output sf_branch_payload.json
    """
}

workflow SF_BRANCH_ENGINE {
    take:
    ch_branch_input
    ch_thresholds_yaml
    ch_references_yaml
    ch_references_validated

    main:
    def chSfEngineScript = channel.value(file("${projectDir}/bin/stage5_sf_branch_engine.py"))
    RUN_SF_ENGINE(ch_branch_input, ch_thresholds_yaml, ch_references_yaml, ch_references_validated, chSfEngineScript)
    def chBranchOutput = RUN_SF_ENGINE.out.payload.map { meta, payloadFile ->
        def payloadText = payloadFile.text.trim()
        def payload = new groovy.json.JsonSlurper().parseText(payloadText)
        tuple(meta, payload.summary.status.toString(), payloadText)
    }

    emit:
    branch_output = chBranchOutput
}
