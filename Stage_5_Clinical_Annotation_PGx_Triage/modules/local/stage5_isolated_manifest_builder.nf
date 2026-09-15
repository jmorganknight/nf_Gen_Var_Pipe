process STAGE5_BUILD_MULTI_BRANCH_MANIFEST {
    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}", mode: 'copy', overwrite: true, pattern: 'samples_*_banked_stage5.yaml'

    input:
    tuple val(sample_id), path(germline_manifest), path(pgx_manifest), path(sf_manifest), path(prs_manifest), path(somatic_manifest), path(manifest_builder_script)

    output:
    tuple val(sample_id), path("samples_${sample_id}_banked_stage5.yaml"), emit: banked_manifest

    script:
    """
    set -euo pipefail
    python3 "${manifest_builder_script}" \
      --sample-id "${sample_id}" \
      --germline "${germline_manifest}" \
      --pgx "${pgx_manifest}" \
      --sf "${sf_manifest}" \
      --prs "${prs_manifest}" \
      --somatic "${somatic_manifest}" \
      --out-yaml "samples_${sample_id}_banked_stage5.yaml"
    """
}
