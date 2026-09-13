process SOMATIC_ONCO_TRIAGE {

    label 'process_medium'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    tag "${sample_id}"

    input:
    tuple val(sample_id), path(phased_vcf), path(phased_tbi), path(ancestry_metrics_json), path(phasing_audit_json), path(revel), path(alphamissense), path(cadd), path(spliceai), path(clinvar), path(gnomad), path(pfam_domains), path(alphafold_annotations), path(litvar), path(pmc), path(mastermind), path(stage5_engine_script)

    output:
    tuple val(sample_id), path("${sample_id}.somatic_onco_summary.json"), emit: summary

    script:
    def sid = sample_id
    def litvarArg = litvar ? "--litvar \"${litvar}\"" : ''
    def pmcArg = pmc ? "--pmc \"${pmc}\"" : ''
    def mastermindArg = mastermind ? "--mastermind \"${mastermind}\"" : ''
    """
    set -euo pipefail

    python3 "${stage5_engine_script}" somatic \
      --sample-id "${sid}" \
      --vcf "${phased_vcf}" \
      --ancestry-json "${ancestry_metrics_json}" \
      --phasing-json "${phasing_audit_json}" \
      --revel "${revel}" \
      --alphamissense "${alphamissense}" \
      --cadd "${cadd}" \
      --spliceai "${spliceai}" \
      --clinvar "${clinvar}" \
      --gnomad "${gnomad}" \
      --pfam_domains "${pfam_domains}" \
      --alphafold_annotations "${alphafold_annotations}" \
      ${litvarArg} \
      ${pmcArg} \
      ${mastermindArg} \
      --out "${sid}.somatic_onco_summary.json"
    """
}
