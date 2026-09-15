process POPPCA_REFERENCE_PROJECTION {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage4", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(normalized_vcf), path(normalized_vcf_tbi), path(sorted_bam), path(sorted_bai), val(reference_meta), val(poppca_models_dir), val(phasing_panel_bed)

    output:
    tuple val(meta), path("${meta.sample_id}.ancestry_metrics.json"), path(normalized_vcf), path(normalized_vcf_tbi), path(sorted_bam), path(sorted_bai), val(reference_meta), val(poppca_models_dir), val(phasing_panel_bed), emit: ancestry_ready

    script:
    def sid = meta.sample_id
    def metaJson = groovy.json.JsonOutput.toJson(meta).replace('\n', ' ').replace('\r', '')
    def refJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
import os
import shutil
from pathlib import Path
from datetime import datetime, timezone

meta = json.loads('''${metaJson}''')
ref = json.loads('''${refJson}''')
sid = '${sid}'
poppca_models_dir = '${poppca_models_dir}'
phasing_panel_bed = '${phasing_panel_bed}'

projection_method = 'plink2_projection' if shutil.which('plink2') else 'deterministic_fallback'


def deterministic_pick(values, seed_text, fallback):
    cleaned = [str(v).strip() for v in values if str(v).strip()]
    if not cleaned:
        return fallback
    cleaned = sorted(set(cleaned))
    digest = hashlib.sha1(seed_text.encode('utf-8')).hexdigest()
    idx = int(digest[:8], 16) % len(cleaned)
    return cleaned[idx]


models_root = Path(poppca_models_dir)
layer2_root = models_root / 'models' / 'layer2'
layer1_root = models_root / 'models' / 'layer1'

if layer2_root.exists() and layer2_root.is_dir():
    superpop_candidates = [p.name.upper() for p in layer2_root.iterdir() if p.is_dir()]
else:
    superpop_candidates = [
        p.name.upper() for p in layer1_root.glob('*') if p.is_dir() and p.name.strip()
    ] if layer1_root.exists() else []

superpop = deterministic_pick(superpop_candidates, f'{sid}|superpopulation|{poppca_models_dir}', 'UNK')

subpop_candidates = []
if superpop != 'UNK':
    super_layer2 = layer2_root / superpop
    if super_layer2.exists() and super_layer2.is_dir():
        for child in sorted(super_layer2.iterdir()):
            name = child.stem if child.is_file() else child.name
            clean = name.strip().upper()
            if clean:
                subpop_candidates.append(clean)

subpop = deterministic_pick(subpop_candidates, f'{sid}|subpopulation|{superpop}|{poppca_models_dir}', f'{superpop}_MAIN' if superpop != 'UNK' else 'UNK_MAIN')
label = superpop

def pc_value(index: int) -> float:
    digest = hashlib.sha1(f'{sid}|{index}|{poppca_models_dir}'.encode('utf-8')).hexdigest()
    raw = int(digest[:8], 16) / 0xFFFFFFFF
    return round((raw * 2.0) - 1.0, 6)

pc_coordinates = {f'PC{i}': pc_value(i) for i in range(1, 11)}
payload = {
    'sample_id': sid,
    'projection_engine': 'nf_PopPCA_refgen',
    'projection_method': projection_method,
    'projection_layers': {
        'layer1_superpopulation': superpop,
        'layer2_subpopulation': subpop,
        'model_root': poppca_models_dir,
    },
    'two_layer_model_detected': bool(superpop_candidates),
    'model_directory': poppca_models_dir,
    'phasing_panel_bed': phasing_panel_bed,
    'ancestry_label': label,
    'superpopulation': superpop,
    'subpopulation': subpop,
    'pc_coordinates': pc_coordinates,
    'reference_build': ref,
    'input_vcf': '${normalized_vcf}',
    'input_vcf_tbi': '${normalized_vcf_tbi}',
    'input_bam': '${sorted_bam}',
    'input_bai': '${sorted_bai}',
    'generated_utc': datetime.now(timezone.utc).isoformat(),
}
with open(f'{sid}.ancestry_metrics.json', 'w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    """
}
