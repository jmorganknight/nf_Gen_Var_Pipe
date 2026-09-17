nextflow.enable.dsl = 2

process SIGN_OFF_CLINICAL_BUNDLE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    publishDir "${params.outdir}/clinical_release", mode: 'copy', overwrite: true, pattern: '*_production_release.*'
    tag "${sample_id ?: 'UNKNOWN'}"

    input:
    tuple val(sample_id), path(clinical_bundle_json)
    val git_commit_sha
    val container_digest

    output:
    tuple val(sample_id), path("${sample_id}_production_release.json"), path("${sample_id}_production_release.sha256"), emit: production_release

    script:
    def safeSampleId = sample_id?.toString()?.trim()
    if (!safeSampleId) {
        throw new IllegalStateException('STAGE5_SIGN_OFF_FATAL: sample_id is required for release sign-off')
    }
    def safeGitCommitSha = git_commit_sha?.toString()?.trim()
    if (!safeGitCommitSha) {
        throw new IllegalStateException('STAGE5_SIGN_OFF_FATAL: git_commit_sha is required for release sign-off')
    }
    def safeContainerDigest = container_digest?.toString()?.trim()
    if (!safeContainerDigest) {
        throw new IllegalStateException('STAGE5_SIGN_OFF_FATAL: container_digest is required for release sign-off')
    }

    """
    set -euo pipefail

    python3 - <<'PY'
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

sample_id = ${groovy.json.JsonOutput.toJson(safeSampleId)}
git_commit_sha = ${groovy.json.JsonOutput.toJson(safeGitCommitSha)}
container_digest = ${groovy.json.JsonOutput.toJson(safeContainerDigest)}

bundle_path = Path(${groovy.json.JsonOutput.toJson(clinical_bundle_json.toString())})
if not bundle_path.exists() or not bundle_path.is_file():
    raise SystemExit(f"STAGE5_SIGN_OFF_FATAL: clinical bundle not found: {bundle_path}")

try:
    original_payload = json.loads(bundle_path.read_text(encoding='utf-8'))
except json.JSONDecodeError as exc:
    raise SystemExit(f"STAGE5_SIGN_OFF_FATAL: invalid clinical bundle JSON: {exc}") from exc

canonical_bundle = json.dumps(original_payload, sort_keys=True, separators=(',', ':'))
bundle_sha256 = hashlib.sha256(canonical_bundle.encode('utf-8')).hexdigest()

envelope = {
    'sample_id': sample_id,
    'audit_trail': {
        'timestamp_utc': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'git_commit_sha': git_commit_sha,
        'container_digest': container_digest,
        'bundle_sha256': bundle_sha256,
    },
    'clinical_payload': json.loads(canonical_bundle),
}

release_json_path = Path(f"{sample_id}_production_release.json")
release_sha_path = Path(f"{sample_id}_production_release.sha256")

release_json_path.write_text(json.dumps(envelope, sort_keys=True, separators=(',', ':')), encoding='utf-8')
release_sha_path.write_text(bundle_sha256 + '\\n', encoding='utf-8')
PY
    """
}
