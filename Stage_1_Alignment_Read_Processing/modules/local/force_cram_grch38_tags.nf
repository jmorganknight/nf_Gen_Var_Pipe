/*
 * Node: FORCE_CRAM_GRCh38_TAGS
 */

process FORCE_CRAM_GRCh38_TAGS {

    label 'process_low'
    container 'genvar-core:2.1.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/audit_and_qc/reheader" }, mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(bam), path(bai), val(ref_dict)

    output:
    tuple val(meta),
          path("${meta.sample_id}.hs38DH_reheader.bam"),
          path("${meta.sample_id}.hs38DH_reheader.bam.bai"), emit: normalized_stream

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    samtools view -H "${bam}" > "${sid}.header.sam"
    printf '@CO\tFORCE_CRAM_GRCh38_TAGS ref_dict=%s\n' "${ref_dict}" >> "${sid}.header.sam"

    samtools reheader "${sid}.header.sam" "${bam}" > "${sid}.hs38DH_reheader.bam"
    samtools index -@ "${task.cpus}" "${sid}.hs38DH_reheader.bam"
    """

    stub:
    """
    : > "${meta.sample_id}.hs38DH_reheader.bam"
    : > "${meta.sample_id}.hs38DH_reheader.bam.bai"
    """
}
