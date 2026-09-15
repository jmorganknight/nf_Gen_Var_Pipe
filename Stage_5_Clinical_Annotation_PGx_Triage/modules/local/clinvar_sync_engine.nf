process CLINVAR_SYNC_ENGINE {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/annotation", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path(router_json)

    output:
    tuple val(meta), path("${meta.sample_id}.clinvar_2star_assertions.json"), emit: clinvar_payload

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import gzip
import json
from pathlib import Path


def parse_info_map(info_text: str) -> dict:
    info = {}
    for item in info_text.split(';'):
        token = item.strip()
        if not token:
            continue
        if '=' in token:
            key, value = token.split('=', 1)
            info[key] = value
        else:
            info[token] = True
    return info


def map_stars(review_status: str) -> int:
    text = (review_status or '').lower()
    if 'practice guideline' in text:
        return 4
    if 'reviewed by expert panel' in text:
        return 3
    if 'multiple submitters' in text and 'no conflicts' in text:
        return 2
    if 'single submitter' in text:
        return 1
    return 0

sid = '${sid}'
phased = Path('${phased_vcf}')
assertions = []
with gzip.open(phased, 'rt', encoding='utf-8') as handle:
    for raw in handle:
        if raw.startswith('#'):
            continue
        parts = raw.rstrip().split('\t')
        if len(parts) < 8:
            continue
        chrom, pos, _vid, ref, alt, _qual, _flt, info_text = parts[:8]
        info = parse_info_map(info_text)
        clin_sig = info.get('CLNSIG') or info.get('CLIN_SIG') or 'NONE'
        review = info.get('CLNREVSTAT') or info.get('CLINVAR_REVIEW_STATUS') or ''
        stars = map_stars(review)
        assertions.append({
            'variant': f'{chrom}:{pos}:{ref}:{alt}',
            'stars': stars,
            'assertion': str(clin_sig).split(',')[0],
            'review_status': review,
        })

Path(f'{sid}.clinvar_2star_assertions.json').write_text(json.dumps({
    'node': 'CLINVAR_SYNC_ENGINE',
    'sample_id': sid,
    'star_floor': 2,
    'assertions': assertions,
}, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    """
    printf '{"node":"CLINVAR_SYNC_ENGINE","sample_id":"%s","star_floor":2,"assertions":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.clinvar_2star_assertions.json"
    """
}
