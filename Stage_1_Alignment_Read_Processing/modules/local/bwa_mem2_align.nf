/*
 * ─────────────────────────────────────────────────────────────────────────────
 * Process : BWA_MEM2_ALIGN
 * Stage   : 1 — Hardware-Vectorized Alignment (local open-source track)
 *
 * Blueprint node : BWA / ELE_LAB_ALIGNER / UG_ALIGN / CG_ALIGN (draft_03.html)
 * Local mirror   : bwa-mem2 replaces Sentieon BWA-MEM (Rule 4.2, -profile local)
 *
 * Purpose:
 *   Map adapter-trimmed short reads to hs38DH (GRCh38 + ALTs + Decoys + HLA)
 *   using bwa-mem2, injecting a canonical @RG tag, and piping directly into
 *   samtools sort to produce a coordinate-sorted BAM without touching scratch
 *   disk twice (Rule 7.1 in-memory streaming design principle).
 *
 * Tuning (thresholds.yaml / PIPELINE_RULES.md Section 4.2):
 *   -k 19  (bwa_min_seed_length)
 *   -A  1  (bwa_match_score)
 *   -B  4  (bwa_mismatch_penalty)
 *
 * Rule 2.2.2: All thread counts bound to "${task.cpus}" — no hardcoded integers.
 * Rule 2.3  : Temp sort directory routed to task workDir (\${PWD}/tmp_sort_*)
 *             not to the external reference mount.
 *
 * Inputs  : tuple val(meta), path(r1), path(r2)
 *           path fasta             — reference FASTA (for samtools context)
 *           path fai               — reference FAI index
 *           path bwa_index, stageAs: 'bwa_idx/*'
 *                                  — bwa-mem2 index base (staged separately
 *                                    to prevent filename collision with fasta)
 * Outputs : tuple val(meta), path("*.aligned.bam"),  emit: bam
 * ─────────────────────────────────────────────────────────────────────────────
 */

process BWA_MEM2_ALIGN {

    label 'process_high'
    container 'genvar-core:2.1.0'

    tag "${meta.sample_id}"

    input:
    tuple val(meta), path(r1), path(r2)
    val fasta
    val fai
    val bwa_index

    output:
    tuple val(meta), path("${meta.sample_id}.aligned.bam"), emit: bam

    script:
    // ── Groovy pre-evaluation — safe binding before bash ─────────────────────
    def sid      = meta.sample_id
    def platform = meta.sequencer?.platform ?: 'illumina'
    def model    = meta.sequencer?.model    ?: 'unknown'
    def pu       = meta.sequencer?.flowcell_id ?: sid
    def ds       = meta.sequencer?.flowcell_geometry ?: 'native'
    def single_end = (meta.single_end ?: false)
    // REC-001: use declared val inputs — bwa_index is the hs38DH index base path;
    //          fasta val available for any samtools operations requiring the FASTA.
    //          Hardcoded container-internal reference path removed.
    // RG tag per nf-core canonical format; all fields pre-escaped for bash
    def rg_tag   = "@RG\\tID:${sid}\\tSM:${sid}\\tPL:${platform.toUpperCase()}\\tPM:${model}\\tPU:${pu}\\tLB:${sid}\\tDS:${ds}"

    if (single_end) {
    """
    bwa-mem2 mem \
        -t "${task.cpus}" \
        -k 19 \
        -A 1 \
        -B 4 \
        -R "${rg_tag}" \
        "${bwa_index}" \
        "${r1}" \
        | samtools sort \
            -@ "${task.cpus}" \
            -m 8G \
            -T "\${PWD}/tmp_sort_${sid}" \
            -o "${sid}.aligned.bam"
    """
    } else {
    """
    bwa-mem2 mem \\
        -t "${task.cpus}" \\
        -k 19 \\
        -A 1 \\
        -B 4 \\
        -R "${rg_tag}" \\
        "${bwa_index}" \\
        "${r1}" "${r2}" \\
        | samtools sort \\
            -@ "${task.cpus}" \\
            -m 8G \\
            -T "\${PWD}/tmp_sort_${sid}" \\
            -o "${sid}.aligned.bam"
    """
            }

    stub:
    """
    : > "${meta.sample_id}.aligned.bam"
    """
}
