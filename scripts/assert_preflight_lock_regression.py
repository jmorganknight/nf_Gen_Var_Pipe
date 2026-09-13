#!/usr/bin/env python3

import argparse
import hashlib
import json
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(65536), b''):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    parser = argparse.ArgumentParser(description='Verify emitted preflight lock hashes and Stage 6 propagation.')
    parser.add_argument('--preflight-lock', required=True)
    parser.add_argument('--samples-yaml', required=True)
    parser.add_argument('--references-yaml', required=True)
    parser.add_argument('--thresholds-yaml', required=True)
    parser.add_argument('--infrastructure-yaml', required=True)
    parser.add_argument('--stage6-provenance', required=True)
    parser.add_argument('--stage6-precondition', required=True)
    parser.add_argument('--stage6-integrity-audit', required=True)
    parser.add_argument('--stage6-ledger', required=True)
    args = parser.parse_args()

    preflight_lock = Path(args.preflight_lock)
    payload = json.loads(preflight_lock.read_text(encoding='utf-8'))

    require(payload.get('node') == 'PREFLIGHT_INGESTION_GUARD', 'preflight lock node mismatch')
    require(payload.get('preflight_status') == 'STAGE0_PREFLIGHT_LOCK_PASS', 'preflight lock status mismatch')
    require(payload.get('hash_engine') == 'SHA-256', 'preflight lock hash engine mismatch')

    control_files = {
        'samples_yaml': Path(args.samples_yaml),
        'references_yaml': Path(args.references_yaml),
        'thresholds_yaml': Path(args.thresholds_yaml),
        'infrastructure_yaml': Path(args.infrastructure_yaml),
    }

    recorded = payload.get('control_plane_files', {})
    for label, path in control_files.items():
        require(path.exists(), f'missing control-plane input: {path}')
        require(label in recorded, f'missing {label} in preflight lock payload')
        actual = sha256_file(path)
        observed = recorded[label].get('sha256')
        require(actual == observed, f'sha256 mismatch for {label}: expected {actual}, observed {observed}')

    provenance = json.loads(Path(args.stage6_provenance).read_text(encoding='utf-8'))
    precondition = json.loads(Path(args.stage6_precondition).read_text(encoding='utf-8'))
    integrity_audit = json.loads(Path(args.stage6_integrity_audit).read_text(encoding='utf-8'))
    ledger = json.loads(Path(args.stage6_ledger).read_text(encoding='utf-8'))

    expected_lock = str(preflight_lock)
    for payload_name, doc in {
        'stage6_provenance': provenance,
        'stage6_precondition': precondition,
        'stage6_integrity_audit': integrity_audit,
        'stage6_ledger': ledger,
    }.items():
        require(doc.get('preflight_lock') == expected_lock, f'{payload_name} missing expected preflight_lock path')
        require(doc.get('preflight_lock_status') == 'STAGE0_PREFLIGHT_LOCK_PASS', f'{payload_name} missing expected preflight_lock_status')

    print(json.dumps({
        'status': 'PASS',
        'preflight_lock': expected_lock,
        'validated_payloads': ['stage6_provenance', 'stage6_precondition', 'stage6_integrity_audit', 'stage6_ledger'],
    }, indent=2))


if __name__ == '__main__':
    main()