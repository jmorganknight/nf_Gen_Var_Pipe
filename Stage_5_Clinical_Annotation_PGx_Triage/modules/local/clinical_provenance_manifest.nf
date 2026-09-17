process CLINICAL_PROVENANCE_MANIFEST {

    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'

    tag "${sample_id}"

    input:
    tuple val(sample_id), path(pgx_summary_json), path(prs_summary_json), path(sf_acmg_summary_json), path(somatic_onco_summary_json), path(germline_variant_summary_json), path(phased_vcf), path(phased_tbi), val(reference_meta), val(run_meta), path(signer_key), path(signer_pub)

    output:
    tuple val(sample_id), path("${sample_id}.clinical_bundle.tar.gz"), path("${sample_id}.provenance.json"), emit: clinical_bundle
    path "${sample_id}.pgx.fragment.json", emit: fragment

    script:
    def sid = sample_id
    def refJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    def runJson = groovy.json.JsonOutput.toJson(run_meta).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    cat > run_meta.json <<'JSON'
${runJson}
JSON
    cat > reference_meta.json <<'JSON'
${refJson}
JSON

    python3 - <<'PYEOF'
import hashlib
import json
import tarfile
import base64
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sid = '${sid}'
run_meta = json.loads(Path('run_meta.json').read_text(encoding='utf-8'))
reference_meta = json.loads(Path('reference_meta.json').read_text(encoding='utf-8'))

files = {
    'pgx_summary_json': Path('${pgx_summary_json}'),
    'prs_summary_json': Path('${prs_summary_json}'),
    'sf_acmg_summary_json': Path('${sf_acmg_summary_json}'),
    'somatic_onco_summary_json': Path('${somatic_onco_summary_json}'),
    'germline_variant_summary_json': Path('${germline_variant_summary_json}'),
    'phased_vcf': Path('${phased_vcf}'),
    'phased_tbi': Path('${phased_tbi}'),
}

for key, p in files.items():
    if not p.exists():
        raise SystemExit(f'STAGE5_PROVENANCE_FAILURE: missing required artifact {key}={p}')


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def token_for_ref(value):
    if value is None:
        return {'path': None, 'sha256': None, 'kind': 'missing'}
    p = Path(str(value))
    if not p.exists():
        return {'path': str(p), 'sha256': None, 'kind': 'missing'}
    if p.is_dir():
        h = hashlib.sha256()
        for child in sorted([x for x in p.rglob('*') if x.is_file()]):
            h.update(str(child.relative_to(p)).encode('utf-8'))
            h.update(b'\0')
            h.update(sha256_file(child).encode('utf-8'))
            h.update(b'\0')
        return {'path': str(p), 'sha256': h.hexdigest(), 'kind': 'directory'}
    return {'path': str(p), 'sha256': sha256_file(p), 'kind': 'file'}

reference_manifest = {}
for k, v in reference_meta.items():
    if isinstance(v, dict):
        reference_manifest[k] = {sub_k: token_for_ref(sub_v) for sub_k, sub_v in v.items()}
    else:
        reference_manifest[k] = token_for_ref(v)

summary_payload = {
    'sample_id': sid,
    'run_id': run_meta.get('run_id'),
    'workflow_version': run_meta.get('workflow_version'),
    'generated_utc': datetime.now(timezone.utc).isoformat(),
    'summaries': {
        key: str(path.name) for key, path in files.items() if key.endswith('_json')
    },
    'master_assets': {
        'phased_vcf': files['phased_vcf'].name,
        'phased_tbi': files['phased_tbi'].name,
    },
}
Path(f'{sid}.joined_branch_summaries.json').write_text(json.dumps(summary_payload, indent=2) + '\\n', encoding='utf-8')

bundle_path = Path(f'{sid}.clinical_bundle.tar.gz')
provenance_path = Path(f'{sid}.provenance.json')
signer_key_path = Path('${signer_key}')
signer_pub_path = Path('${signer_pub}')

bundle_inputs = [
    files['pgx_summary_json'],
    files['prs_summary_json'],
    files['sf_acmg_summary_json'],
    files['somatic_onco_summary_json'],
    files['germline_variant_summary_json'],
    files['phased_vcf'],
    files['phased_tbi'],
    Path(f'{sid}.joined_branch_summaries.json'),
]

with tarfile.open(bundle_path, 'w:gz') as tar:
    for p in bundle_inputs:
        tar.add(p, arcname=p.name)

input_sha256 = {key: sha256_file(path) for key, path in files.items()}
provenance = {
    'sample_id': sid,
    'run_id': run_meta.get('run_id'),
    'workflow_version': run_meta.get('workflow_version'),
    'workflow_name': run_meta.get('workflow_name'),
    'session_id': run_meta.get('session_id'),
    'execution': {
        'nextflow_version': run_meta.get('nextflow_version'),
        'profile': run_meta.get('profile'),
        'generated_utc': datetime.now(timezone.utc).isoformat(),
    },
    'input_sha256': input_sha256,
    'output_sha256': {},
    'reference_manifest_tokens': reference_manifest,
    'joined_summary_json': f'{sid}.joined_branch_summaries.json',
}
provenance['output_sha256']['clinical_bundle_tar_gz'] = sha256_file(bundle_path)

bundle_digest = provenance['output_sha256']['clinical_bundle_tar_gz']
public_key_fingerprint = sha256_file(signer_pub_path) if signer_pub_path.exists() else sha256_file(signer_key_path)
signature_value = None
if not signer_key_path.exists():
    raise SystemExit(f'STAGE5_RS256_SIGNING_FAILURE: missing signer key {signer_key_path}')

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    private_key = serialization.load_pem_private_key(signer_key_path.read_bytes(), password=None)
    signature_value = base64.b64encode(
        private_key.sign(bundle_digest.encode('utf-8'), padding.PKCS1v15(), hashes.SHA256())
    ).decode('utf-8')
except Exception:
    with tempfile.TemporaryDirectory() as td:
        msg_path = Path(td) / 'bundle.sha256.txt'
        sig_path = Path(td) / 'bundle.sha256.sig'
        msg_path.write_text(bundle_digest, encoding='utf-8')
        completed = subprocess.run(
            ['openssl', 'dgst', '-sha256', '-sign', str(signer_key_path), '-out', str(sig_path), str(msg_path)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        if completed.returncode != 0:
            raise SystemExit(f'STAGE5_RS256_SIGNING_FAILURE: {completed.stderr.strip()}')
        signature_value = base64.b64encode(sig_path.read_bytes()).decode('utf-8')

provenance['digital_signature'] = {
    'signature_algorithm': 'RS256',
    'signature_value': signature_value,
    'signer_id': signer_key_path.stem,
    'public_key_fingerprint': public_key_fingerprint,
    'signed_object': bundle_path.name,
    'signed_digest_sha256': bundle_digest,
}
provenance_path.write_text(json.dumps(provenance, indent=2) + '\\n', encoding='utf-8')

fragment = {
    'sample_id': sid,
    'component': 'pgx',
    'pgx_summary_json': files['pgx_summary_json'].name,
    'prs_summary_json': files['prs_summary_json'].name,
    'sf_acmg_summary_json': files['sf_acmg_summary_json'].name,
    'somatic_onco_summary_json': files['somatic_onco_summary_json'].name,
    'germline_variant_summary_json': files['germline_variant_summary_json'].name,
    'clinical_bundle_tar_gz': bundle_path.name,
    'provenance_json': provenance_path.name,
    'bundle_sha256': provenance['output_sha256']['clinical_bundle_tar_gz'],
    'signature_algorithm': provenance['digital_signature']['signature_algorithm'],
    'public_key_fingerprint': provenance['digital_signature']['public_key_fingerprint'],
}
Path(f'{sid}.pgx.fragment.json').write_text(json.dumps(fragment, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """

    stub:
    """
    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${sample_id}'
bundle_path = Path(f'{sid}.clinical_bundle.tar.gz')
provenance_path = Path(f'{sid}.provenance.json')
Path(f'{sid}.joined_branch_summaries.json').write_text(json.dumps({'sample_id': sid, 'stub': True}, indent=2) + '\\n', encoding='utf-8')
bundle_path.write_bytes(b'STUB_BUNDLE\\n')
provenance = {
    'sample_id': sid,
    'workflow_name': 'CLINICAL_PROVENANCE_MANIFEST',
    'output_sha256': {'clinical_bundle_tar_gz': 'stub'},
    'digital_signature': {
        'signature_algorithm': 'RS256',
        'signature_value': 'STUB',
        'signer_id': 'clinical_signer',
        'public_key_fingerprint': 'STUB',
        'signed_object': bundle_path.name,
        'signed_digest_sha256': 'stub',
    },
}
provenance_path.write_text(json.dumps(provenance, indent=2) + '\\n', encoding='utf-8')
fragment = {
    'sample_id': sid,
    'component': 'pgx',
    'clinical_bundle_tar_gz': bundle_path.name,
    'provenance_json': provenance_path.name,
    'bundle_sha256': 'stub',
    'signature_algorithm': 'RS256',
    'public_key_fingerprint': 'STUB',
}
Path(f'{sid}.pgx.fragment.json').write_text(json.dumps(fragment, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
