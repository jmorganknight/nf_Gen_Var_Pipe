process VALIDATE_STAGE1_PRECONDITION {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    publishDir "${params.outdir}/audit_and_qc/stage2", mode: 'copy', overwrite: true, pattern: '*.stage2_precondition_audit.json'

    input:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds)

    output:
    tuple val(meta), path(bam), path(bai), val(refs), val(thresholds), path("${meta.sample_id}.stage2_precondition_audit.json"), emit: validated

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

meta = json.loads('${metaJson}')
sid = meta['sample_id']
bam_path = Path('${bam}')
bai_path = Path('${bai}')
audit_path = Path(f"{sid}.stage2_precondition_audit.json")

token_field = str(meta.get('intake_validation_token') or '').strip()
token_value = str(meta.get('intake_validation_token_value') or '').strip()
if not token_value:
    token_value = token_field
if token_field and Path(token_field).exists():
    token_value = Path(token_field).read_text(encoding='utf-8', errors='replace').strip()

valid_token = ('VALID_PASS|INTAKE_VALIDATED' in token_value) or ('VALID_PASS|ALIGNMENT_COMPLETED' in token_value)

audit = {
    'node': 'STAGE2_PRECONDITION_GUARD',
    'sample_id': sid,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'checks': {
        'stage1_token_present': bool(token_field),
        'stage1_token_valid': valid_token,
        'sorted_bam_exists': bam_path.exists(),
        'sorted_bai_exists': bai_path.exists(),
        'sorted_bam_size_bytes': bam_path.stat().st_size if bam_path.exists() else 0,
    },
    'status': 'PASS'
}

fail_reasons = []
if not audit['checks']['stage1_token_present']:
    fail_reasons.append('intake_validation_token missing')
if not audit['checks']['stage1_token_valid']:
    fail_reasons.append(f"intake_validation_token invalid: {token_value}")
if not audit['checks']['sorted_bam_exists']:
    fail_reasons.append(f"sorted BAM missing: {bam_path}")
if not audit['checks']['sorted_bai_exists']:
    fail_reasons.append(f"sorted BAI missing: {bai_path}")

if fail_reasons:
    audit['status'] = 'FAIL'
    audit['failure_code'] = 'STAGE2_PRECONDITION_FAILURE'
    audit['fail_reasons'] = fail_reasons

audit_path.write_text(json.dumps(audit, indent=2) + '\\n', encoding='utf-8')

if fail_reasons:
    print('STAGE2_PRECONDITION_FAILURE: ' + '; '.join(fail_reasons), file=sys.stderr)
    sys.exit(1)
PYEOF
    """
}
