process MEDICAL_DIRECTOR_WORKBENCH_GATEWAY {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(stage5_manifest), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    path 'medical_director_workbench_signoff.json', emit: signoff
    tuple val(meta), path("${meta.sample_id}.stage6_workbench.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path

sid = '${sid}'
queue = json.loads(Path('${vus_queue_json}').read_text(encoding='utf-8'))
acmg = json.loads(Path('${acmg_tiered_variants_json}').read_text(encoding='utf-8'))
candidate_payload = json.loads(Path('${candidate_vus_json}').read_text(encoding='utf-8'))

candidate_count = len(candidate_payload.get('candidate_vus', [])) if isinstance(candidate_payload, dict) else 0
reported_count = sum(len(v) for v in (acmg.get('tiers', {}) if isinstance(acmg, dict) else {}).values() if isinstance(v, list))
remaining_count = len(queue.get('remaining_vus', [])) if isinstance(queue, dict) else 0
upgraded_count = len(queue.get('upgraded_variants', [])) if isinstance(queue, dict) else 0

manual_overrides = []
sanger_inputs = []
digital_signatures = []

summary_seed = json.dumps({
    'sample_id': sid,
    'candidate_vus_count': candidate_count,
    'upgraded_vus_count': upgraded_count,
    'remaining_vus_count': remaining_count,
    'reported_variant_count': reported_count,
}, sort_keys=True)

digest = hashlib.sha256(summary_seed.encode('utf-8')).hexdigest()

payload = {
    'node': 'MEDICAL_DIRECTOR_WORKBENCH_GATEWAY',
    'sample_id': sid,
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'manual_variant_overrides': manual_overrides,
    'sanger_confirmation_inputs': sanger_inputs,
    'digital_signatures': digital_signatures,
    'approval_digest': digest,
    'workflow_gate': 'STAGE6_CLINICAL_WORKBENCH',
}
Path('medical_director_workbench_signoff.json').write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'workbench_gateway',
    'signoff': 'medical_director_workbench_signoff.json',
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'candidate_vus_count': candidate_count,
    'reported_variant_count': reported_count,
    'status': 'PASS',
}
Path(f'{sid}.stage6_workbench.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import hashlib, json
from pathlib import Path
sid = '${meta.sample_id}'
payload = {
    'node': 'MEDICAL_DIRECTOR_WORKBENCH_GATEWAY',
    'sample_id': sid,
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'manual_variant_overrides': [],
    'sanger_confirmation_inputs': [],
    'digital_signatures': [],
    'approval_digest': hashlib.sha256(sid.encode('utf-8')).hexdigest(),
    'workflow_gate': 'STAGE6_CLINICAL_WORKBENCH',
}
Path('medical_director_workbench_signoff.json').write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
Path(f'{sid}.stage6_workbench.fragment.json').write_text(json.dumps({'sample_id': sid, 'component': 'workbench_gateway', 'signoff': 'medical_director_workbench_signoff.json', 'signoff_status': 'PENDING_DIRECTOR_REVIEW', 'status': 'PASS'}, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
