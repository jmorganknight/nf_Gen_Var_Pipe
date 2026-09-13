nextflow.enable.dsl = 2

include { PGX_DIPLOTYPE_RESOLVER } from '../../modules/local/pgx_diplotype_resolver.nf'
include { PRS_RISK_SCORE_ENGINE } from '../../modules/local/prs_risk_score_engine.nf'
include { ACMG_SF73_CLASSIFIER } from '../../modules/local/acmg_sf73_classifier.nf'
include { GERMLINE_TRIAGE_ENGINE } from '../../modules/local/germline_triage_engine.nf'
include { SOMATIC_ONCO_TRIAGE } from '../../modules/local/somatic_onco_triage.nf'
include { STAGE5_BRANCH_OPT_OUT as STAGE5_PRS_BRANCH_OPT_OUT } from '../../modules/local/stage5_branch_opt_out.nf'
include { STAGE5_BRANCH_OPT_OUT as STAGE5_SF_BRANCH_OPT_OUT } from '../../modules/local/stage5_branch_opt_out.nf'
include { CLINICAL_PROVENANCE_MANIFEST } from '../../modules/local/clinical_provenance_manifest.nf'

workflow STAGE5_CLINICAL_TRIAGE {
    take:
    ch_pgx_branch
    ch_prs_branch
    ch_sf_acmg_branch
    ch_somatic_onco_branch
    ch_germline_variant_branch
    ch_master_assets
    branch_assets
    run_meta
    ch_signer_key
    ch_signer_pub

    main:
    PGX_DIPLOTYPE_RESOLVER(ch_pgx_branch.map { sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, reference_meta ->
        def meta = [
            sample_id: sample_id,
            ancestry_metrics_json: ancestry_metrics_json.toString(),
            phasing_audit_json: phasing_audit_json.toString(),
            validation_token: 'VALID_PASS|VARIANTS_HARMONIZED',
            run_id: run_meta?.run_id ?: sample_id,
            workflow_version: run_meta?.workflow_version ?: 'unspecified',
            phased_vcf: phased_vcf.toString(),
            phased_vcf_tbi: phased_tbi.toString()
        ]
        tuple(meta, phased_vcf, phased_tbi, reference_meta, branch_assets.pgx_cli_script)
    })

    def prsEnabled = params.enable_prs_branch == null ? true : params.enable_prs_branch as boolean
    if (prsEnabled) {
        PRS_RISK_SCORE_ENGINE(ch_prs_branch.map { sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, _reference_meta ->
            tuple(sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, branch_assets.pgx_gene_panel, branch_assets.gene_rule_set, branch_assets.stage5_engine_script)
        })
    } else {
        STAGE5_PRS_BRANCH_OPT_OUT(ch_prs_branch.map { sample_id, _a, _b, _c, _d, _e -> tuple(sample_id, 'prs', 'prs_consent: OPT_OUT') })
    }

    def sfEnabled = params.enable_sf_branch == null ? true : params.enable_sf_branch as boolean
    if (sfEnabled) {
        ACMG_SF73_CLASSIFIER(ch_sf_acmg_branch.map { sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, _reference_meta ->
            tuple(sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, branch_assets.acmg_schema, branch_assets.clinvar, branch_assets.gnomad, branch_assets.pgx_gene_panel, branch_assets.stage5_engine_script)
        })
    } else {
        STAGE5_SF_BRANCH_OPT_OUT(ch_sf_acmg_branch.map { sample_id, _a, _b, _c, _d, _e -> tuple(sample_id, 'sf_acmg', 'sf_consent: OPT_OUT') })
    }

    GERMLINE_TRIAGE_ENGINE(ch_germline_variant_branch.map { sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, _reference_meta ->
        tuple(sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, branch_assets.revel, branch_assets.alphamissense, branch_assets.cadd, branch_assets.spliceai, branch_assets.clinvar, branch_assets.gnomad, branch_assets.pfam_domains, branch_assets.alphafold_annotations, branch_assets.litvar, branch_assets.pmc, branch_assets.mastermind, branch_assets.stage5_engine_script)
    })

    SOMATIC_ONCO_TRIAGE(ch_somatic_onco_branch.map { sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, _reference_meta ->
        tuple(sample_id, phased_vcf, phased_tbi, ancestry_metrics_json, phasing_audit_json, branch_assets.revel, branch_assets.alphamissense, branch_assets.cadd, branch_assets.spliceai, branch_assets.clinvar, branch_assets.gnomad, branch_assets.pfam_domains, branch_assets.alphafold_annotations, branch_assets.litvar, branch_assets.pmc, branch_assets.mastermind, branch_assets.stage5_engine_script)
    })

    def prsSummary = prsEnabled ? PRS_RISK_SCORE_ENGINE.out.summary : STAGE5_PRS_BRANCH_OPT_OUT.out.summary
    def sfSummary = sfEnabled ? ACMG_SF73_CLASSIFIER.out.summary : STAGE5_SF_BRANCH_OPT_OUT.out.summary

    def joinedBranches = PGX_DIPLOTYPE_RESOLVER.out.summary
        .join(prsSummary)
        .join(sfSummary)
        .join(SOMATIC_ONCO_TRIAGE.out.summary)
        .join(GERMLINE_TRIAGE_ENGINE.out.summary)
        .join(ch_master_assets)
        .map { sample_id, pgx_summary, prs_summary, sf_summary, somatic_summary, germline_summary, phased_vcf, phased_tbi, reference_meta ->
            tuple(sample_id, pgx_summary, prs_summary, sf_summary, somatic_summary, germline_summary, phased_vcf, phased_tbi, reference_meta, run_meta)
        }

    def signedBundleInput = joinedBranches
        .combine(ch_signer_key)
        .combine(ch_signer_pub)
        .map { sample_id, pgx_summary, prs_summary, sf_summary, somatic_summary, germline_summary, phased_vcf, phased_tbi, reference_meta, run_meta_value, signer_key, signer_pub ->
            tuple(sample_id, pgx_summary, prs_summary, sf_summary, somatic_summary, germline_summary, phased_vcf, phased_tbi, reference_meta, run_meta_value, signer_key, signer_pub)
        }

    CLINICAL_PROVENANCE_MANIFEST(signedBundleInput)

    emit:
    pgx_summary = PGX_DIPLOTYPE_RESOLVER.out.summary
    prs_summary = prsSummary
    sf_summary = sfSummary
    somatic_summary = SOMATIC_ONCO_TRIAGE.out.summary
    germline_summary = GERMLINE_TRIAGE_ENGINE.out.summary
    clinical_bundle = CLINICAL_PROVENANCE_MANIFEST.out.clinical_bundle
    provenance_fragment = CLINICAL_PROVENANCE_MANIFEST.out.fragment
}
