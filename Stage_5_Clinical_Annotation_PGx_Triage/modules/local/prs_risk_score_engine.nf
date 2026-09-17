process PRS_RISK_SCORE_ENGINE {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${sample_id}"

    input:
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), path(pgx_gene_panel), path(gene_rule_set), path(stage5_engine_script)

    output:
    tuple val(sample_id), path("${sample_id}.prs_summary.json"), emit: summary

    script:
    def sid = sample_id
    """
    set -euo pipefail

    python3 "${stage5_engine_script}" prs \
      --sample-id "${sid}" \
      --vcf "${phased_vcf}" \
      --pgx_gene_panel "${pgx_gene_panel}" \
      --gene_rule_set "${gene_rule_set}" \
      --out "${sid}.prs_summary.json"
    """
}
