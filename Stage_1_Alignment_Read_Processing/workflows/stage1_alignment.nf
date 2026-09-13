nextflow.enable.dsl = 2

include { PLATFORM_INIT_ROUTER } from '../modules/local/platform_init_router.nf'
include { FASTP_TRIM as FASTP_TRIM_ILLUMINA } from '../modules/local/fastp_trim.nf'
include { FASTP_TRIM as FASTP_TRIM_ELEMENT } from '../modules/local/fastp_trim.nf'
include { ELPREP_ALIGN_MARKDUP } from '../modules/local/elprep_align_markdup.nf'
include { BWA_MEM2_ALIGN as BWA_MEM2_ALIGN_ULTIMA } from '../modules/local/bwa_mem2_align.nf'
include { BWA_MEM2_ALIGN as BWA_MEM2_ALIGN_ELEMENT } from '../modules/local/bwa_mem2_align.nf'
include { STAGE1_ONT_LONGREAD_ALIGN } from '../modules/local/stage1_ont_longread_align.nf'
include { STAGE1_BWA_FINALIZE as STAGE1_BWA_FINALIZE_ULTIMA } from '../modules/local/stage1_bwa_finalize.nf'
include { STAGE1_BWA_FINALIZE as STAGE1_BWA_FINALIZE_ELEMENT } from '../modules/local/stage1_bwa_finalize.nf'
include { FORCE_CRAM_GRCh38_TAGS } from '../modules/local/force_cram_grch38_tags.nf'
include { COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB } from '../modules/local/coordinate_standardized_cram_junction_hub.nf'
include { CROSS_SAMPLE_IDENTITY_GATE } from '../modules/local/cross_sample_identity_gate.nf'
include { STAGE1_FLAGSTAT } from '../modules/local/stage1_flagstat.nf'
include { STAGE1_AUDIT_SINK } from '../modules/local/stage1_audit_sink.nf'
include { BANK_STAGE1_CONTRACT } from '../modules/local/bank_stage1_contract.nf'
include { ASSEMBLE_STAGE1_BANKED_MANIFEST } from '../modules/local/assemble_stage1_banked_manifest.nf'

workflow STAGE1_ALIGNMENT {

    take:
    ch_platform_payload
    ch_ref_genome
    ch_ref_fai
    ch_bwa_index
    ch_ref_dict
    ch_svd_panel
    ch_freemix_limit
    ch_reference_meta

    main:
    PLATFORM_INIT_ROUTER(ch_platform_payload)

    def ch_routed_reads = PLATFORM_INIT_ROUTER.out.routed_payload.map { meta, fastq1, fastq2, _token, _report ->
        tuple(meta, fastq1, fastq2)
    }

    // Explicit assay intent routes used by downstream branch governance.
    def ch_somatic_paired = ch_routed_reads.filter { meta, _r1, _r2 ->
        (meta.assay_route ?: 'germline_single').toString() == 'somatic_paired'
    }
    def ch_germline_single = ch_routed_reads.filter { meta, _r1, _r2 ->
        (meta.assay_route ?: 'germline_single').toString() != 'somatic_paired'
    }

    // Explicit platform-decoupled sub-channels.
    def ch_illumina_short_read = ch_germline_single.filter { meta, _r1, _r2 ->
        (meta.sequencing_platform ?: 'illumina').toString() == 'illumina'
    }
    def ch_ultima_short_read = ch_routed_reads.filter { meta, _r1, _r2 ->
        (meta.sequencing_platform ?: '').toString() == 'ultima'
    }
    def ch_element_short_read = ch_routed_reads.filter { meta, _r1, _r2 ->
        ['element', 'complete', 'complete_genomics'].contains((meta.sequencing_platform ?: '').toString())
    }
    def ch_ont_long_read = ch_routed_reads.filter { meta, _r1, _r2 ->
        (meta.sequencing_platform ?: '').toString() == 'ont'
    }

    FASTP_TRIM_ILLUMINA(ch_illumina_short_read)
    ELPREP_ALIGN_MARKDUP(
        FASTP_TRIM_ILLUMINA.out.reads,
        ch_ref_genome,
        ch_ref_fai,
        ch_bwa_index
    )

    // Ultima decoupled short-read path with flow/homopolymer calibration flags in metadata.
    def ch_ultima_calibrated = ch_ultima_short_read.map { meta, r1, r2 ->
        tuple(meta + [single_end: true, homopolymer_calibration: 'ultima_flow_model_v1'], r1, r2)
    }
    BWA_MEM2_ALIGN_ULTIMA(
        ch_ultima_calibrated,
        ch_ref_genome,
        ch_ref_fai,
        ch_bwa_index
    )
    STAGE1_BWA_FINALIZE_ULTIMA(BWA_MEM2_ALIGN_ULTIMA.out.bam)

    // Element decoupled short-read path with chemistry-specific quality score binning metadata.
    FASTP_TRIM_ELEMENT(ch_element_short_read.map { meta, r1, r2 ->
        tuple(meta + [quality_score_binning: 'element_4bin'], r1, r2)
    })
    BWA_MEM2_ALIGN_ELEMENT(
        FASTP_TRIM_ELEMENT.out.reads,
        ch_ref_genome,
        ch_ref_fai,
        ch_bwa_index
    )
    STAGE1_BWA_FINALIZE_ELEMENT(BWA_MEM2_ALIGN_ELEMENT.out.bam)

    // ONT decoupled long-read path via minimap2 map-ont.
    STAGE1_ONT_LONGREAD_ALIGN(
        ch_ont_long_read,
        ch_ref_genome
    )

    def ch_all_bam_bai = ELPREP_ALIGN_MARKDUP.out.bam_bai
        .mix(STAGE1_BWA_FINALIZE_ULTIMA.out.bam_bai)
        .mix(STAGE1_BWA_FINALIZE_ELEMENT.out.bam_bai)
        .mix(STAGE1_ONT_LONGREAD_ALIGN.out.bam_bai)

    def ch_force_input = ch_all_bam_bai
        .combine(ch_ref_dict)
        .map { meta, bam, bai, refDict -> tuple(meta, bam, bai, refDict) }

    FORCE_CRAM_GRCh38_TAGS(ch_force_input)
    COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB(FORCE_CRAM_GRCh38_TAGS.out.normalized_stream)

    def ch_identity_input = COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB.out.verified_stream
        .combine(ch_svd_panel)
        .combine(ch_freemix_limit)
        .map { meta, bam, bai, svdPanel, freemixLimit -> tuple(meta, bam, bai, svdPanel, freemixLimit) }

    CROSS_SAMPLE_IDENTITY_GATE(ch_identity_input)
    STAGE1_FLAGSTAT(CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream)

    def ch_route_audits = PLATFORM_INIT_ROUTER.out.route_audit.collect()
    def ch_fastp_jsons = FASTP_TRIM_ILLUMINA.out.json.map { _meta, jsonPath -> jsonPath }
        .mix(FASTP_TRIM_ELEMENT.out.json.map { _meta, jsonPath -> jsonPath })
        .collect()
    def ch_align_metrics = ELPREP_ALIGN_MARKDUP.out.json_metrics.map { _meta, p -> p }
        .mix(STAGE1_BWA_FINALIZE_ULTIMA.out.json_metrics.map { _meta, p -> p })
        .mix(STAGE1_BWA_FINALIZE_ELEMENT.out.json_metrics.map { _meta, p -> p })
        .mix(STAGE1_ONT_LONGREAD_ALIGN.out.json_metrics.map { _meta, p -> p })
        .collect()
    def ch_identity_audits = CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream.map { _meta, audit, _bam, _bai -> audit }.collect()
    def ch_junction_audits = COORDINATE_STANDARDIZED_CRAM_JUNCTION_HUB.out.audit.collect()
    def ch_flagstats = STAGE1_FLAGSTAT.out.flagstat.collect()

    STAGE1_AUDIT_SINK(
        ch_route_audits,
        ch_fastp_jsons,
        ch_align_metrics,
        ch_flagstats,
        ch_identity_audits,
        ch_junction_audits
    )

    BANK_STAGE1_CONTRACT(CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream, ch_reference_meta)
    ASSEMBLE_STAGE1_BANKED_MANIFEST(BANK_STAGE1_CONTRACT.out.manifest_fragment.collect())

    def ch_stage2_handoff = CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream.map { meta, identityAudit, bam, bai ->
        def sampleMeta = (meta as Map) + [identity_audit: identityAudit.toString()]
        tuple(meta.sample_id.toString(), sampleMeta, bam, bai)
    }

    emit:
    aligned_contract = ASSEMBLE_STAGE1_BANKED_MANIFEST.out.banked_manifest
    stage1_audit_payload = STAGE1_AUDIT_SINK.out.payload
    aligned_bam_bai = CROSS_SAMPLE_IDENTITY_GATE.out.audited_stream
    stage2_handoff = ch_stage2_handoff
    somatic_routed = ch_somatic_paired
    germline_routed = ch_germline_single
    illumina_routed = ch_illumina_short_read
    ultima_routed = ch_ultima_short_read
    element_routed = ch_element_short_read
    ont_routed = ch_ont_long_read
}
