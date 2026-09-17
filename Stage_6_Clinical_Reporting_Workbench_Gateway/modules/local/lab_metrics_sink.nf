process LAB_METRICS_SINK {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'copy', overwrite: true, pattern: '*.lab_metrics.json'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    tuple val(meta), path("${meta.sample_id}.lab_metrics.json"), emit: lab_metrics_json
    tuple val(meta), path("${meta.sample_id}.stage6_lab_metrics.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sid}'
acmg = json.loads(Path('${acmg_tiered_variants_json}').read_text(encoding='utf-8'))
candidates = json.loads(Path('${candidate_vus_json}').read_text(encoding='utf-8'))
queue = json.loads(Path('${vus_queue_json}').read_text(encoding='utf-8'))

sf_payload = {}
prs_payload = {}
for payload_path, target in [('${sf_artifact}', 'sf'), ('${prs_artifact}', 'prs')]:
    p = Path(payload_path)
    if p.exists():
        try:
            parsed = json.loads(p.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            parsed = {'parse_error': 'invalid_json'}
    else:
        parsed = {}
    if target == 'sf':
        sf_payload = parsed
    else:
        prs_payload = parsed

tiers = acmg.get('tiers', {}) if isinstance(acmg, dict) else {}
tier_counts = {name: len(rows) if isinstance(rows, list) else 0 for name, rows in tiers.items()} if isinstance(tiers, dict) else {}
reported_count = sum(tier_counts.values())
candidate_count = len(candidates.get('candidate_vus', [])) if isinstance(candidates, dict) else 0
upgraded_count = len(queue.get('upgraded_variants', [])) if isinstance(queue, dict) else 0
remaining_count = len(queue.get('remaining_vus', [])) if isinstance(queue, dict) else 0

payload = {
    'node': 'LAB_METRICS_SINK',
    'sample_id': sid,
    'variant_counts': {
        'reported': reported_count,
        'candidate_vus': candidate_count,
        'upgraded_vus': upgraded_count,
        'remaining_vus': remaining_count,
    },
    'tier_counts': tier_counts,
    'consent_states': {
        'secondary_findings': sf_payload.get('consent_state', 'UNKNOWN') if isinstance(sf_payload, dict) else 'UNKNOWN',
        'prs_reporting': prs_payload.get('consent_state', 'UNKNOWN') if isinstance(prs_payload, dict) else 'UNKNOWN',
    },
    'quality_flags': {
        'variant_ledger_balanced': candidate_count == (upgraded_count + remaining_count),
    },
}

Path(f'{sid}.lab_metrics.json').write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'lab_metrics_sink',
    'lab_metrics_json': str(Path(f'{sid}.lab_metrics.json').resolve()),
    'status': 'PASS',
}
Path(f'{sid}.stage6_lab_metrics.fragment.json').write_text(json.dumps(fragment, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import json
from pathlib import Path
sid = '${meta.sample_id}'
Path(f'{sid}.lab_metrics.json').write_text(json.dumps({'node': 'LAB_METRICS_SINK', 'sample_id': sid, 'status': 'PASS', 'stub': True}, indent=2) + '\\n', encoding='utf-8')
Path(f'{sid}.stage6_lab_metrics.fragment.json').write_text(json.dumps({'sample_id': sid, 'component': 'lab_metrics_sink', 'lab_metrics_json': str(Path(f'{sid}.lab_metrics.json').resolve()), 'status': 'PASS'}, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
