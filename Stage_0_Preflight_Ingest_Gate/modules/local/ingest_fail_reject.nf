/*
 * Stage 0.5 — INGEST_FAIL_REJECT
 * Sinks invalid intake tokens and emits a signed rejection audit payload.
 */

process INGEST_FAIL_REJECT {

    label 'process_low'
    container 'wes-onco-core:1.0.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/audit_and_qc" }, mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(_fastq_1), path(_fastq_2), path(intake_token), path(intake_report)
    path signer_key
    path signer_pub

    output:
    tuple val(meta), path("${meta.sample_id}.ingest_rejection_audit.json"), emit: rejection_audit

    script:
    def sid = meta.sample_id
    def platform = (meta.sequencer?.platform ?: 'unknown').toString().toLowerCase()
    def consentTokensJson = groovy.json.JsonOutput.toJson(meta.consent_tokens ?: [:]).replace('\n', ' ').replace('\r', '')
    def diagnosisJson = groovy.json.JsonOutput.toJson(meta.diagnosis ?: [:]).replace('\n', ' ').replace('\r', '')
    def specimenJson = groovy.json.JsonOutput.toJson(meta.specimen ?: [:]).replace('\n', ' ').replace('\r', '')
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import base64
import hashlib
import json
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sid = "${sid}"
platform = "${platform}"
token_text = Path("${intake_token}").read_text(encoding='utf-8').strip()
report = json.loads(Path("${intake_report}").read_text(encoding='utf-8'))
out_path = Path(f"{sid}.ingest_rejection_audit.json")


def canonical_json(data):
    return json.dumps(data, sort_keys=True, separators=(',', ':'))


def sha256_hex(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def try_rs256_signature(message: str):
    key_path = Path("${signer_key}")
    pub_path = Path("${signer_pub}")
    if not key_path.exists():
        return None, 'SHA256_FALLBACK'

    public_key_fingerprint = sha256_hex(pub_path.read_text(encoding='utf-8')) if pub_path.exists() else sha256_hex(key_path.read_text(encoding='utf-8'))

    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding

        private_key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
        signature = private_key.sign(
            message.encode('utf-8'),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        return {
            'alg': 'RS256',
            'signature_b64': base64.b64encode(signature).decode('utf-8'),
            'key_fingerprint': public_key_fingerprint,
            'key_source': str(key_path),
        }, 'RS256'
    except Exception:
        pass

    try:
        with tempfile.TemporaryDirectory() as td:
            msg_path = Path(td) / 'message.json'
            sig_path = Path(td) / 'signature.bin'
            msg_path.write_text(message, encoding='utf-8')
            subprocess.run(
                ['openssl', 'dgst', '-sha256', '-sign', str(key_path), '-out', str(sig_path), str(msg_path)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            signature = sig_path.read_bytes()
        return {
            'alg': 'RS256',
            'signature_b64': base64.b64encode(signature).decode('utf-8'),
            'key_fingerprint': public_key_fingerprint,
            'key_source': str(key_path),
        }, 'RS256'
    except Exception:
        return None, 'SHA256_FALLBACK'


payload = {
    'node': 'INGEST_FAIL_REJECT',
    'sample_id': sid,
    'patient_id': '${meta.patient_id ?: meta.sample_id}',
    'case_id': '${meta.case_id ?: meta.patient_id ?: meta.sample_id}',
    'platform': platform,
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'intake_validation_token': token_text,
    'consent_tokens': json.loads('''${consentTokensJson}'''),
    'diagnosis': json.loads('''${diagnosisJson}'''),
    'specimen': json.loads('''${specimenJson}'''),
    'rejection_reasons': report.get('rejection_reasons', []),
    'intake_validation_report': report,
}

signing_payload = canonical_json(payload)
signature, signature_alg = try_rs256_signature(signing_payload)
if signature is None:
    signature = {
        'alg': 'SHA256',
        'signature_hex': sha256_hex(signing_payload),
        'key_fingerprint': sha256_hex('SHA256_FALLBACK'),
        'key_source': 'SHA256_FALLBACK',
    }

payload['signature'] = signature
payload['signature_algorithm'] = signature_alg
payload['payload_checksum_sha256'] = sha256_hex(signing_payload)

with out_path.open('w', encoding='utf-8') as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    """

    stub:
    """
    printf '{"node":"INGEST_FAIL_REJECT","sample_id":"%s","signature_algorithm":"RS256","stub":true}' "${meta.sample_id}" > "${meta.sample_id}.ingest_rejection_audit.json"
    """
}