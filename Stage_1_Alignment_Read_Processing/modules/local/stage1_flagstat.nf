process STAGE1_FLAGSTAT {

    label 'process_low'
    container 'genvar-core:2.1.0'

    tag "${meta.sample_id}"


    input:
    tuple val(meta), path(identity_audit), path(bam), path(bai)

    output:
    path "${meta.sample_id}.flagstat.txt", emit: flagstat

    script:
    """
    set -euo pipefail
    samtools flagstat -@ "${task.cpus}" "${bam}" > "${meta.sample_id}.flagstat.txt"
    """

    stub:
    """
    printf '0 + 0 in total (QC-passed reads + QC-failed reads)\n' > "${meta.sample_id}.flagstat.txt"
    """
}
