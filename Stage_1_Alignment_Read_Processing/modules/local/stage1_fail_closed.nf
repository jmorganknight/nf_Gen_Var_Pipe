process STAGE1_FAIL_CLOSED {

    label 'process_low'
    container 'genvar-core:2.1.0'

    publishDir "${params.outdir}/audit_and_qc/stage1", mode: 'copy', overwrite: true

    input:
    path rejection_audit, stageAs: 'staged_stage1_rejection_audit.json'

    output:
    path 'stage1_rejection_audit.json'

    script:
    """
    set -euo pipefail
    mkdir -p "${params.outdir}/audit_and_qc/stage1"
    cp "staged_stage1_rejection_audit.json" "${params.outdir}/audit_and_qc/stage1/stage1_rejection_audit.json"
    echo "STAGE1_PRECONDITION_FAILURE: mapped BAM header validation failed" >&2
    exit 1
    """
}
