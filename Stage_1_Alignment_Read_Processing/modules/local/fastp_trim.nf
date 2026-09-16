/*
 * ─────────────────────────────────────────────────────────────────────────────
 * Process : FASTP_TRIM
 * Stage   : 1 — Short-Read QC & Adapter Trimming
 *
 * Blueprint node : FASTP / ELE_FASTP_TRIM (draft_03.html)
 * Purpose:
 *   Adapter trimming and per-base quality masking using fastp. Outputs
 *   cleaned paired FASTQ files and a JSON quality report for downstream
 *   parity and Q30 checks (thresholds.yaml: read_parity_threshold = 0.99,
 *   q30_floor varies by platform).
 *
 * Platform-aware logic (pre-evaluated in Groovy, not bash):
 *   - Illumina two-color chemistry (NovaSeqX): enable poly-G trimming.
 *   - All other platforms: disable poly-G trimming.
 *
 * Inputs  : tuple val(meta), path(fastq_1), path(fastq_2)
 * Outputs : tuple val(meta), path("*.trimmed.r1.fq.gz"),
 *                            path("*.trimmed.r2.fq.gz")  → emit: reads
 *           tuple val(meta), path("*.fastp.json")        → emit: json
 * ─────────────────────────────────────────────────────────────────────────────
 */


process FASTP_TRIM {

    label 'process_high'
    container 'genvar-core:2.1.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/qc/fastp" }, mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(fastq_1), path(fastq_2)

    output:
    tuple val(meta),
          path("${meta.sample_id}.trimmed.r1.fq.gz"),
          path("${meta.sample_id}.trimmed.r2.fq.gz"), emit: reads
    tuple val(meta),
          path("${meta.sample_id}.fastp.json"),        emit: json

    script:
    def sid      = meta.sample_id
    def platform = meta.sequencer?.platform ?: 'illumina'
    def force_disable_poly_g = meta.fastp_disable_poly_g ?: false
    def poly_g_flag = force_disable_poly_g
        ? '--disable_trim_poly_g'
        : ((platform == 'illumina') ? '--trim_poly_g' : '--disable_trim_poly_g')

    """
    fastp \\
        --in1 "${fastq_1}" \\
        --in2 "${fastq_2}" \\
        --out1 "${sid}.trimmed.r1.fq.gz" \\
        --out2 "${sid}.trimmed.r2.fq.gz" \\
        --json "${sid}.fastp.json" \\
        --thread "${task.cpus}" \\
        --compression 2 \\
        --detect_adapter_for_pe \\
        ${poly_g_flag} \\
        --cut_right \\
        --cut_right_window_size 4 \\
        --cut_right_mean_quality 15 \\
        --qualified_quality_phred 20 \\
        --unqualified_percent_limit 40 \\
        --n_base_limit 5 \\
        --length_required 50
    """

    stub:
    """
    : > "${meta.sample_id}.trimmed.r1.fq.gz"
    : > "${meta.sample_id}.trimmed.r2.fq.gz"
    printf '{"summary":{"fastp_version":"stub","filtering_result":{"passed_filter_reads":0}}}' \\
        > "${meta.sample_id}.fastp.json"
    """
}