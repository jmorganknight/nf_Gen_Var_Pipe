nextflow.enable.dsl = 2

include { POPPCA_REFERENCE_PROJECTION } from '../../modules/local/poppca_reference_projection.nf'

process STAGE4_ANCESTRY_LOAD_WEIGHTS {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    tag "${meta.sample_id}"

    input:
    tuple val(meta), path(ancestry_metrics_json), path(normalized_vcf), path(normalized_vcf_tbi), path(sorted_bam), path(sorted_bai), val(reference_meta), val(poppca_models_dir), val(phasing_panel_bed)

    output:
    tuple val(meta), path("${meta.sample_id}.ancestry_load_weights.json"), emit: weights

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import glob
import json
from pathlib import Path

sid = '${sid}'
models_dir = Path('${poppca_models_dir}')
reference_files = {
    'bed': sorted(glob.glob(str(models_dir / '**/*.bed'), recursive=True)),
    'bim': sorted(glob.glob(str(models_dir / '**/*.bim'), recursive=True)),
    'fam': sorted(glob.glob(str(models_dir / '**/*.fam'), recursive=True)),
}
payload = {
    'sample_id': sid,
    'projection_engine': 'nf_PopPCA_refgen',
    'reference_matrices': reference_files,
    'variant_load_weighting': {
        'layer1_variant_count': len(reference_files['bed']),
        'layer2_variant_count': len(reference_files['bim']),
        'status': 'reference_matrix_loaded'
    },
    'phasing_panel_bed': '${phasing_panel_bed}'
}
Path(f'{sid}.ancestry_load_weights.json').write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}

workflow STAGE4_ANCESTRY_PCA {
    take:
    ch_stage4_inputs

    main:
    POPPCA_REFERENCE_PROJECTION(ch_stage4_inputs)
    STAGE4_ANCESTRY_LOAD_WEIGHTS(POPPCA_REFERENCE_PROJECTION.out.ancestry_ready)

    emit:
    ancestry_ready = POPPCA_REFERENCE_PROJECTION.out.ancestry_ready
    ancestry_weights = STAGE4_ANCESTRY_LOAD_WEIGHTS.out.weights
}
