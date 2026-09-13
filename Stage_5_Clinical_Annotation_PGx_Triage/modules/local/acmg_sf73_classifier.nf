process ACMG_SF73_CLASSIFIER {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${sample_id}"

    input:
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), path(acmg_schema), path(clinvar), path(gnomad), path(pgx_gene_panel), path(stage5_engine_script)

    output:
    tuple val(sample_id), path("${sample_id}.sf_acmg_summary.json"), emit: summary

    script:
    def sid = sample_id
    """
    set -euo pipefail

    python3 "${stage5_engine_script}" sf73 \
      --sample-id "${sid}" \
      --vcf "${phased_vcf}" \
      --acmg_schema "${acmg_schema}" \
      --clinvar "${clinvar}" \
      --gnomad "${gnomad}" \
      --pgx_gene_panel "${pgx_gene_panel}" \
      --out "${sid}.sf_acmg_summary.json"
    """
}
