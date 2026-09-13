nextflow.enable.dsl = 2
// Revision marker: Stage 3 scalar-metadata dynamic calibration + schema governance wiring.

include { STAGE3_SNV_INDEL } from './modules/local/stage3_snv_indel.nf'
include { MANE_TRANSCRIPT_SELECTOR } from './modules/local/mane_transcript_selector.nf'
include { MASTER_HARMONIZED_VCF_PAYLOAD } from './modules/local/master_harmonized_vcf_payload.nf'

def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}

def resolveHostPath(def rawPath, String refDir) {
    if (!rawPath) {
        return null
    }
    def p = rawPath.toString()
    if (p.startsWith('/opt/reference')) {
        if (!refDir) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: ref_dir is required to resolve host path for ${p}")
        }
        return new File(refDir + p.replaceFirst('^/opt/reference', '')).toString()
    }
    return p
}

workflow STAGE3_VARIANT_DISCOVERY_ENGINE {
    take:
    ch_snv_indel_inputs

    main:
    STAGE3_SNV_INDEL(ch_snv_indel_inputs)
    def ch_mane_inputs = STAGE3_SNV_INDEL.out.calibrated_vcf.map { sid, vcf, calibrationAudit, refs, meta ->
        tuple(sid, vcf, calibrationAudit, file(refs.mane_transcripts.toString()), refs, meta)
    }
    MANE_TRANSCRIPT_SELECTOR(ch_mane_inputs)
    MASTER_HARMONIZED_VCF_PAYLOAD(MANE_TRANSCRIPT_SELECTOR.out.selected_vcf)

    emit:
    snv_indel_vcf = MASTER_HARMONIZED_VCF_PAYLOAD.out.harmonized.map { sid, vcf, _audit, _fragment -> tuple(sid, vcf) }
    snv_indel_audit = MASTER_HARMONIZED_VCF_PAYLOAD.out.harmonized.map { sid, _vcf, audit, _fragment -> tuple(sid, audit) }
    stage3_manifest = MASTER_HARMONIZED_VCF_PAYLOAD.out.harmonized.map { _sid, _vcf, _audit, fragment -> fragment }
}

workflow STAGE3_VARIANT_DISCOVERY {
    main:
    def ys = new groovy.yaml.YamlSlurper()
    def stage2Manifest = file((params.input ?: params.samples).toString())
    if (!stage2Manifest.exists()) {
        throw new IllegalArgumentException('STAGE3_PRECONDITION_FAILURE: missing Stage 2 banked manifest')
    }
    def referencesFile = file(params.references)
    def refsRaw = ys.parse(referencesFile)
    def refsParsed = mapOrEmpty(refsRaw?.references ?: refsRaw)
    def refsFromParams = mapOrEmpty(params.refs)
    def refsCombined = refsParsed + refsFromParams
    def refDir = params.ref_dir?.toString()

    def stage3Refs = [
        reference_genome  : refsCombined.reference_genome ?: refsCombined.grch38_fasta ?: refsCombined.fasta,
        capture_wes_bed   : refsCombined.capture_wes_bed ?: refsCombined.onco_target_bed ?: refsCombined.target_bed_onco,
        onco_target_bed   : refsCombined.onco_target_bed ?: refsCombined.capture_wes_bed ?: refsCombined.target_bed_onco,
        mane_transcripts  : refsCombined.mane_transcripts ?: refsCombined.mane_db,
        stage3_vcf_schema : refsCombined.stage3_vcf_schema,
    ]

    ['reference_genome', 'mane_transcripts', 'stage3_vcf_schema'].each { key ->
        def value = stage3Refs[key]
        if (!value) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def resolved = resolveHostPath(value, refDir)
        if (!new File(resolved).exists()) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
        stage3Refs[key] = resolved
    }

    ['capture_wes_bed', 'onco_target_bed'].each { key ->
        def value = stage3Refs[key]
        if (value) {
            stage3Refs[key] = resolveHostPath(value, refDir)
        }
    }

    def stage2Parsed = ys.parse(stage2Manifest)
    def records = stage2Parsed?.samples
    if (!(records instanceof List) || records.isEmpty()) {
        throw new IllegalStateException('STAGE3_PRECONDITION_FAILURE: Stage 2 banked manifest contains no samples')
    }

    def ch_samples = channel
        .from(records)
        .map { rec ->
            def sample = rec as Map
            def sampleId = (sample.sample_id ?: 'UNKNOWN').toString()
            def sortedBam = sample.sorted_bam?.toString()
            if (!sortedBam) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: sorted_bam missing for sample '${sampleId}'")
            }
            def sortedBai = sample.sorted_bai?.toString() ?: "${sortedBam}.bai"
            def sequencingType = (([sample.sequencing_type, sample.seq_type, 'WES'].find { v -> v != null && v.toString().trim() }) ?: 'WES').toString().trim().toUpperCase()
            def isWgs = sequencingType == 'WGS'
            def sampleType = (sample.sample_type ?: 'germline').toString().toLowerCase()

            def sampleQcMeta = mapOrEmpty(sample.sample_qc_meta)
            sampleQcMeta = [
                estimated_in_silico_purity: sampleQcMeta.estimated_in_silico_purity ?: sample.estimated_in_silico_purity,
                contamination_rate        : sampleQcMeta.contamination_rate ?: sample.contamination_rate,
                computed_sex              : sampleQcMeta.computed_sex ?: sample.computed_sex ?: 'UNKNOWN',
                sex_concordance_pass      : sampleQcMeta.sex_concordance_pass ?: sample.sex_concordance_pass,
                purity_concordance_pass   : sampleQcMeta.purity_concordance_pass ?: sample.purity_concordance_pass,
            ]

            def refBuild = (sample.reference_build instanceof Map) ? (sample.reference_build as Map) : [:]
            def rawFasta = [refBuild.fasta, refBuild.reference_genome, refBuild.grch38_fasta, stage3Refs.reference_genome].find { v -> v != null && v.toString().trim() }
            if (!rawFasta) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET 'fasta' for sample '${sampleId}'")
            }
            def fastaHostPath = resolveHostPath(rawFasta, refDir)
            if (!new File(fastaHostPath).exists()) {
                throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET 'fasta=${rawFasta}' for sample '${sampleId}'")
            }

            def rawTargetBed = [sample.snv_mask_bed, sample.cnv_target_bed, refBuild.target_bed_onco, refBuild.onco_target_bed, refBuild.capture_wes_bed, stage3Refs.onco_target_bed, stage3Refs.capture_wes_bed].find { v -> v != null && v.toString().trim() }
            def targetBed = rawTargetBed ? rawTargetBed.toString() : null
            if (targetBed) {
                targetBed = resolveHostPath(targetBed, refDir)
            }

            def variantBranches = (sample.variant_branches instanceof Map) ? (sample.variant_branches as Map) : [:]
            def activeBranches = variantBranches.findAll { _key, enabled -> enabled as boolean }.keySet() as List
            if (activeBranches.isEmpty()) {
                throw new IllegalStateException("STAGE3_BRANCH_DISABLED: no active Stage 3 branches enabled for sample '${sampleId}'")
            }
            def sampleMeta = [
                sample_id       : sampleId,
                sample_type     : sampleType,
                sequencing_type : sequencingType,
                validation_token: (sample.validation_token ?: sample.intake_validation_token_value ?: '').toString(),
                sorted_bam      : sortedBam,
                sorted_bai      : sortedBai,
                variant_branches: variantBranches,
                reference_build : refBuild,
                stage3_faults   : ((sample.stage3_faults instanceof Map) ? (sample.stage3_faults as Map) : [:]),
            ]

            tuple(
                sampleId,
                stage2Manifest,
                file(sortedBam),
                file(sortedBai),
                isWgs,
                targetBed,
                file(fastaHostPath),
                sampleQcMeta,
                stage3Refs,
                sampleMeta,
                variantBranches
            )
        }

    def ch_snv_indel_inputs = ch_samples
        .filter { row ->
            def branches = row[10] as Map
            return (branches?.snv_indel ?: false) as boolean
        }
        .map { row -> tuple(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9]) }

    STAGE3_VARIANT_DISCOVERY_ENGINE(ch_snv_indel_inputs)

    emit:
    stage3_manifest = STAGE3_VARIANT_DISCOVERY_ENGINE.out.stage3_manifest
}

workflow {
    STAGE3_VARIANT_DISCOVERY()
}
