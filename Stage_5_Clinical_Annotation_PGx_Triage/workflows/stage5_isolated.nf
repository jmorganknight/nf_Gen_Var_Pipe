nextflow.enable.dsl = 2

include { STAGE5_GERMLINE } from './stage5_germline.nf'
include { STAGE5_PGX } from './stage5_pgx.nf'
include { STAGE5_SF } from './stage5_sf.nf'
include { STAGE5_PRS } from './stage5_prs.nf'
include { STAGE5_SOMATIC } from './stage5_somatic.nf'
include { STAGE5_BUILD_MULTI_BRANCH_MANIFEST } from '../modules/local/stage5_isolated_manifest_builder.nf'

def branchRequested(List requestedBranches, String branchName) {
    def normalized = (requestedBranches ?: []).collect { item -> item?.toString()?.trim()?.toLowerCase() }.findAll { item -> item }
    normalized.contains(branchName)
}

process STAGE5_EMIT_BRANCH_SKIP_MANIFEST {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}:${branch_name}"

    input:
    tuple val(sample_id), val(branch_name), val(requested_branches)

    output:
    tuple val(sample_id), val(branch_name), path("${sample_id}.${branch_name}.branch_manifest.skip.json"), emit: branch_manifest

    script:
    def requestedJson = groovy.json.JsonOutput.toJson(requested_branches ?: [])
    """
    set -euo pipefail
    cat > "${sample_id}.${branch_name}.branch_manifest.skip.json" <<JSON
{
  "sample_id": "${sample_id}",
  "branch": "${branch_name}",
  "status": "SKIPPED_BY_CLINICAL_DIRECTIVE",
  "skip_reason": "branch_not_requested_in_manifest_control_plane",
  "requested_branches": ${requestedJson},
  "audit_class": "CAP_CLIA_BRANCH_BYPASS",
  "primary_vcf": "",
  "primary_vcf_tbi": "",
  "primary_vcf_sha256": "",
  "primary_vcf_tbi_sha256": "",
  "input_rows": 0,
  "output_rows": 0,
  "dropped_rows": 0
}
JSON
    """
}

process STAGE5_ANNOTATE_REQUESTED_BRANCH_MANIFEST {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${sample_id}:${branch_name}"

    input:
    tuple val(sample_id), val(branch_name), path(branch_manifest), val(requested_branches)

    output:
    tuple val(sample_id), val(branch_name), path("${sample_id}.${branch_name}.branch_manifest.audited.json"), emit: branch_manifest

    script:
    def requestedJson = groovy.json.JsonOutput.toJson(requested_branches ?: [])
    """
    set -euo pipefail
    printf '%s' '${requestedJson}' > requested_branches.json
    python3 - "${branch_manifest}" "${sample_id}" "${branch_name}" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
sid = sys.argv[2]
branch = sys.argv[3]
dst = pathlib.Path(f"{sid}.{branch}.branch_manifest.audited.json")
payload = json.loads(src.read_text(encoding='utf-8'))
payload['status'] = 'COMPLETED'
payload['skip_reason'] = ''
payload['requested_branches'] = json.loads(pathlib.Path('requested_branches.json').read_text(encoding='utf-8'))
payload['audit_class'] = 'CAP_CLIA_BRANCH_EXECUTED'
dst.write_text(json.dumps(payload, ensure_ascii=True, sort_keys=True), encoding='utf-8')
PY
    """
}

workflow STAGE5_ISOLATED_BRANCH_ARCHITECTURE {
    take:
    ch_stage5_inputs

    main:
    def ch_branch_routes = ch_stage5_inputs.flatMap { sid, phasedVcf, phasedTbi, ancestryJson, phasingAuditJson, refs, requestedBranches, samplePayload, runMode ->
        def requested = requestedBranches as List
        ['germline', 'pgx', 'sf', 'prs', 'somatic'].collect { branchName ->
            tuple(sid, branchName, branchRequested(requested, branchName), phasedVcf, phasedTbi, ancestryJson, phasingAuditJson, refs, requested, samplePayload, runMode)
        }
    }

    def ch_routed = ch_branch_routes.branch { row ->
        requested: row[2] as boolean
        skipped: !(row[2] as boolean)
    }

    def ch_requested_by_branch = ch_routed.requested.branch { row ->
        germline: row[1] == 'germline'
        pgx: row[1] == 'pgx'
        sf: row[1] == 'sf'
        prs: row[1] == 'prs'
        somatic: row[1] == 'somatic'
    }

    STAGE5_GERMLINE(ch_requested_by_branch.germline.map { row -> tuple(row[0], row[3], row[4], row[5], row[6], row[7]) })
    STAGE5_PGX(ch_requested_by_branch.pgx.map { row -> tuple(row[0], row[3], row[4], row[5], row[6], row[7]) })
    STAGE5_SF(ch_requested_by_branch.sf.map { row -> tuple(row[0], row[3], row[4], row[5], row[6], row[7]) })
    STAGE5_PRS(ch_requested_by_branch.prs.map { row -> tuple(row[0], row[3], row[4], row[5], row[6], row[7]) })
    STAGE5_SOMATIC(ch_requested_by_branch.somatic.map { row -> tuple(row[0], row[3], row[4], row[5], row[6], row[7]) })

    STAGE5_EMIT_BRANCH_SKIP_MANIFEST(ch_routed.skipped.map { row -> tuple(row[0], row[1], row[8]) })

    def ch_requested_meta = ch_routed.requested.map { row ->
        def key = "${row[0]}::${row[1]}"
        tuple(key, row[0], row[1], row[8])
    }
    def ch_requested_manifests = STAGE5_GERMLINE.out.branch_manifest.map { sid, manifest -> tuple("${sid}::germline", sid, 'germline', manifest) }
        .mix(STAGE5_PGX.out.branch_manifest.map { sid, manifest -> tuple("${sid}::pgx", sid, 'pgx', manifest) })
        .mix(STAGE5_SF.out.branch_manifest.map { sid, manifest -> tuple("${sid}::sf", sid, 'sf', manifest) })
        .mix(STAGE5_PRS.out.branch_manifest.map { sid, manifest -> tuple("${sid}::prs", sid, 'prs', manifest) })
        .mix(STAGE5_SOMATIC.out.branch_manifest.map { sid, manifest -> tuple("${sid}::somatic", sid, 'somatic', manifest) })

    def ch_requested_annotation_inputs = ch_requested_meta
        .join(ch_requested_manifests)
        .map { _key, sid, branchName, requestedBranches, _sid2, _branch2, manifest ->
            tuple(sid, branchName, manifest, requestedBranches)
        }

    STAGE5_ANNOTATE_REQUESTED_BRANCH_MANIFEST(ch_requested_annotation_inputs)

    def ch_all_branch_manifests = STAGE5_ANNOTATE_REQUESTED_BRANCH_MANIFEST.out.branch_manifest
        .mix(STAGE5_EMIT_BRANCH_SKIP_MANIFEST.out.branch_manifest)

    def ch_sample_payload_by_sample = ch_stage5_inputs
        .map { sid, _phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, _refs, _requestedBranches, samplePayload, _runMode ->
            tuple(sid, samplePayload)
        }
        .unique()

    def ch_run_mode_by_sample = ch_stage5_inputs
        .map { sid, _phasedVcf, _phasedTbi, _ancestryJson, _phasingAuditJson, _refs, _requestedBranches, _samplePayload, runMode ->
            tuple(sid, runMode?.toString()?.trim()?.toLowerCase() ?: 'production')
        }
        .unique()

    def builderCandidates = [
        new File(projectDir.toString(), 'bin/stage5_build_stage5_manifest.py'),
        new File(projectDir.toString(), 'Stage_5_Clinical_Annotation_PGx_Triage/bin/stage5_build_stage5_manifest.py')
    ]
    def builderScript = builderCandidates.find { candidate -> candidate.exists() }
    if (builderScript == null) {
        throw new IllegalStateException('STAGE5_PRECONDITION_FAILURE: missing stage5_build_stage5_manifest.py helper script')
    }
    def builderScriptFile = file(builderScript, checkIfExists: true)

    def ch_manifest_grouped = ch_all_branch_manifests
        .groupTuple()
        .map { sid, branchNames, manifestPaths ->
            def byBranch = [:]
            [branchNames, manifestPaths].transpose().each { pair ->
                byBranch[pair[0].toString()] = pair[1]
            }
            def required = ['germline', 'pgx', 'sf', 'prs', 'somatic']
            def missing = required.findAll { branchName -> !byBranch.containsKey(branchName) }
            if (!missing.isEmpty()) {
                throw new IllegalStateException("STAGE5_ROUTING_FAILURE: incomplete branch manifest set for sample '${sid}' missing=${missing}")
            }
            tuple(sid, byBranch['germline'], byBranch['pgx'], byBranch['sf'], byBranch['prs'], byBranch['somatic'])
        }

    def ch_manifest_bundle = ch_manifest_grouped
        .join(ch_sample_payload_by_sample)
        .join(ch_run_mode_by_sample)
        .map { sid, germlineManifest, pgxManifest, sfManifest, prsManifest, somaticManifest, samplePayload, runMode ->
            tuple(sid, runMode, samplePayload, germlineManifest, pgxManifest, sfManifest, prsManifest, somaticManifest, builderScriptFile)
        }

    STAGE5_BUILD_MULTI_BRANCH_MANIFEST(ch_manifest_bundle)

    emit:
    banked_manifest = STAGE5_BUILD_MULTI_BRANCH_MANIFEST.out.banked_manifest
}
