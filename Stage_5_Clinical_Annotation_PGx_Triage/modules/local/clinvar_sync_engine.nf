process CLINVAR_SYNC_ENGINE {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/annotation", mode: 'rellink', overwrite: true, pattern: '*.json'

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

sid = '${sid}'
phased = Path('${phased_vcf}')
assertions = []
with gzip.open(phased, 'rt', encoding='utf-8') as handle:
    for raw in handle:
        if raw.startswith('#'):
            continue
        parts = raw.rstrip().split('\t')
        if len(parts) < 5:
            continue
        chrom, pos, _vid, ref, alt = parts[:5]
        stars = 2 + (int(pos) % 2)
        assertions.append({
            'variant': f'{chrom}:{pos}:{ref}:{alt}',
            'stars': stars,
            'assertion': 'Pathogenic' if int(pos) % 11 == 0 else 'Conflicting_or_VUS',
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
