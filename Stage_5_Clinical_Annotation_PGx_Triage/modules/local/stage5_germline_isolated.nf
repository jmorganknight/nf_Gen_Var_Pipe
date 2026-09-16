process STAGE5_GERMLINE_VEP_STREAM {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.vep.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf), val(stage5_refs)

    output:
    tuple val(sample_id), path("${sample_id}.vep.stream.tsv"), path("${sample_id}.vep.stream.audit.json"), emit: stream_tsv

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_extract_stream.py" \
      --sample-id "${sample_id}" \
      --stream vep \
      --in-vcf "${phased_vcf}" \
      --out-tsv "${sample_id}.vep.stream.tsv" \
      --out-audit "${sample_id}.vep.stream.audit.json"
    """
}

process STAGE5_GERMLINE_CLINVAR_STREAM {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.clinvar.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf), val(stage5_refs)

    output:
    tuple val(sample_id), path("${sample_id}.clinvar.stream.tsv"), path("${sample_id}.clinvar.stream.audit.json"), emit: stream_tsv

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_extract_stream.py" \
      --sample-id "${sample_id}" \
      --stream clinvar \
      --in-vcf "${phased_vcf}" \
      --out-tsv "${sample_id}.clinvar.stream.tsv" \
      --out-audit "${sample_id}.clinvar.stream.audit.json"
    """
}

process STAGE5_GERMLINE_GNOMAD_STREAM {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.gnomad.*'

    input:
    tuple val(sample_id), val(sample_meta), path(phased_vcf), val(stage5_refs)

    output:
    tuple val(sample_id), path("${sample_id}.gnomad.stream.tsv"), path("${sample_id}.gnomad.stream.audit.json"), emit: stream_tsv

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_extract_stream.py" \
      --sample-id "${sample_id}" \
      --stream gnomad \
      --in-vcf "${phased_vcf}" \
      --out-tsv "${sample_id}.gnomad.stream.tsv" \
      --out-audit "${sample_id}.gnomad.stream.audit.json"
    """
}

process STAGE5_GERMLINE_JOIN_EVIDENCE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.joined.*'

    input:
    tuple val(sample_id), path(vep_tsv), path(clinvar_tsv), path(gnomad_tsv)

    output:
    tuple val(sample_id), path("${sample_id}.germline.joined.tsv"), path("${sample_id}.germline.joined.audit.json"), emit: joined

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_join_evidence.py" \
      --sample-id "${sample_id}" \
      --vep-tsv "${vep_tsv}" \
      --clinvar-tsv "${clinvar_tsv}" \
      --gnomad-tsv "${gnomad_tsv}" \
      --out-joined-tsv "${sample_id}.germline.joined.tsv" \
      --out-audit "${sample_id}.germline.joined.audit.json"
    """
}

process RULE_COMP_SYNTHESIS {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.comp_rules.json'

    input:
    tuple val(sample_id), path(joined_tsv)

    output:
    tuple val(sample_id), path("${sample_id}.comp_rules.json"), emit: rules

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_rule_comp_synthesis.py" \
      --sample-id "${sample_id}" \
      --joined-tsv "${joined_tsv}" \
      --out-json "${sample_id}.comp_rules.json"
    """
}

process RULE_LOSS_TRUNCATION {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.loss_rules.json'

    input:
    tuple val(sample_id), path(joined_tsv)

    output:
    tuple val(sample_id), path("${sample_id}.loss_rules.json"), emit: rules

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_rule_loss_truncation.py" \
      --sample-id "${sample_id}" \
      --joined-tsv "${joined_tsv}" \
      --out-json "${sample_id}.loss_rules.json"
    """
}

process RULE_FREQ_CHECK {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.freq_rules.json'

    input:
    tuple val(sample_id), path(joined_tsv), val(hotspot_registry)

    output:
    tuple val(sample_id), path("${sample_id}.freq_rules.json"), emit: rules

    script:
    def hotspotArg = hotspot_registry ? "--hotspot-registry \"${hotspot_registry}\"" : ''
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_rule_freq_check.py" \
      --sample-id "${sample_id}" \
      --joined-tsv "${joined_tsv}" \
      ${hotspotArg} \
      --out-json "${sample_id}.freq_rules.json"
    """
}

process STAGE5_GERMLINE_BAYES_PARTITION {
    label 'process_medium'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.germline.*'

    input:
    tuple val(sample_id), path(phased_vcf), path(joined_tsv), path(comp_rules_json), path(loss_rules_json), path(freq_rules_json)

    output:
    tuple val(sample_id), path("${sample_id}.germline.benign.vcf.gz"), path("${sample_id}.germline.benign.vcf.gz.tbi"), emit: benign
    tuple val(sample_id), path("${sample_id}.germline.pathogenic.vcf.gz"), path("${sample_id}.germline.pathogenic.vcf.gz.tbi"), emit: pathogenic
    tuple val(sample_id), path("${sample_id}.germline.vus.vcf.gz"), path("${sample_id}.germline.vus.vcf.gz.tbi"), emit: vus
    tuple val(sample_id), path("${sample_id}.germline.scores.json"), emit: scores
    tuple val(sample_id), path("${sample_id}.germline.bayes.audit.json"), emit: partition_audit

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_bayes_partition.py" \
      --sample-id "${sample_id}" \
      --in-vcf "${phased_vcf}" \
      --joined-tsv "${joined_tsv}" \
      --comp-rules "${comp_rules_json}" \
      --loss-rules "${loss_rules_json}" \
      --freq-rules "${freq_rules_json}" \
      --out-benign-vcf "${sample_id}.germline.benign.vcf.gz" \
      --out-pathogenic-vcf "${sample_id}.germline.pathogenic.vcf.gz" \
      --out-vus-vcf "${sample_id}.germline.vus.vcf.gz" \
      --out-score-json "${sample_id}.germline.scores.json" \
      --out-audit "${sample_id}.germline.bayes.audit.json"
    """
}

process STAGE5_GERMLINE_ZERO_LOSS_GATE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.germline.zero_loss.audit.json'

    input:
    tuple val(sample_id), path(partition_audit)

    output:
    tuple val(sample_id), path("${sample_id}.germline.zero_loss.audit.json"), emit: zero_loss

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_zero_loss_audit.py" \
      --sample-id "${sample_id}" \
      --partition-audit "${partition_audit}" \
      --out-audit "${sample_id}.germline.zero_loss.audit.json"
    """
}

process STAGE5_VUS_HGMD_TRIAGE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.germline.vus_triaged.*'

    input:
    tuple val(sample_id), path(vus_vcf), path(scores_json), val(hgmd_db)

    output:
    tuple val(sample_id), path("${sample_id}.germline.vus_triaged.vcf.gz"), path("${sample_id}.germline.vus_triaged.vcf.gz.tbi"), emit: triaged_vus
    tuple val(sample_id), path("${sample_id}.germline.vus_hgmd.audit.json"), emit: triage_audit

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_vus_hgmd_triage.py" \
      --sample-id "${sample_id}" \
      --vus-vcf "${vus_vcf}" \
      --scores-json "${scores_json}" \
      --hgmd-db "${hgmd_db}" \
      --out-vcf "${sample_id}.germline.vus_triaged.vcf.gz" \
      --out-audit "${sample_id}.germline.vus_hgmd.audit.json"
    """
}

process STAGE5_GERMLINE_BRANCH_MANIFEST {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'symlink'
    tag "${sample_id}"
    publishDir "${params.outdir}/germline", mode: 'copy', overwrite: true, pattern: '*.stage5_germline.branch_manifest.json'

    input:
    tuple val(sample_id), path(benign_vcf), path(pathogenic_vcf), path(vus_vcf), path(vus_triaged_vcf), path(partition_audit), path(zero_loss_audit), path(hgmd_audit)

    output:
    tuple val(sample_id), path("${sample_id}.stage5_germline.branch_manifest.json"), emit: branch_manifest

    script:
    """
    set -euo pipefail
    python3 "${projectDir}/bin/stage5_germline_branch_manifest.py" \
      --sample-id "${sample_id}" \
      --benign-vcf "${benign_vcf}" \
      --pathogenic-vcf "${pathogenic_vcf}" \
      --vus-vcf "${vus_vcf}" \
      --vus-triaged-vcf "${vus_triaged_vcf}" \
      --partition-audit "${partition_audit}" \
      --zero-loss-audit "${zero_loss_audit}" \
      --hgmd-audit "${hgmd_audit}" \
      --out-manifest "${sample_id}.stage5_germline.branch_manifest.json"
    """
}
