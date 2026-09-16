process GNOMAD_AGGREGATOR_SIEVE {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/annotation", mode: 'copy', overwrite: true, pattern: '*.json'

    input:
    tuple val(meta), path(phased_vcf), path(phased_tbi), val(reference_meta), path(router_json), path(custom_freq_sieve_script)

    output:
    tuple val(meta), path("${meta.sample_id}.gnomad_sieve_rules.json"), emit: freq_payload

    script:
    def sid = meta.sample_id
    def ancestry = meta.ancestry_label?.toString() ?: 'EUR'
    """
    set -euo pipefail

    python3 "${custom_freq_sieve_script}" --vcf "${phased_vcf}" --sample-id "${sid}" --ancestry-label "${ancestry}" --out "${sid}.gnomad_sieve_rules.json"
    """

    stub:
    """
    printf '{"node":"custom_freq_sieve.py","sample_id":"%s","ancestry_label":"EUR","rules":[],"stub":true}' "${meta.sample_id}" > "${meta.sample_id}.gnomad_sieve_rules.json"
    """
}
