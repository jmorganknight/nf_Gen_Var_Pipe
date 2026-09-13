nextflow.enable.dsl = 2

include { STAGE5_INPUT_NORMALIZER } from '../modules/local/stage5_input_normalizer.nf'
include { STAGE5_CLINICAL_TRIAGE } from '../subworkflows/local/stage5_clinical_triage.nf'

workflow STAGE5_ANNOTATION_PGX {
    take:
    ch_stage5_inputs
    ch_signer_key
    ch_signer_pub

    main:
    def refs = params.refs instanceof Map ? params.refs : [:]
    def requiredRefs = [
        'revel',
        'alphamissense',
        'cadd',
        'spliceai',
        'clinvar',
        'gnomad',
        'pfam_domains',
        'alphafold_annotations',
        'pgx_gene_panel',
        'gene_rule_set',
        'acmg_schema',
        'pgx_cli_script'
    ]

    def missingRefs = requiredRefs.findAll { key -> !refs[key] }
    if (missingRefs) {
        throw new IllegalStateException("STAGE5_REFERENCE_FAILURE: missing params.refs keys ${missingRefs}")
    }

    def branchAssets = [
        stage5_engine_script  : file(new File(projectDir.toString(), 'bin/stage5_pathogenicity.py'), checkIfExists: true),
        pgx_cli_script        : file(refs.pgx_cli_script, checkIfExists: true),
        revel                 : file(refs.revel, checkIfExists: true),
        alphamissense         : file(refs.alphamissense, checkIfExists: true),
        cadd                  : file(refs.cadd, checkIfExists: true),
        spliceai              : file(refs.spliceai, checkIfExists: true),
        clinvar               : file(refs.clinvar, checkIfExists: true),
        gnomad                : file(refs.gnomad, checkIfExists: true),
        pfam_domains          : file(refs.pfam_domains, checkIfExists: true),
        alphafold_annotations : file(refs.alphafold_annotations, checkIfExists: true),
        litvar                : refs.litvar ? file(refs.litvar, checkIfExists: true) : null,
        pmc                   : refs.pmc ? file(refs.pmc, checkIfExists: true) : null,
        mastermind            : refs.mastermind ? file(refs.mastermind, checkIfExists: true) : null,
        pgx_gene_panel        : file(refs.pgx_gene_panel, checkIfExists: true),
        gene_rule_set         : file(refs.gene_rule_set, checkIfExists: true),
        acmg_schema           : file(refs.acmg_schema, checkIfExists: true),
    ]

    def runMeta = [
        run_id: workflow.runName,
        session_id: workflow.sessionId,
        workflow_name: workflow.manifest.name ?: 'Stage_5_Clinical_Annotation_PGx_Triage',
        workflow_version: workflow.manifest.version ?: 'unspecified',
        nextflow_version: System.getenv('NXF_VER') ?: 'unknown',
        profile: workflow.profile,
        outdir: params.outdir?.toString() ?: 'results',
    ]

    STAGE5_INPUT_NORMALIZER(ch_stage5_inputs)

    def chMasterAssets = STAGE5_INPUT_NORMALIZER.out.normalized_bundle.map { sample_id, phased_vcf, phased_tbi, _ancestry_metrics_json, _phasing_audit_json, reference_meta ->
        tuple(sample_id, phased_vcf, phased_tbi, reference_meta)
    }

    STAGE5_CLINICAL_TRIAGE(
        STAGE5_INPUT_NORMALIZER.out.ch_pgx_branch,
        STAGE5_INPUT_NORMALIZER.out.ch_prs_branch,
        STAGE5_INPUT_NORMALIZER.out.ch_sf_acmg_branch,
        STAGE5_INPUT_NORMALIZER.out.ch_somatic_onco_branch,
        STAGE5_INPUT_NORMALIZER.out.ch_germline_variant_branch,
        chMasterAssets,
        branchAssets,
        runMeta,
        ch_signer_key,
        ch_signer_pub
    )

    emit:
    pgx_summary = STAGE5_CLINICAL_TRIAGE.out.pgx_summary
    prs_summary = STAGE5_CLINICAL_TRIAGE.out.prs_summary
    sf_summary = STAGE5_CLINICAL_TRIAGE.out.sf_summary
    somatic_summary = STAGE5_CLINICAL_TRIAGE.out.somatic_summary
    germline_summary = STAGE5_CLINICAL_TRIAGE.out.germline_summary
    clinical_bundle = STAGE5_CLINICAL_TRIAGE.out.clinical_bundle
    provenance_fragment = STAGE5_CLINICAL_TRIAGE.out.provenance_fragment
}
