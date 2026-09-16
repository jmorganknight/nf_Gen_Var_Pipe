#!/usr/bin/env python3
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def is_svd_prefix(prefix):
    if not prefix:
        return False
    p = str(prefix)
    return Path(p + '.UD').exists() and Path(p + '.mu').exists() and Path(p + '.bed').exists()


def normalize_prefix(candidate):
    if not candidate:
        return None
    text = str(candidate)
    if text.endswith('.UD'):
        return text[:-3]
    if text.endswith('.mu'):
        return text[:-3]
    if text.endswith('.bed'):
        return text[:-4]
    return text


def resolve_verifybamid2_binary():
    candidates = [
        shutil.which('verifybamid2'),
        shutil.which('VerifyBamID2'),
        shutil.which('VerifyBamID'),
        '/opt/micromamba/envs/gen-var/bin/verifybamid2',
        '/opt/micromamba/envs/gen-var/bin/VerifyBamID2',
        '/opt/micromamba/envs/gen-var/bin/VerifyBamID',
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def probe_verifybamid2_version(binary_path):
    if not binary_path:
        return None
    probe = subprocess.run([binary_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    merged = "\n".join([probe.stdout or '', probe.stderr or ''])
    match = re.search(r'Version\s*:\s*([0-9]+(?:\.[0-9]+)+)', merged, flags=re.IGNORECASE)
    if match:
        return match.group(1)
    return None


def resolve_reference_fasta(refs_payload):
    declared = refs_payload.get('reference_genome') or refs_payload.get('grch38_fasta')
    if declared and Path(str(declared)).exists():
        return str(declared)
    ref_names = {
        'hs38DH.fa',
        'GRCh38_full_analysis_set_plus_decoy_hla.fa',
        'GRCh38.fasta',
        'Homo_sapiens_assembly38.fasta',
    }
    root = Path('/opt/reference')
    if root.exists():
        for cand in root.rglob('*'):
            if cand.is_file() and cand.name in ref_names:
                return str(cand)
    return None


def resolve_svd_prefix(refs_payload):
    raw_candidates = [
        refs_payload.get('verifybamid2_svd_prefix'),
        refs_payload.get('stage2_verifybamid2_svd_prefix'),
        refs_payload.get('verifybamid2_ud'),
        refs_payload.get('verifybamid2_ud_path'),
        refs_payload.get('stage2_verifybamid2_ud_path'),
    ]
    for raw in raw_candidates:
        prefix = normalize_prefix(raw)
        if is_svd_prefix(prefix):
            return prefix
    scan_roots = [
        Path('/opt/conda/share'),
        Path('/opt/reference/verifybamid2'),
        Path('/opt/reference'),
        Path('/opt/micromamba/envs/gen-var/share'),
        Path('/usr/share'),
    ]
    discovered = []
    for root in scan_roots:
        if not root.exists():
            continue
        for ud_file in root.rglob('*.UD'):
            prefix = str(ud_file)[:-3]
            if is_svd_prefix(prefix):
                discovered.append(prefix)
    if not discovered:
        return None
    def score(prefix):
        s = 0
        lower = prefix.lower()
        if '1000g.phase3.100k.b38' in lower:
            s += 100
        if '1000g.phase3' in lower:
            s += 40
        if '.b38.' in lower:
            s += 30
        if 'exome' in lower:
            s += 10
        return s
    return sorted(discovered, key=score, reverse=True)[0]


def resolve_bed_path(refs_payload, svd_prefix):
    candidates = [
        refs_payload.get('verifybamid2_bed'),
        refs_payload.get('capture_wes_bed'),
        refs_payload.get('onco_target_bed'),
        f"{svd_prefix}.bed" if svd_prefix else None,
    ]
    for candidate in candidates:
        if candidate and Path(str(candidate)).exists():
            return str(candidate)
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--meta-json', required=True)
    parser.add_argument('--refs-json', required=True)
    parser.add_argument('--bam', required=True)
    parser.add_argument('--precondition-audit', required=True)
    parser.add_argument('--limit', required=True, type=float)
    parser.add_argument('--run-mode', required=True)
    parser.add_argument('--fail-closed', required=True)
    parser.add_argument('--non-evaluable-fail-closed', required=True)
    args = parser.parse_args()

    meta = json.loads(args.meta_json)
    refs = json.loads(args.refs_json)
    sid = meta['sample_id']
    limit = args.limit
    fail_closed = str(args.fail_closed).lower() in ('true', '1', 'yes')
    non_evaluable_fail_closed = str(args.non_evaluable_fail_closed).lower() in ('true', '1', 'yes')
    run_mode = str(args.run_mode or 'production').strip().lower()
    if run_mode == 'audit_only':
        run_mode = 'dev'
    audit_mode = run_mode in ('dev', 'audit_only')

    resources = {
        'verifybamid2_svd_prefix': resolve_svd_prefix(refs),
    }
    resources['verifybamid2_ud_path'] = f"{resources['verifybamid2_svd_prefix']}.UD" if resources['verifybamid2_svd_prefix'] else None
    resources['verifybamid2_bed'] = resolve_bed_path(refs, resources['verifybamid2_svd_prefix'])
    resources['reference_genome'] = resolve_reference_fasta(refs)
    resources['verifybamid2_binary'] = resolve_verifybamid2_binary()

    required = ['verifybamid2_binary', 'reference_genome', 'verifybamid2_svd_prefix', 'verifybamid2_ud_path', 'verifybamid2_bed']
    missing = []
    for key in required:
        path_text = resources.get(key)
        if key == 'verifybamid2_svd_prefix':
            if not is_svd_prefix(path_text):
                missing.append(f"{key}={path_text}")
            continue
        if not path_text or not Path(path_text).exists():
            missing.append(f"{key}={path_text}")

    sample_type = str(meta.get('sample_type') or 'germline').lower()
    freemix = None
    failure = None
    status = 'PASS'
    skip_reason = None
    non_evaluable = False
    method = 'VerifyBamID2'
    output_prefix = f"{sid}.verifybamid2"
    result_path = Path(f"{output_prefix}.selfSM")
    version_text = None

    if missing:
        failure = 'missing VerifyBamID2 reference assets: ' + ', '.join(missing)
    else:
        version_text = probe_verifybamid2_version(resources['verifybamid2_binary'])
        cmd = [
            resources['verifybamid2_binary'],
            '--NumThread', '2',
            '--BamFile', args.bam,
            '--Reference', resources['reference_genome'],
            '--SVDPrefix', str(resources['verifybamid2_svd_prefix']),
            '--UDPath', str(resources['verifybamid2_ud_path']),
            '--BedPath', str(resources['verifybamid2_bed']),
            '--Output', output_prefix,
        ]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        insufficient_markers = 'Insufficient Available markers' in (proc.stderr or '')
        if proc.returncode != 0:
            if insufficient_markers:
                status = 'SKIP'
                non_evaluable = True
                skip_reason = 'VerifyBamID2: insufficient marker overlap for robust contamination estimate'
            else:
                failure = f"VerifyBamID2 execution failed (exit={proc.returncode}): {proc.stderr.strip()}"
        elif not result_path.exists():
            if insufficient_markers:
                status = 'SKIP'
                non_evaluable = True
                skip_reason = 'VerifyBamID2: insufficient marker overlap for robust contamination estimate'
            else:
                failure = f"VerifyBamID2 completed but output missing: {result_path}"
        else:
            header = None
            values = None
            for line in result_path.read_text(encoding='utf-8', errors='replace').splitlines():
                striped = line.strip()
                if not striped:
                    continue
                if striped.startswith('#SEQ_ID'):
                    header = re.split(r'\s+', striped.lstrip('#'))
                    continue
                if striped.startswith('#'):
                    continue
                values = re.split(r'\s+', striped)
                break
            if not header or not values:
                failure = f"unable to parse VerifyBamID2 output: {result_path}"
            else:
                row = dict(zip(header, values))
                try:
                    freemix = float(row.get('FREEMIX', 'nan'))
                except ValueError:
                    freemix = None
                    failure = f"invalid FREEMIX in VerifyBamID2 output: {row.get('FREEMIX')}"

    if freemix is not None and freemix > limit:
        failure = f"contamination_rate {freemix:.6f} exceeds contamination limit {limit:.6f}"

    if non_evaluable and non_evaluable_fail_closed:
        failure = skip_reason or 'VerifyBamID2 contamination estimate not evaluable'

    if failure and fail_closed:
        status = 'FAIL'

    payload = {
        'node': 'VERIFYBAMID2',
        'sample_id': sid,
        'timestamp_utc': datetime.now(timezone.utc).isoformat(),
        'run_mode': run_mode,
        'status': status,
        'method': method,
        'sample_type': sample_type,
        'verifybamid2_binary': resources['verifybamid2_binary'],
        'verifybamid2_version': version_text,
        'contamination_rate': freemix,
        'contamination_evaluable': not non_evaluable,
        'contamination_limit': limit,
        'fail_closed_enabled': fail_closed,
        'contamination_non_evaluable_fail_closed': non_evaluable_fail_closed,
        'fail_closed_rule': f'STAGE2_CONTAMINATION_FAILURE when contamination_rate > {limit:.6f}',
        'governance_mode': 'DEV' if audit_mode else 'PRODUCTION',
        'verifybamid2_references': resources,
        'precondition_audit': args.precondition_audit,
    }

    if failure and status == 'FAIL':
        payload['failure_code'] = 'STAGE2_CONTAMINATION_NOT_EVALUABLE' if non_evaluable else 'STAGE2_CONTAMINATION_FAILURE'
        payload['failure_detail'] = failure
    elif failure:
        payload['warning_detail'] = failure

    if skip_reason:
        payload['skip_reason'] = skip_reason

    if failure and audit_mode:
        payload['policy_action'] = 'CONTINUE_FOR_AUDIT'
        payload['status'] = 'FAIL'

    Path(f"{sid}.contamination_audit.json").write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')

    if payload['status'] == 'FAIL' and not audit_mode:
        print('STAGE2_CONTAMINATION_FAILURE: ' + failure, file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
