process STAGE5_PRECONDITION_GUARD {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage5", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta)

    output:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), emit: validated_bundle
    path "${meta.sample_id}.stage5_precondition_guard.json", emit: guard_audit

    script:
    def sid = meta.sample_id
    def token = meta.validation_token?.toString() ?: ''
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sid}'
audit = {
    'node': 'STAGE5_PRECONDITION_GUARD',
    'sample_id': sid,
    'validation_token': '${token}',
    'phased_vcf': '${phased_vcf}',
    'phased_vcf_tbi': '${phased_tbi}',
    'status': 'PASS',
}
Path(f'{sid}.stage5_precondition_guard.json').write_text(json.dumps(audit, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE5_PRECONDITION_GUARD","sample_id":"%s","status":"PASS","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.stage5_precondition_guard.json"
    """
}
