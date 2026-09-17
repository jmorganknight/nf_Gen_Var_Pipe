process STAGE1_FAIL_CLOSED {

    label 'process_low'
    container 'genvar-core:2.1.0'


    input:
    path rejection_audit, stageAs: 'staged_stage1_rejection_audit.json'

    output:
    path 'stage1_rejection_audit.json'

    script:
    """
    set -euo pipefail
    cp "staged_stage1_rejection_audit.json" "stage1_rejection_audit.json"
    echo "STAGE1_PRECONDITION_FAILURE: mapped BAM header validation failed" >&2
    exit 1
    """
}
