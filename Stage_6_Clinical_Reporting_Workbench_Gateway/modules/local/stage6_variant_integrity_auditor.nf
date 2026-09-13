process STAGE6_VARIANT_INTEGRITY_AUDITOR {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    path "${meta.sample_id}.stage6_variant_integrity_audit.json", emit: integrity_audit
    path "${meta.sample_id}.stage6_variant_ledger.json", emit: variant_ledger
    tuple val(meta), path("${meta.sample_id}.stage6_variant_integrity.fragment.json"), emit: fragment

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

candidate_vus = candidates.get('candidate_vus', []) if isinstance(candidates, dict) else []
upgraded_variants = queue.get('upgraded_variants', []) if isinstance(queue, dict) else []
remaining_vus = queue.get('remaining_vus', []) if isinstance(queue, dict) else []

tiers = acmg.get('tiers', {}) if isinstance(acmg, dict) else {}
reported_variants = []
if isinstance(tiers, dict):
    for tier_name, tier_rows in tiers.items():
        if isinstance(tier_rows, list):
            for row in tier_rows:
                if isinstance(row, dict):
                    reported_variants.append({'tier': tier_name, **row})
                else:
                    reported_variants.append({'tier': tier_name, 'variant': str(row)})

reported_count = len(reported_variants)
candidate_count = len(candidate_vus)
upgraded_count = len(upgraded_variants)
remaining_count = len(remaining_vus)

ledger = {
    'node': 'STAGE6_VARIANT_INTEGRITY_AUDITOR',
    'sample_id': sid,
    'preflight_lock': reference_meta.get('preflight_lock', '') if isinstance(reference_meta, dict) else '',
    'preflight_lock_status': reference_meta.get('preflight_lock_status', '') if isinstance(reference_meta, dict) else '',
    'reported_variant_count': reported_count,
    'candidate_vus_count': candidate_count,
    'upgraded_vus_count': upgraded_count,
    'remaining_vus_count': remaining_count,
    'reported_variants': reported_variants,
    'candidate_vus': candidate_vus,
    'upgraded_variants': upgraded_variants,
    'remaining_vus': remaining_vus,
    'accounted_variant_count': reported_count + remaining_count + upgraded_count,
}
if ledger['preflight_lock_status'] and ledger['preflight_lock_status'] != 'STAGE0_PREFLIGHT_LOCK_PASS':
    raise SystemExit(f"STAGE6_PRECONDITION_FAILURE: invalid preflight_lock_status for {sid}: {ledger['preflight_lock_status']}")
Path(f'{sid}.stage6_variant_ledger.json').write_text(json.dumps(ledger, indent=2) + "\\n", encoding='utf-8')

loss = candidate_count - (upgraded_count + remaining_count)
if loss != 0:
    audit = {
        'node': 'STAGE6_VARIANT_INTEGRITY_AUDITOR',
        'sample_id': sid,
        'failure_code': 'STAGE6_VARIANT_LOSS_FAILURE',
        'reported_variant_count': reported_count,
        'candidate_vus_count': candidate_count,
        'upgraded_vus_count': upgraded_count,
        'remaining_vus_count': remaining_count,
        'variant_loss_delta': loss,
        'status': 'FAIL',
    }
    Path(f'{sid}.stage6_variant_integrity_audit.json').write_text(json.dumps(audit, indent=2) + "\\n", encoding='utf-8')
    raise SystemExit('STAGE6_VARIANT_LOSS_FAILURE: candidate VUS ledger does not reconcile with upgraded + remaining queues')

confidence = {
    'node': 'STAGE6_VARIANT_INTEGRITY_AUDITOR',
    'sample_id': sid,
    'preflight_lock': ledger['preflight_lock'],
    'preflight_lock_status': ledger['preflight_lock_status'],
    'failure_code': None,
    'reported_variant_count': reported_count,
    'candidate_vus_count': candidate_count,
    'upgraded_vus_count': upgraded_count,
    'remaining_vus_count': remaining_count,
    'variant_loss_delta': loss,
    'status': 'PASS',
}
Path(f'{sid}.stage6_variant_integrity_audit.json').write_text(json.dumps(confidence, indent=2) + "\\n", encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'variant_integrity',
    'integrity_audit': f'{sid}.stage6_variant_integrity_audit.json',
    'variant_ledger': f'{sid}.stage6_variant_ledger.json',
    'reported_variant_count': reported_count,
    'candidate_vus_count': candidate_count,
    'status': 'PASS',
}
Path(f'{sid}.stage6_variant_integrity.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE6_VARIANT_INTEGRITY_AUDITOR","sample_id":"%s","preflight_lock":"%s","preflight_lock_status":"%s","reported_variant_count":0,"candidate_vus_count":0,"upgraded_vus_count":0,"remaining_vus_count":0,"variant_loss_delta":0,"status":"PASS","stub":true}' "${meta.sample_id}" "${reference_meta.preflight_lock ?: ''}" "${reference_meta.preflight_lock_status ?: ''}" > "${meta.sample_id}.stage6_variant_integrity_audit.json"
    printf '{"node":"STAGE6_VARIANT_INTEGRITY_AUDITOR","sample_id":"%s","preflight_lock":"%s","preflight_lock_status":"%s","reported_variant_count":0,"candidate_vus_count":0,"upgraded_vus_count":0,"remaining_vus_count":0,"accounted_variant_count":0}' "${meta.sample_id}" "${reference_meta.preflight_lock ?: ''}" "${reference_meta.preflight_lock_status ?: ''}" > "${meta.sample_id}.stage6_variant_ledger.json"
    printf '{"sample_id":"%s","component":"variant_integrity","integrity_audit":"%s.stage6_variant_integrity_audit.json","variant_ledger":"%s.stage6_variant_ledger.json","reported_variant_count":0,"candidate_vus_count":0,"status":"PASS"}' "${meta.sample_id}" "${meta.sample_id}" "${meta.sample_id}" > "${meta.sample_id}.stage6_variant_integrity.fragment.json"
    """
}
