nextflow.enable.dsl = 2

include { LOAD_STAGE2_CONTRACT } from './modules/local/load_stage2_contract.nf'
include { BRANCH_SNV_INDEL } from './modules/local/branch_snv_indel.nf'
include { BRANCH_STRUCTURAL_VARIANTS } from './modules/local/branch_structural_variants.nf'
include { BRANCH_COPY_NUMBER_CNV } from './modules/local/branch_copy_number_cnv.nf'
include { BRANCH_STR_EXPANSIONS } from './modules/local/branch_str_expansions.nf'
include { BRANCH_TRISOMY_ANEUPLOIDY } from './modules/local/branch_trisomy_aneuploidy.nf'
include { BRANCH_HOMOLOGOUS_PSEUDOGENES } from './modules/local/branch_homologous_pseudogenes.nf'
include { BCFTOOLS_NORM } from './modules/local/bcftools_norm.nf'
include { STAGE3_VARIANT_ENGINE } from './modules/local/stage3_variant_engine.nf'
include { ASSEMBLE_STAGE3_BANKED_MANIFEST } from './modules/local/assemble_stage3_banked_manifest.nf'

workflow STAGE3_VARIANT_DISCOVERY_ENGINE {
    take:
    ch_stage2_contracts

    main:
    STAGE3_VARIANT_ENGINE(ch_stage2_contracts)

    emit:
    stage3_manifest = STAGE3_VARIANT_ENGINE.out.banked_manifest
}

workflow {
    def stage2Manifest = file((params.input ?: params.samples).toString())
    if (!stage2Manifest.exists()) {
        throw new IllegalArgumentException('STAGE3_PRECONDITION_FAILURE: missing Stage 2 banked manifest')
    }
    def referencesFile = file(params.references)
    def refsParsed = new groovy.yaml.YamlSlurper().parse(referencesFile).references
    def refDir = params.ref_dir?.toString()
    [
        reference_genome: (refsParsed.reference_genome ?: refsParsed.grch38_fasta),
        reference_fai   : (refsParsed.reference_fai ?: refsParsed.grch38_fai),
        reference_dict  : (refsParsed.reference_dict ?: refsParsed.grch38_dict),
        onco_target_bed : (refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed),
        sf_bed          : refsParsed.sf_bed,
        hotspot_registry: refsParsed.hotspot_registry,
        clinvar_db      : refsParsed.clinvar_db
    ].each { key, value ->
        if (!value) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}'")
        }
        def referencePath = value.toString()
        def resolved = referencePath.startsWith('/opt/reference')
            ? (refDir ? new File(refDir + referencePath.replaceFirst('^/opt/reference', '')) : null)
            : new File(referencePath)
        if (resolved == null || !resolved.exists()) {
            throw new IllegalStateException("STAGE3_PRECONDITION_FAILURE: MISSING_REFERENCE_ASSET '${key}=${value}'")
        }
    }
    STAGE3_VARIANT_DISCOVERY_ENGINE(channel.of(stage2Manifest))
}
