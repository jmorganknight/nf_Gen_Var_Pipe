process PGX_DIPLOTYPE_RESOLVER {

    label 'process_medium'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), val(pgx_cli_script)

    output:
    tuple val(meta.sample_id), path("${meta.sample_id}.pgx_summary.json"), emit: summary

    script:
    def sid = meta.sample_id
    def combinedMeta = [
        sample_id: sid,
        phased_vcf: phased_vcf.toString(),
        phased_vcf_tbi: phased_tbi.toString(),
        ancestry_metrics_json: meta.ancestry_metrics_json?.toString(),
        phasing_audit_json: meta.phasing_audit_json?.toString(),
        validation_token: meta.validation_token?.toString(),
        run_id: meta.run_id?.toString(),
        workflow_version: meta.workflow_version?.toString(),
    ] + (reference_meta instanceof Map ? reference_meta : [:])
    def metaJson = groovy.json.JsonOutput.toJson(combinedMeta).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 "${pgx_cli_script}" resolve \
      --sample-id "${sid}" \
      --vcf "${phased_vcf}" \
      --tbi "${phased_tbi}" \
      --reference-meta '${metaJson}' \
      --out "${sid}.pgx_summary.json"
    """
}
