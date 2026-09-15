nextflow.enable.dsl = 2

include { STAGE5_GERMLINE } from './stage5_germline.nf'
include { STAGE5_PGX } from './stage5_pgx.nf'
include { STAGE5_SF } from './stage5_sf.nf'
include { STAGE5_PRS } from './stage5_prs.nf'
include { STAGE5_SOMATIC } from './stage5_somatic.nf'
include { STAGE5_BUILD_MULTI_BRANCH_MANIFEST } from '../modules/local/stage5_isolated_manifest_builder.nf'

workflow STAGE5_ISOLATED_BRANCH_ARCHITECTURE {
    take:
    ch_stage5_inputs

    main:
    def (ch_germline, ch_pgx, ch_sf, ch_prs, ch_somatic) = ch_stage5_inputs.into(5)

    STAGE5_GERMLINE(ch_germline)
    STAGE5_PGX(ch_pgx)
    STAGE5_SF(ch_sf)
    STAGE5_PRS(ch_prs)
    STAGE5_SOMATIC(ch_somatic)

    def ch_builder_script = channel.value(file("${projectDir}/bin/stage5_build_stage5_manifest.py", checkIfExists: true))

    def ch_manifest_bundle = STAGE5_GERMLINE.out.branch_manifest
        .join(STAGE5_PGX.out.branch_manifest)
        .join(STAGE5_SF.out.branch_manifest)
        .join(STAGE5_PRS.out.branch_manifest)
        .join(STAGE5_SOMATIC.out.branch_manifest)
        .join(ch_builder_script)
        .map { sid, germlineManifest, pgxManifest, sfManifest, prsManifest, somaticManifest, manifestBuilderScript ->
            tuple(sid, germlineManifest, pgxManifest, sfManifest, prsManifest, somaticManifest, manifestBuilderScript)
        }

    STAGE5_BUILD_MULTI_BRANCH_MANIFEST(ch_manifest_bundle)

    emit:
    germline_manifest = STAGE5_GERMLINE.out.branch_manifest
    pgx_manifest = STAGE5_PGX.out.branch_manifest
    sf_manifest = STAGE5_SF.out.branch_manifest
    prs_manifest = STAGE5_PRS.out.branch_manifest
    somatic_manifest = STAGE5_SOMATIC.out.branch_manifest
    banked_manifest = STAGE5_BUILD_MULTI_BRANCH_MANIFEST.out.banked_manifest
}
