process STAGE5_PGX_BRANCH {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}"
    publishDir "${params.outdir}/pgx", mode: 'copy', overwrite: true, pattern: '*.pgx.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf), val(criteria_file)

    output:
    tuple val(sample_id), path("${sample_id}.pgx.vcf.gz"), path("${sample_id}.pgx.vcf.gz.tbi"), emit: vcf
    tuple val(sample_id), path("${sample_id}.pgx.audit.json"), emit: audit
    tuple val(sample_id), path("${sample_id}.stage5_pgx.branch_manifest.json"), emit: branch_manifest

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_branch_lane.py" \
      --sample-id "${sample_id}" \
      --mode pgx \
      --in-vcf "${phased_vcf}" \
      --criteria "${criteria_file}" \
      --out-vcf "${sample_id}.pgx.vcf.gz" \
      --out-audit "${sample_id}.pgx.audit.json" \
      --out-manifest "${sample_id}.stage5_pgx.branch_manifest.json"
    """
}

process STAGE5_SF_BRANCH {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}"
    publishDir "${params.outdir}/secondary_findings", mode: 'copy', overwrite: true, pattern: '*.sf.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf), val(criteria_file)

    output:
    tuple val(sample_id), path("${sample_id}.sf.vcf.gz"), path("${sample_id}.sf.vcf.gz.tbi"), emit: vcf
    tuple val(sample_id), path("${sample_id}.sf.audit.json"), emit: audit
    tuple val(sample_id), path("${sample_id}.stage5_sf.branch_manifest.json"), emit: branch_manifest

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_branch_lane.py" \
      --sample-id "${sample_id}" \
      --mode sf \
      --in-vcf "${phased_vcf}" \
      --criteria "${criteria_file}" \
      --out-vcf "${sample_id}.sf.vcf.gz" \
      --out-audit "${sample_id}.sf.audit.json" \
      --out-manifest "${sample_id}.stage5_sf.branch_manifest.json"
    """
}

process STAGE5_PRS_BRANCH {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}"
    publishDir "${params.outdir}/prs", mode: 'copy', overwrite: true, pattern: '*.prs.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf), val(criteria_file)

    output:
    tuple val(sample_id), path("${sample_id}.prs.vcf.gz"), path("${sample_id}.prs.vcf.gz.tbi"), emit: vcf
    tuple val(sample_id), path("${sample_id}.prs.audit.json"), emit: audit
    tuple val(sample_id), path("${sample_id}.stage5_prs.branch_manifest.json"), emit: branch_manifest

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_branch_lane.py" \
      --sample-id "${sample_id}" \
      --mode prs \
      --in-vcf "${phased_vcf}" \
      --criteria "${criteria_file}" \
      --out-vcf "${sample_id}.prs.vcf.gz" \
      --out-audit "${sample_id}.prs.audit.json" \
      --out-manifest "${sample_id}.stage5_prs.branch_manifest.json"
    """
}

process STAGE5_SOMATIC_BRANCH {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}"
    publishDir "${params.outdir}/somatic", mode: 'copy', overwrite: true, pattern: '*.somatic.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf)

    output:
    tuple val(sample_id), path("${sample_id}.somatic.vcf.gz"), path("${sample_id}.somatic.vcf.gz.tbi"), emit: vcf
    tuple val(sample_id), path("${sample_id}.somatic.audit.json"), emit: audit
    tuple val(sample_id), path("${sample_id}.stage5_somatic.branch_manifest.json"), emit: branch_manifest

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_branch_lane.py" \
      --sample-id "${sample_id}" \
      --mode somatic \
      --in-vcf "${phased_vcf}" \
      --out-vcf "${sample_id}.somatic.vcf.gz" \
      --out-audit "${sample_id}.somatic.audit.json" \
      --out-manifest "${sample_id}.stage5_somatic.branch_manifest.json"
    """
}
