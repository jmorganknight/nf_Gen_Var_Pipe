process ASSEMBLE_CLINICAL_BUNDLE {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${meta?.sample_id ?: 'UNKNOWN'}"

    input:
    tuple val(meta), val(germline_branch_json), val(pgx_branch_json), val(prs_branch_json), val(sf_branch_json), val(somatic_branch_json)

    output:
    tuple val(meta), path('stage5_clinical_bundle.json'), emit: clinical_bundle

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta ?: [:])
    def germlineJson = germline_branch_json.toString()
    def pgxJson = pgx_branch_json.toString()
    def prsJson = prs_branch_json.toString()
    def sfJson = sf_branch_json.toString()
    def somaticJson = somatic_branch_json.toString()

    """
    set -euo pipefail

    cat > sample_meta.json <<'JSON'
${metaJson}
JSON
    cat > germline_branch_payload.json <<'JSON'
${germlineJson}
JSON
    cat > pgx_branch_payload.json <<'JSON'
${pgxJson}
JSON
    cat > prs_branch_payload.json <<'JSON'
${prsJson}
JSON
    cat > sf_branch_payload.json <<'JSON'
${sfJson}
JSON
    cat > somatic_branch_payload.json <<'JSON'
${somaticJson}
JSON

    python3 - <<'PY'
import json
import sys
from pathlib import Path

meta = json.loads(Path('sample_meta.json').read_text(encoding='utf-8'))
def parse_branch_payload(payload_path: Path, branch_name: str):
    text = payload_path.read_text(encoding='utf-8').strip() if payload_path.exists() else ''
    if not text:
        return {
            'status': 'SKIPPED_BY_CLINICAL_DIRECTIVE',
            'skip_reason': 'EMPTY_BRANCH_PAYLOAD',
            'branch': branch_name,
        }
    try:
        payload = json.loads(text)
    except Exception as exc:
        return {
            'status': 'SKIPPED_BY_CLINICAL_DIRECTIVE',
            'skip_reason': f'INVALID_BRANCH_PAYLOAD_JSON:{exc}',
            'branch': branch_name,
        }
    if payload is None:
        return {
            'status': 'SKIPPED_BY_CLINICAL_DIRECTIVE',
            'skip_reason': 'NULL_BRANCH_PAYLOAD',
            'branch': branch_name,
        }
    if not isinstance(payload, dict):
        return {
            'status': 'SKIPPED_BY_CLINICAL_DIRECTIVE',
            'skip_reason': 'NON_OBJECT_BRANCH_PAYLOAD',
            'branch': branch_name,
            'payload': payload,
        }
    return payload


germline = parse_branch_payload(Path('germline_branch_payload.json'), 'germline')
pgx = parse_branch_payload(Path('pgx_branch_payload.json'), 'pgx')
prs = parse_branch_payload(Path('prs_branch_payload.json'), 'prs')
sf = parse_branch_payload(Path('sf_branch_payload.json'), 'sf')
somatic = parse_branch_payload(Path('somatic_branch_payload.json'), 'somatic')

required_meta = [
    'sample_id',
    'patient_id',
    'case_id',
    'intake_validation_token',
    'git_commit_sha',
    'container_digest',
    'policy_version',
    'timestamp_utc',
]

missing = [key for key in required_meta if not str(meta.get(key) or '').strip()]
if missing:
    print('STAGE5_BUNDLE_ASSEMBLY_FATAL: missing required metadata fields: ' + ','.join(missing), file=sys.stderr)
    sys.exit(1)

bundle = {
    'metadata': {
        'sample_id': str(meta['sample_id']).strip(),
        'patient_id': str(meta['patient_id']).strip(),
        'case_id': str(meta['case_id']).strip(),
        'intake_validation_token': str(meta['intake_validation_token']).strip(),
        'git_commit_sha': str(meta['git_commit_sha']).strip(),
        'container_digest': str(meta['container_digest']).strip(),
        'policy_version': str(meta['policy_version']).strip(),
        'timestamp_utc': str(meta['timestamp_utc']).strip(),
    },
    'branches': {
        'germline': germline,
        'pgx': pgx,
        'prs': prs,
        'sf': sf,
        'somatic': somatic,
    },
}

Path('stage5_clinical_bundle.json').write_text(json.dumps(bundle, sort_keys=True), encoding='utf-8')
PY
    """
}