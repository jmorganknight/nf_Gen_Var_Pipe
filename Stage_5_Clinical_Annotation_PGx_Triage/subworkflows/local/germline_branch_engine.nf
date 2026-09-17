nextflow.enable.dsl = 2

String stage5DockerReferenceBind() {
    def root = stage5ReferenceRoot()
    root ? "-v \"${root}:${root}:ro\"" : ''
}

String stage5ReferenceRoot() {
    def direct = [params.reference_mount_root, params.ref_dir, params.ref_data_root, System.getenv('NXF_REF_DATA_ROOT')]
        .collect { value -> value?.toString()?.trim() }
        .find { value -> value }
    if (direct) {
        return direct
    }

    def referencesPath = params.references?.toString()?.trim()
    if (!referencesPath) {
        return ''
    }

    def refsFile = new File(referencesPath)
    if (!refsFile.isAbsolute()) {
        refsFile = new File(projectDir.toString(), referencesPath)
    }
    if (!refsFile.exists()) {
        return ''
    }

    def refsDoc = new groovy.yaml.YamlSlurper().parse(refsFile)
    return refsDoc?.ref_data_root?.toString()?.trim() ?: ''
}

process RUN_GERMLINE_ENGINE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    containerOptions { stage5DockerReferenceBind() }
    stageInMode 'copy'
    tag "${meta?.sample_id ?: 'UNKNOWN'}"

    input:
    tuple val(meta), path(vcf)
    path thresholds_yaml
    path references_yaml
    path germline_engine_script

    output:
    tuple val(meta), path('germline_branch_payload.json'), emit: payload

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta ?: [:])
    def metaJsonB64 = metaJson.bytes.encodeBase64().toString()

    """
    set -euo pipefail

    python3 "${germline_engine_script}" \
        --meta-json-b64 '${metaJsonB64}' \
        --vcf "${vcf}" \
        --thresholds "${thresholds_yaml}" \
        --references "${references_yaml}" \
        --output germline_branch_payload.json
    """
}

workflow GERMLINE_BRANCH_ENGINE {
    take:
    ch_branch_input
    ch_thresholds_yaml
    ch_references_yaml

    main:
    def chGermlineEngineScript = channel.value(file("${projectDir}/bin/stage5_germline_branch_engine.py"))
    RUN_GERMLINE_ENGINE(ch_branch_input, ch_thresholds_yaml, ch_references_yaml, chGermlineEngineScript)
    def chBranchOutput = RUN_GERMLINE_ENGINE.out.payload.map { meta, payloadFile ->
        def payloadText = payloadFile.text.trim()
        def payload = new groovy.json.JsonSlurper().parseText(payloadText)
        tuple(meta, payload.summary.status.toString(), payloadText)
    }

    emit:
    branch_output = chBranchOutput
}
