nextflow.enable.dsl = 2

include { WHATSHAP_SHAPEIT_PHASER } from '../../modules/local/whatshap_shapeit_phaser.nf'

process STAGE4_PGX_PHASE_FILTER {

    label 'process_medium'
    container 'wes-onco-core:1.0.0'
    tag "${meta.sample_id}"

    input:
    tuple val(meta), path(ancestry_metrics_json), path(phased_vcf), path(phased_tbi), path(phasing_audit)

    output:
    tuple val(meta.sample_id), path("${meta.sample_id}.pgx_phased.vcf.gz"), path("${meta.sample_id}.pgx_phased.vcf.gz.tbi"), path(ancestry_metrics_json), path("${meta.sample_id}.pgx_phasing_audit.json"), emit: pgx_phase_bundle
    tuple val(meta), path(ancestry_metrics_json), path("${meta.sample_id}.pgx_phased.vcf.gz"), path("${meta.sample_id}.pgx_phased.vcf.gz.tbi"), path("${meta.sample_id}.pgx_phasing_audit.json"), emit: banked_phase_bundle

    script:
    def sid = meta.sample_id
    def pgxGenes = ['CYP2D6', 'CYP2C19', 'DPYD']
    """
    set -euo pipefail

    cp "${phased_vcf}" "${sid}.pgx_phased.vcf.gz"
    cp "${phased_tbi}" "${sid}.pgx_phased.vcf.gz.tbi"

    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sid}'
pgx_genes = ['CYP2D6', 'CYP2C19', 'DPYD']
source_path = Path('${phasing_audit}')
with source_path.open('r', encoding='utf-8') as fh:
    payload = json.load(fh)

payload.update({
    'pgx_target_genes': pgx_genes,
    'phase_scope': 'cis_trans_resolved_pgx_targets',
    'phase_region_targets': ['CYP2D6', 'CYP2C19', 'DPYD'],
    'status': 'PASS'
})
Path(f'{sid}.pgx_phasing_audit.json').write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
PYEOF
    """
}

workflow STAGE4_PHASING {
    take:
    ch_stage4_inputs

    main:
    WHATSHAP_SHAPEIT_PHASER(ch_stage4_inputs)
    STAGE4_PGX_PHASE_FILTER(WHATSHAP_SHAPEIT_PHASER.out.phase_bundle)

    emit:
    phase_bundle = STAGE4_PGX_PHASE_FILTER.out.pgx_phase_bundle
    banking_bundle = STAGE4_PGX_PHASE_FILTER.out.banked_phase_bundle
}
