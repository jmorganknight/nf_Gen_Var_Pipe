process STAGE6_WETLAB_CONFIRMATION_GATE {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'rellink', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(stage5_manifest), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    path 'wetlab_confirmation_pending_queue.json', emit: pending_queue
    tuple val(meta), path("${meta.sample_id}.stage6_wetlab_confirmation.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sid}'
acmg = json.loads(Path('${acmg_tiered_variants_json}').read_text(encoding='utf-8'))
queue = json.loads(Path('${vus_queue_json}').read_text(encoding='utf-8'))

pending = []
for tier_name, tier_rows in (acmg.get('tiers', {}) if isinstance(acmg, dict) else {}).items():
    if not isinstance(tier_rows, list):
        continue
    for row in tier_rows:
        if not isinstance(row, dict):
            continue
        vaf = float(row.get('vaf', 1.0) or 1.0)
        dp = float(row.get('dp', 999.0) or 999.0)
        indel_size = abs(int(row.get('indel_size_bp', row.get('indel_size', 0)) or 0))
        homopolymer = bool(row.get('homopolymer', False))
        phased = row.get('phasing_state', row.get('phase_state', 'PHASED'))
        compound_het = bool(row.get('compound_het', False))
        gene = (row.get('gene') or row.get('symbol') or '').upper()
        pseudogene_region = gene in {'CYP2D6', 'PMS2'} or bool(row.get('pseudogene_region', False))

        reasons = []
        if vaf < 0.20:
            reasons.append('VAF_BELOW_0.20')
        if dp < 30:
            reasons.append('DEPTH_BELOW_30X')
        if indel_size > 15:
            reasons.append('INDEL_EXCEEDS_15_BP')
        if homopolymer:
            reasons.append('HOMOPOLYMER_CONTEXT')
        if compound_het and str(phased).upper() != 'PHASED':
            reasons.append('UNPHASED_COMPOUND_HET')
        if pseudogene_region:
            reasons.append('PSEUDOGENE_REGION')

        if reasons:
            pending.append({
                'variant': row.get('variant', f"{row.get('chrom','?')}:{row.get('pos','?')}") ,
                'gene': row.get('gene'),
                'chrom': row.get('chrom'),
                'pos': row.get('pos'),
                'vaf': vaf,
                'dp': dp,
                'reasons': reasons,
                'action': 'SANGER_OR_MLPA_CONFIRMATION_PENDING',
            })

payload = {
    'node': 'STAGE6_WETLAB_CONFIRMATION_GATE',
    'sample_id': sid,
    'pending_confirmation_count': len(pending),
    'pending_variants': pending,
}
Path('wetlab_confirmation_pending_queue.json').write_text(json.dumps(payload, indent=2) + "\\n", encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'wetlab_confirmation',
    'pending_queue': 'wetlab_confirmation_pending_queue.json',
    'pending_confirmation_count': len(pending),
    'status': 'PASS',
}
Path(f'{sid}.stage6_wetlab_confirmation.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"STAGE6_WETLAB_CONFIRMATION_GATE","sample_id":"%s","pending_confirmation_count":0,"pending_variants":[]}' "${meta.sample_id}" > wetlab_confirmation_pending_queue.json
    printf '{"sample_id":"%s","component":"wetlab_confirmation","pending_queue":"wetlab_confirmation_pending_queue.json","pending_confirmation_count":0,"status":"PASS"}' "${meta.sample_id}" > "${meta.sample_id}.stage6_wetlab_confirmation.fragment.json"
    """
}
