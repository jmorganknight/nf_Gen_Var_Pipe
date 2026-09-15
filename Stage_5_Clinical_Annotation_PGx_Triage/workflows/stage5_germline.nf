nextflow.enable.dsl = 2

include { STAGE5_GERMLINE_VEP_STREAM; STAGE5_GERMLINE_CLINVAR_STREAM; STAGE5_GERMLINE_GNOMAD_STREAM; STAGE5_GERMLINE_JOIN_EVIDENCE; RULE_COMP_SYNTHESIS; RULE_LOSS_TRUNCATION; RULE_FREQ_CHECK; STAGE5_GERMLINE_BAYES_PARTITION; STAGE5_GERMLINE_ZERO_LOSS_GATE; STAGE5_VUS_HGMD_TRIAGE; STAGE5_GERMLINE_BRANCH_MANIFEST } from '../modules/local/stage5_germline_isolated.nf'

workflow STAGE5_GERMLINE {
    take:
    ch_stage5_inputs

    main:
    def (ch_vep, ch_clin, ch_gno, ch_anchor, ch_join_anchor) = ch_stage5_inputs.into(5)

    STAGE5_GERMLINE_VEP_STREAM(ch_vep.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs -> tuple(sid, [:], phasedVcf, refs) })
    STAGE5_GERMLINE_CLINVAR_STREAM(ch_clin.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs -> tuple(sid, [:], phasedVcf, refs) })
    STAGE5_GERMLINE_GNOMAD_STREAM(ch_gno.map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs -> tuple(sid, [:], phasedVcf, refs) })

    def ch_join_input = STAGE5_GERMLINE_VEP_STREAM.out.stream_tsv
        .join(STAGE5_GERMLINE_CLINVAR_STREAM.out.stream_tsv)
        .join(STAGE5_GERMLINE_GNOMAD_STREAM.out.stream_tsv)
        .map { sid, vepTsv, _vepAudit, clinTsv, _clinAudit, gnoTsv, _gnoAudit -> tuple(sid, vepTsv, clinTsv, gnoTsv) }

    STAGE5_GERMLINE_JOIN_EVIDENCE(ch_join_input)

    RULE_COMP_SYNTHESIS(STAGE5_GERMLINE_JOIN_EVIDENCE.out.joined.map { sid, joinedTsv, _joinAudit -> tuple(sid, joinedTsv) })
    RULE_LOSS_TRUNCATION(STAGE5_GERMLINE_JOIN_EVIDENCE.out.joined.map { sid, joinedTsv, _joinAudit -> tuple(sid, joinedTsv) })
    RULE_FREQ_CHECK(
        STAGE5_GERMLINE_JOIN_EVIDENCE.out.joined
            .join(ch_anchor.map { sid, _phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs -> tuple(sid, refs.hotspot_exception_registry ?: '') })
            .map { sid, joinedTsv, _joinAudit, hotspotRegistry -> tuple(sid, joinedTsv, hotspotRegistry) }
    )

    def ch_bayes_input = ch_join_anchor
        .map { sid, phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, _refs -> tuple(sid, phasedVcf) }
        .join(STAGE5_GERMLINE_JOIN_EVIDENCE.out.joined.map { sid, joinedTsv, _joinAudit -> tuple(sid, joinedTsv) })
        .join(RULE_COMP_SYNTHESIS.out.rules)
        .join(RULE_LOSS_TRUNCATION.out.rules)
        .join(RULE_FREQ_CHECK.out.rules)
        .map { sid, phasedVcf, joinedTsv, compRules, lossRules, freqRules -> tuple(sid, phasedVcf, joinedTsv, compRules, lossRules, freqRules) }

    STAGE5_GERMLINE_BAYES_PARTITION(ch_bayes_input)
    STAGE5_GERMLINE_ZERO_LOSS_GATE(STAGE5_GERMLINE_BAYES_PARTITION.out.partition_audit)

    STAGE5_VUS_HGMD_TRIAGE(
        STAGE5_GERMLINE_BAYES_PARTITION.out.vus
            .join(STAGE5_GERMLINE_BAYES_PARTITION.out.scores)
            .join(ch_anchor.map { sid, _phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, refs -> tuple(sid, refs.hgmd_db ?: refs.hgmd ?: '') })
            .map { sid, vusVcf, _vusTbi, scoresJson, hgmdDb -> tuple(sid, vusVcf, scoresJson, hgmdDb) }
    )

    def ch_branch_manifest_input = STAGE5_GERMLINE_BAYES_PARTITION.out.benign
        .join(STAGE5_GERMLINE_BAYES_PARTITION.out.pathogenic)
        .join(STAGE5_GERMLINE_BAYES_PARTITION.out.vus)
        .join(STAGE5_VUS_HGMD_TRIAGE.out.triaged_vus)
        .join(STAGE5_GERMLINE_BAYES_PARTITION.out.partition_audit)
        .join(STAGE5_GERMLINE_ZERO_LOSS_GATE.out.zero_loss)
        .join(STAGE5_VUS_HGMD_TRIAGE.out.triage_audit)
        .map { sid, benignVcf, _benignTbi, pathogenicVcf, _pathogenicTbi, vusVcf, _vusTbi, triagedVusVcf, _triagedVusTbi, partitionAudit, zeroLossAudit, hgmdAudit ->
            tuple(sid, benignVcf, pathogenicVcf, vusVcf, triagedVusVcf, partitionAudit, zeroLossAudit, hgmdAudit)
        }

    STAGE5_GERMLINE_BRANCH_MANIFEST(ch_branch_manifest_input)

    emit:
    branch_manifest = STAGE5_GERMLINE_BRANCH_MANIFEST.out.branch_manifest
}
