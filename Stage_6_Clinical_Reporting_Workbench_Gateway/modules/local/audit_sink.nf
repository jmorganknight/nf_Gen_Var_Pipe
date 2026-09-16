process AUDIT_SINK {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc/stage6", mode: 'rellink', overwrite: true, pattern: '*.provenance.json'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    tuple val(meta), path("${meta.sample_id}.provenance.json"), emit: provenance_json
    tuple val(meta), path("${meta.sample_id}.stage6_audit_sink.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path
from datetime import datetime, timezone

sid = '${sid}'
ref_meta = json.loads('''${groovy.json.JsonOutput.toJson(reference_meta)}''')


def sha256_file(path_text: str) -> str:
    p = Path(path_text)
    if not p.exists():
        return ''
    digest = hashlib.sha256()
    with p.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

stage5_provenance_payload = {}
sp = Path('${stage5_provenance_json}')
if sp.exists():
    try:
        stage5_provenance_payload = json.loads(sp.read_text(encoding='utf-8'))
    except json.JSONDecodeError:
        stage5_provenance_payload = {'parse_error': 'invalid_json', 'path': str(sp)}


def flatten_reference_checksums(obj, checksum_index, prefix=''):
    flattened = {}
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == 'reference_asset_checksums':
                continue
            child = f"{prefix}.{key}" if prefix else key
            flattened.update(flatten_reference_checksums(value, checksum_index, child))
        return flattened
    if not isinstance(obj, str):
        return flattened
    if '/' not in obj:
        return flattened
    digest = checksum_index.get(obj, '')
    flattened[prefix or obj] = {
        'path': obj,
        'sha256': digest,
    }
    return flattened


checksum_index = ref_meta.get('reference_asset_checksums', {}) if isinstance(ref_meta, dict) else {}
resolved_reference_checksums = flatten_reference_checksums(ref_meta, checksum_index)

payload = {
    'node': 'AUDIT_SINK',
    'sample_id': sid,
    'generated_utc': datetime.now(timezone.utc).isoformat(),
    'run_mode': '${meta.run_mode ?: 'production'}',
    'validation_token': '${meta.validation_token}',
    'stage2_contamination_status': '${meta.stage2_contamination_status ?: ''}',
    'stage2_contamination_policy_action': '${meta.stage2_contamination_policy_action ?: ''}',
    'stage5_manifest': '${stage5_manifest}',
    'stage5_bundle': {
        'path': '${clinical_bundle_tar_gz}',
        'sha256': sha256_file('${clinical_bundle_tar_gz}'),
    },
    'stage5_provenance_source': {
        'path': '${stage5_provenance_json}',
        'sha256': sha256_file('${stage5_provenance_json}'),
    },
    'stage6_inputs': {
        'acmg_tiered_variants_json': {'path': '${acmg_tiered_variants_json}', 'sha256': sha256_file('${acmg_tiered_variants_json}')},
        'candidate_vus_json': {'path': '${candidate_vus_json}', 'sha256': sha256_file('${candidate_vus_json}')},
        'vus_queue_json': {'path': '${vus_queue_json}', 'sha256': sha256_file('${vus_queue_json}')},
        'sf_artifact': {'path': '${sf_artifact}', 'sha256': sha256_file('${sf_artifact}')},
        'prs_artifact': {'path': '${prs_artifact}', 'sha256': sha256_file('${prs_artifact}')},
        'pgx_artifact': {'path': '${pgx_artifact}', 'sha256': sha256_file('${pgx_artifact}')},
    },
    'reference_assets': ref_meta,
    'reference_asset_checksums': resolved_reference_checksums,
    'upstream_stage5_provenance': stage5_provenance_payload,
}

Path(f'{sid}.provenance.json').write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'audit_sink',
    'run_mode': '${meta.run_mode ?: 'production'}',
    'stage2_contamination_status': '${meta.stage2_contamination_status ?: ''}',
    'stage2_contamination_policy_action': '${meta.stage2_contamination_policy_action ?: ''}',
    'provenance_json': f'{sid}.provenance.json',
    'status': 'PASS',
}
Path(f'{sid}.stage6_audit_sink.fragment.json').write_text(json.dumps(fragment, indent=2) + '\n', encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import json
from pathlib import Path
sid = '${meta.sample_id}'
Path(f'{sid}.provenance.json').write_text(json.dumps({'node': 'AUDIT_SINK', 'sample_id': sid, 'run_mode': '${meta.run_mode ?: 'production'}', 'stage2_contamination_status': '${meta.stage2_contamination_status ?: ''}', 'stage2_contamination_policy_action': '${meta.stage2_contamination_policy_action ?: ''}', 'status': 'PASS', 'stub': True}, indent=2) + '\n', encoding='utf-8')
Path(f'{sid}.stage6_audit_sink.fragment.json').write_text(json.dumps({'sample_id': sid, 'component': 'audit_sink', 'run_mode': '${meta.run_mode ?: 'production'}', 'stage2_contamination_status': '${meta.stage2_contamination_status ?: ''}', 'stage2_contamination_policy_action': '${meta.stage2_contamination_policy_action ?: ''}', 'provenance_json': f'{sid}.provenance.json', 'status': 'PASS'}, indent=2) + '\n', encoding='utf-8')
PYEOF
    """
}