process DOWNGRADED_VARIANT_SINK {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'rellink', overwrite: true, pattern: '*.json.gz'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    path 'downgraded_variants_sink.json.gz', emit: sink_archive
    tuple val(meta), path("${meta.sample_id}.stage6_downgraded_sink.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import gzip
import json
from pathlib import Path

sid = '${sid}'
acmg = json.loads(Path('${acmg_tiered_variants_json}').read_text(encoding='utf-8'))
candidates = json.loads(Path('${candidate_vus_json}').read_text(encoding='utf-8'))
queue = json.loads(Path('${vus_queue_json}').read_text(encoding='utf-8'))

reported = []
for tier_name, tier_rows in (acmg.get('tiers', {}) if isinstance(acmg, dict) else {}).items():
    if isinstance(tier_rows, list):
        for row in tier_rows:
            if isinstance(row, dict):
                reported.append({'tier': tier_name, **row})

remaining = queue.get('remaining_vus', []) if isinstance(queue, dict) else []
upgraded = queue.get('upgraded_variants', []) if isinstance(queue, dict) else []
all_candidates = candidates.get('candidate_vus', []) if isinstance(candidates, dict) else []

archive = []
for idx, variant in enumerate(all_candidates):
    if not isinstance(variant, dict):
        archive.append({
            'variant': str(variant),
            'suppression_reason_code': 'UNKNOWN_TRIAGE_RECORD',
            'archived_index': idx,
        })
        continue
    maf = float(variant.get('maf', variant.get('population_af', 0.0)) or 0.0)
    if variant.get('off_target', False):
        reason = 'OFF_TARGET_VARIANT'
    elif maf >= 0.01:
        reason = 'HIGH_MAF_BENIGN'
    elif variant.get('suppressed', False):
        reason = variant.get('suppression_reason_code', 'SUPPRESSED_VARIANT')
    elif variant.get('status') == 'DOWNGRADED':
        reason = variant.get('suppression_reason_code', 'DOWNGRADED_VARIANT')
    else:
        reason = 'TRIAGE_ARCHIVE_ONLY'
    archive.append({
        'variant': variant.get('variant', f'candidate_{idx}'),
        'gene': variant.get('gene'),
        'chrom': variant.get('chrom'),
        'pos': variant.get('pos'),
        'ref': variant.get('ref'),
        'alt': variant.get('alt'),
        'suppression_reason_code': reason,
        'maf': maf,
        'source_state': variant.get('status', 'CANDIDATE'),
    })

payload = {
    'node': 'DOWNGRADED_VARIANT_SINK',
    'sample_id': sid,
    'archive_count': len(archive),
    'archive': archive,
    'reported_variant_count': len(reported),
    'remaining_vus_count': len(remaining),
    'upgraded_vus_count': len(upgraded),
}
with gzip.open('downgraded_variants_sink.json.gz', 'wt', encoding='utf-8') as handle:
    handle.write(json.dumps(payload, indent=2) + "\\n")
fragment = {
    'sample_id': sid,
    'component': 'downgraded_sink',
    'sink_archive': 'downgraded_variants_sink.json.gz',
    'archive_count': len(archive),
    'status': 'PASS',
}
Path(f'{sid}.stage6_downgraded_sink.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import gzip, json
from pathlib import Path
sid = '${meta.sample_id}'
payload = {'node':'DOWNGRADED_VARIANT_SINK','sample_id':sid,'archive_count':0,'archive':[]}
with gzip.open('downgraded_variants_sink.json.gz', 'wt', encoding='utf-8') as handle:
    handle.write(json.dumps(payload, indent=2) + '\\n')
Path(f'{sid}.stage6_downgraded_sink.fragment.json').write_text(json.dumps({'sample_id': sid, 'component': 'downgraded_sink', 'sink_archive': 'downgraded_variants_sink.json.gz', 'archive_count': 0, 'status': 'PASS'}, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
