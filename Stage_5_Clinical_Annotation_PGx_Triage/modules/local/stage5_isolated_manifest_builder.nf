process STAGE5_BUILD_MULTI_BRANCH_MANIFEST {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}"
    publishDir "${params.outdir}", mode: 'copy', overwrite: true, pattern: 'samples_*_banked_stage5.yaml'

    input:
    tuple val(sample_id), val(run_mode), val(sample_payload), path(germline_manifest), path(pgx_manifest), path(sf_manifest), path(prs_manifest), path(somatic_manifest), path(manifest_builder_script)

    output:
    tuple val(sample_id), path("samples_${sample_id}_banked_stage5.yaml"), emit: banked_manifest

    script:
    """
    set -euo pipefail
    cat > stage4_sample_payload.json <<'JSON'
${groovy.json.JsonOutput.toJson(sample_payload)}
JSON
    python3 "${manifest_builder_script}" \
      --sample-id "${sample_id}" \
      --run-mode "${run_mode}" \
      --stage4-sample-json "stage4_sample_payload.json" \
      --germline "${germline_manifest}" \
      --pgx "${pgx_manifest}" \
      --sf "${sf_manifest}" \
      --prs "${prs_manifest}" \
      --somatic "${somatic_manifest}" \
      --out-yaml "samples_${sample_id}_banked_stage5.yaml"
    """
}
