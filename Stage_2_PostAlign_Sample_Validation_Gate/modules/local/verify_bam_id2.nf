process VERIFYBAMID2 {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.stage2_outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true, pattern: '*.contamination_audit.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path(precondition_audit), path("${meta.sample_id}.contamination_audit.json"), emit: validated

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    def refsJson = groovy.json.JsonOutput.toJson(refs).replace('\\', '\\\\').replace("'", "\\'")
    def freemixLimit = thresholds?.clinical?.contamination?.freemix_germline_limit ?: 0.01
    def failClosed = thresholds?.stage2?.contamination_fail_closed != null ? thresholds.stage2.contamination_fail_closed : true
    def nonEvaluableFailClosed = thresholds?.stage2?.contamination_non_evaluable_fail_closed != null ? thresholds.stage2.contamination_non_evaluable_fail_closed : true
    def runMode = (meta?.run_mode ?: 'production').toString()
    "python3 ${workflow.projectDir}/bin/verify_bam_id2_audit.py --meta-json '${metaJson}' --refs-json '${refsJson}' --bam '${bam}' --precondition-audit '${precondition_audit}' --limit ${freemixLimit} --run-mode '${runMode}' --fail-closed ${failClosed} --non-evaluable-fail-closed ${nonEvaluableFailClosed}"

    stub:
    """
    cat > "${meta.sample_id}.contamination_audit.json" <<'JSON'
{
    "node": "VERIFYBAMID2",
    "sample_id": "${meta.sample_id}",
    "run_mode": "${meta.run_mode ?: 'production'}",
    "status": "PASS",
    "method": "VerifyBamID2",
    "sample_type": "${meta.sample_type ?: 'germline'}",
    "contamination_rate": 0.0025,
    "contamination_limit": 0.01,
    "fail_closed_rule": "STAGE2_CONTAMINATION_FAILURE when contamination_rate > 0.01",
    "stub": true
}
JSON
    """
}
