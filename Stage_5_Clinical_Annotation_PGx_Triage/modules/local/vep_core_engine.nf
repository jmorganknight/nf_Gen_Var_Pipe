process VEP_CORE_ENGINE {

    label 'process_medium'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/annotation", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path(router_json), path(translate_vep_to_acmg_script)

    output:
    tuple val(meta), path("${meta.sample_id}.vep_core_annotations.json"), path("${meta.sample_id}.vep_to_acmg_rules.json"), emit: annotation_bundle

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


def first_float(values):
    for raw in values:
        if raw is None:
            continue
        text = str(raw).strip()
        if not text or text == '.':
            continue
        for piece in text.split(','):
            piece = piece.strip()
            if not piece or piece == '.':
                continue
            try:
                return float(piece)
            except ValueError:
                continue
    return None

sid = '${sid}'
phased = Path('${phased_vcf}')
router = json.loads(Path('${router_json}').read_text(encoding='utf-8'))
rows = []
with gzip.open(phased, 'rt', encoding='utf-8') as handle:
    for raw in handle:
        if raw.startswith('#'):
            continue
        parts = raw.rstrip().split('\t')
        if len(parts) < 8:
            continue
        chrom, pos, _vid, ref, alt, qual, _flt, info_text = parts[:8]
        info = parse_info_map(info_text)
        rows.append({
            'variant': f'{chrom}:{pos}:{ref}:{alt}',
            'cadd_phred': first_float([info.get('CADD'), info.get('CADD_PHRED')]),
            'revel': first_float([info.get('REVEL')]),
            'alphamissense': first_float([info.get('AlphaMissense'), info.get('ALPHAMISSENSE')]),
            'pangolin': first_float([info.get('Pangolin'), info.get('SpliceAI'), info.get('SPLICEAI')]),
            'consequence': (info.get('CSQ') or info.get('ANN') or info.get('Consequence') or '').split(',')[0],
            'qual': 0.0 if qual in ('.', '') else float(qual),
        })

Path(f'{sid}.vep_core_annotations.json').write_text(json.dumps({
    'node': 'VEP_CORE_ENGINE',
    'annotation_engine_version': 'stage5-vep-evidence-v1',
    'sample_id': sid,
    'plugins': ['CADD_v1.7', 'REVEL_v1.3', 'AlphaMissense', 'Pangolin'],
    'router_warnings': router.get('warnings', []),
    'annotations': rows,
}, indent=2) + "\\n", encoding='utf-8')
PYEOF

    python3 "${translate_vep_to_acmg_script}" --vcf "${phased_vcf}" --sample-id "${sid}" --out "${sid}.vep_to_acmg_rules.json"
    """

    stub:
    """
    printf '{"node":"VEP_CORE_ENGINE","sample_id":"%s","plugins":["stub"],"annotations":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.vep_core_annotations.json"
    printf '{"node":"translate_vep_to_acmg.py","sample_id":"%s","records":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.vep_to_acmg_rules.json"
    """
}
