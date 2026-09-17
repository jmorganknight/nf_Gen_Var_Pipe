#!/usr/bin/env python3
from __future__ import annotations

import json
import hashlib
import re
import shutil
import subprocess
import tempfile
import tarfile
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import List

SCRIPT_PATH = Path(__file__).resolve()
STAGE6_ROOT = SCRIPT_PATH.parents[2]
REPO_ROOT = SCRIPT_PATH.parents[3]
REFS = REPO_ROOT / 'conf' / 'references.yaml'
THRESHOLDS = REPO_ROOT / 'conf' / 'thresholds.yaml'
SUMMARY = STAGE6_ROOT / 'tests' / 'fmea' / 'stage6_fmea_summary.tsv'


@dataclass
class ScenarioResult:
    name: str
    passed: bool
    observed_ok: bool
    expected_ok: bool
    exit_code: int
    details: str


def read_text(path: Path) -> str:
    return path.read_text(encoding='utf-8')


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def pick_base_input() -> Path:
    candidates = [
        REPO_ROOT / 'Stage_5_Clinical_Annotation_PGx_Triage' / 'tests' / 'mini_control' / 'samples_mini_control_banked_stage5.yaml',
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate

    search_roots = [
        REPO_ROOT / 'Stage_5_Clinical_Annotation_PGx_Triage' / 'tests' / 'mini_control',
        REPO_ROOT / 'Stage_5_Clinical_Annotation_PGx_Triage' / 'tests' / 'fixtures' / 'banked_stage5',
        REPO_ROOT / 'Stage_5_Clinical_Annotation_PGx_Triage' / 'tests' / 'fmea' / 'runs',
        REPO_ROOT / 'results' / 'master_orchestrator',
    ]
    for root in search_roots:
        matches = sorted(root.rglob('samples_*_banked_stage5.yaml'))
        if matches:
            return matches[0]

    return ensure_stage5_seed_fixture()


def ensure_stage5_seed_fixture() -> Path:
    sid = 'HG002_STUB'
    seed_root = STAGE6_ROOT / 'tests' / 'fmea' / 'seed_stage5'
    if seed_root.exists():
        shutil.rmtree(seed_root)

    annotation_dir = seed_root / 'annotation'
    sf_dir = seed_root / 'secondary_findings'
    prs_dir = seed_root / 'prs'
    pgx_dir = seed_root / 'pgx'
    release_dir = seed_root / 'clinical_release'
    for directory in [annotation_dir, sf_dir, prs_dir, pgx_dir, release_dir]:
        directory.mkdir(parents=True, exist_ok=True)

    acmg_payload = {
        'sample_id': sid,
        'tiers': {
            'Tier I': [],
            'Tier II': [],
            'Tier III': [],
        },
    }
    candidate_payload = {
        'sample_id': sid,
        'candidate_vus': [],
    }
    queue_payload = {
        'sample_id': sid,
        'upgraded_variants': [],
        'remaining_vus': [],
    }
    sf_payload = {
        'sample_id': sid,
        'consent_state': 'BYPASSED_NO_CONSENT',
        'findings': [],
    }
    prs_payload = {
        'sample_id': sid,
        'consent_state': 'BYPASSED_NO_CONSENT',
        'score_percentile': None,
    }
    pgx_payload = {
        'sample_id': sid,
        'star_alleles': {},
    }
    stage5_provenance_payload = {
        'sample_id': sid,
        'digital_signature': {
            'signature_algorithm': 'RS256',
            'signature_value': 'STUB',
            'signer_id': 'clinical_signer',
            'public_key_fingerprint': 'STUB',
            'signed_digest_sha256': '0' * 64,
        },
        'status': 'PASS',
    }
    clinical_payload = {
        'metadata': {
            'sample_id': sid,
            'patient_id': sid,
            'case_id': sid,
            'timestamp_utc': '2026-09-16T00:00:00Z',
        },
        'branches': {
            'germline': {'reported_variants': [], 'summary': {'status': 'COMPLETED', 'reported_variant_count': 0}},
            'somatic': {'reported_variants': [], 'summary': {'status': 'COMPLETED', 'reported_variant_count': 0}},
            'sf': {'reported_variants': [], 'summary': {'status': 'COMPLETED', 'reported_variant_count': 0}},
            'pgx': {'reported_calls': [], 'summary': {'status': 'COMPLETED', 'reported_variant_count': 0}},
            'prs': {'score_payload': {}, 'summary': {'status': 'COMPLETED', 'reported_variant_count': 0}},
        },
    }
    canonical_payload = json.dumps(clinical_payload, sort_keys=True, separators=(',', ':')).encode('utf-8')
    bundle_sha256 = hashlib.sha256(canonical_payload).hexdigest()
    release_payload = {
        'sample_id': sid,
        'audit_trail': {
            'bundle_sha256': bundle_sha256,
            'container_digest': 'sha256:1234abcd',
            'git_commit_sha': 'stage6_fmea_seed',
            'timestamp_utc': '2026-09-16T00:00:00Z',
        },
        'clinical_payload': clinical_payload,
    }

    write_text(annotation_dir / f'{sid}.stage5_acmg_tiered_variants.json', json.dumps(acmg_payload, indent=2) + '\n')
    write_text(annotation_dir / f'{sid}.stage5_candidate_vus.json', json.dumps(candidate_payload, indent=2) + '\n')
    write_text(annotation_dir / f'{sid}.stage5_vus_triage_queue.json', json.dumps(queue_payload, indent=2) + '\n')
    write_text(sf_dir / f'{sid}.acmg_sf_bypassed_audit.json', json.dumps(sf_payload, indent=2) + '\n')
    write_text(prs_dir / f'{sid}.prs_bypassed_audit.json', json.dumps(prs_payload, indent=2) + '\n')
    write_text(pgx_dir / f'{sid}.pgx_report.json', json.dumps(pgx_payload, indent=2) + '\n')
    write_text(pgx_dir / f'{sid}.provenance.json', json.dumps(stage5_provenance_payload, indent=2) + '\n')
    write_text(release_dir / f'{sid}_production_release.json', json.dumps(release_payload, indent=2) + '\n')

    bundle_path = pgx_dir / f'{sid}.clinical_bundle.tar.gz'
    with tarfile.open(bundle_path, mode='w:gz') as tar:
        payload_bytes = json.dumps({'sample_id': sid, 'status': 'STUB'}, indent=2).encode('utf-8')
        info = tarfile.TarInfo(name=f'{sid}.clinical_payload.json')
        info.size = len(payload_bytes)
        tar.addfile(info, BytesIO(payload_bytes))

    manifest = seed_root / 'samples_seed_banked_stage5.yaml'
    manifest_text = f"""samples:
  - sample_id: \"{sid}\"
    validation_token: \"VALID_PASS|VARIANTS_HARMONIZED|STAGE5_COMPLETE\"
    run_mode: \"production\"
    stage2_contamination_status: \"CLEAR\"
    stage2_contamination_policy_action: \"PROCEED\"
    stage5_outputs:
      acmg_tiered_variants_json: \"annotation/{sid}.stage5_acmg_tiered_variants.json\"
      vus_triage_queue_json: \"annotation/{sid}.stage5_vus_triage_queue.json\"
      sf_report_json: \"secondary_findings/{sid}.acmg_sf_bypassed_audit.json\"
      prs_calibrated_report_json: \"prs/{sid}.prs_bypassed_audit.json\"
      pgx_report_json: \"pgx/{sid}.pgx_report.json\"
      clinical_bundle_tar_gz: \"pgx/{sid}.clinical_bundle.tar.gz\"
      provenance_json: \"pgx/{sid}.provenance.json\"
      production_release_json: \"clinical_release/{sid}_production_release.json\"
"""
    write_text(manifest, manifest_text)
    return manifest


def stage6_cmd(
    input_path: Path,
    outdir: Path,
    references_path: Path,
    thresholds_path: Path,
    ref_dir: str | None = None,
) -> List[str]:
    cmd = [
        'nextflow', 'run', str(STAGE6_ROOT / 'main.nf'),
        '-profile', 'docker',
        '--input', str(input_path),
        '--references', str(references_path),
        '--thresholds', str(thresholds_path),
        '--outdir', str(outdir),
        '-ansi-log', 'false',
    ]
    if ref_dir is not None:
        cmd.extend(['--ref_dir', ref_dir])
    return cmd


def run_case(
    name: str,
    input_path: Path,
    expect_ok: bool,
    references_path: Path,
    thresholds_path: Path,
    ref_dir: str | None = None,
) -> ScenarioResult:
    run_dir = STAGE6_ROOT / 'tests' / 'fmea' / 'runs' / name
    outdir = run_dir / 'out'
    run_dir.mkdir(parents=True, exist_ok=True)
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    proc = subprocess.run(
        stage6_cmd(
            input_path,
            outdir,
            references_path=references_path,
            thresholds_path=thresholds_path,
            ref_dir=ref_dir,
        ),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    write_text(run_dir / 'stdout.log', proc.stdout)

    observed_ok = proc.returncode == 0
    passed = observed_ok == expect_ok
    if not passed:
        raise AssertionError(
            f'{name}: expected ok={expect_ok} but got exit={proc.returncode}\n{proc.stdout}'
        )

    return ScenarioResult(
        name=name,
        passed=passed,
        observed_ok=observed_ok,
        expected_ok=expect_ok,
        exit_code=proc.returncode,
        details=proc.stdout[-4000:],
    )


def run_case_with_expected_fatal(
    name: str,
    input_path: Path,
    expected_fatal: str,
    references_path: Path,
    thresholds_path: Path,
    ref_dir: str | None = None,
) -> ScenarioResult:
    result = run_case(
        name,
        input_path,
        expect_ok=False,
        references_path=references_path,
        thresholds_path=thresholds_path,
        ref_dir=ref_dir,
    )
    if expected_fatal not in result.details:
        full_log = read_text(STAGE6_ROOT / 'tests' / 'fmea' / 'runs' / name / 'stdout.log')
        if expected_fatal not in full_log:
            raise AssertionError(
                f"{name}: expected fatal code {expected_fatal!r} not found in execution logs\n{full_log[-6000:]}"
            )
    return result


def mutate_invalid_token(base_text: str) -> str:
    return base_text.replace('VALID_PASS|VARIANTS_HARMONIZED|STAGE5_COMPLETE', 'INVALID_STAGE5_TOKEN', 1)


def copy_stage5_fixture(name: str) -> Path:
    tmp_dir = Path(tempfile.mkdtemp(prefix=f'stage6_fmea_{name}_'))
    stage5_copy = tmp_dir / 'banked_stage5'
    shutil.copytree(pick_base_input().parent, stage5_copy)
    return stage5_copy


def mutate_candidate_vus_disparity(stage5_copy: Path) -> None:
    candidate_files = sorted(stage5_copy.glob('annotation/*.stage5_candidate_vus.json'))
    if not candidate_files:
        raise FileNotFoundError(f'No Stage 5 candidate VUS JSON files found under {stage5_copy / "annotation"}')
    candidate_file = candidate_files[0]
    payload = json.loads(candidate_file.read_text(encoding='utf-8'))
    payload['candidate_vus'] = [
        {
            'variant': 'chr1:12345:A:T',
            'gene': 'TP53',
            'chrom': 'chr1',
            'pos': 12345,
            'ref': 'A',
            'alt': 'T',
            'maf': 0.02,
            'status': 'CANDIDATE',
        }
    ]
    candidate_file.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


def mutate_signature_mismatch(stage5_copy: Path) -> None:
    release_dir = stage5_copy / 'clinical_release'
    release_files = sorted(release_dir.glob('*_production_release.json'))
    if not release_files:
        raise FileNotFoundError(f'No Stage 5 production release payload found in {release_dir}')
    release_path = release_files[0]
    envelope = json.loads(release_path.read_text(encoding='utf-8'))
    payload = envelope.get('clinical_payload')
    if not isinstance(payload, dict):
        raise ValueError(f'clinical_payload missing or malformed in {release_path}')

    metadata = payload.setdefault('metadata', {})
    if not isinstance(metadata, dict):
        raise ValueError(f'clinical_payload.metadata malformed in {release_path}')

    prior = str(metadata.get('timestamp_utc', ''))
    metadata['timestamp_utc'] = f'{prior}__OQ_SIGNATURE_TAMPERED'
    release_path.write_text(json.dumps(envelope, indent=2) + '\n', encoding='utf-8')


def run_manifest_assembly_case(
    name: str,
    fragments_glob: str,
    provenance_glob: str,
    metrics_glob: str,
    expect_ok: bool,
    expected_fatal: str | None = None,
) -> ScenarioResult:
    run_dir = STAGE6_ROOT / 'tests' / 'fmea' / 'runs' / name
    outdir = run_dir / 'out'
    if outdir.exists():
        shutil.rmtree(outdir)
    run_dir.mkdir(parents=True, exist_ok=True)
    outdir.mkdir(parents=True, exist_ok=True)

    harness = run_dir / 'assemble_harness.nf'
    module_path = (STAGE6_ROOT / 'modules' / 'local' / 'assemble_stage6_banked_manifest.nf').resolve().as_posix()
    harness_template = """nextflow.enable.dsl = 2

include { ASSEMBLE_STAGE6_BANKED_MANIFEST } from '__MODULE_PATH__'

workflow {
    def fragments = Channel.fromPath(params.fragments_glob, checkIfExists: true)
    def provenance = Channel.fromPath(params.provenance_glob, checkIfExists: true)
    def metrics = Channel.fromPath(params.metrics_glob, checkIfExists: true)
    ASSEMBLE_STAGE6_BANKED_MANIFEST(fragments.collect(), provenance.collect(), metrics.collect())
}
"""
    harness.write_text(
        harness_template.replace('__MODULE_PATH__', module_path),
        encoding='utf-8',
    )

    cmd = [
        'nextflow',
        'run',
        str(harness),
        '--fragments_glob',
        fragments_glob,
        '--provenance_glob',
        provenance_glob,
        '--metrics_glob',
        metrics_glob,
        '--outdir',
        str(outdir),
        '-ansi-log',
        'false',
    ]
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=STAGE6_ROOT,
    )
    write_text(run_dir / 'stdout.log', proc.stdout)

    observed_ok = proc.returncode == 0
    passed = observed_ok == expect_ok
    if not passed:
        raise AssertionError(
            f'{name}: expected ok={expect_ok} but got exit={proc.returncode}\n{proc.stdout}'
        )
    if expected_fatal:
        if expected_fatal not in proc.stdout:
            raise AssertionError(
                f"{name}: expected fatal code {expected_fatal!r} not found\n{proc.stdout[-6000:]}"
            )

    return ScenarioResult(
        name=name,
        passed=passed,
        observed_ok=observed_ok,
        expected_ok=expect_ok,
        exit_code=proc.returncode,
        details=proc.stdout[-4000:],
    )


def build_missing_validation_token_fragments(source_outdir: Path, target_dir: Path) -> tuple[str, str, str]:
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)

    stage6_audit_dir = source_outdir / 'audit_and_qc' / 'stage6'
    reporting_dir = source_outdir / 'reporting'

    for src in sorted(stage6_audit_dir.glob('*.json')):
        shutil.copy2(src, target_dir / src.name)
    for src in sorted(reporting_dir.glob('*.json')):
        shutil.copy2(src, target_dir / src.name)

    precondition_candidates = sorted(target_dir.glob('*.stage6_precondition.fragment.json'))
    if not precondition_candidates:
        raise FileNotFoundError('No precondition fragment found for missing-validation-token test')

    fragment_path = precondition_candidates[0]
    fragment = json.loads(fragment_path.read_text(encoding='utf-8'))
    fragment.pop('validation_token', None)
    fragment_path.write_text(json.dumps(fragment, indent=2) + '\n', encoding='utf-8')

    fragments_glob = str(target_dir / '*.fragment.json')
    provenance_glob = str(target_dir / '*.provenance.json')
    metrics_glob = str(target_dir / '*.lab_metrics.json')
    return fragments_glob, provenance_glob, metrics_glob


def ensure_stage6_reference_fixture() -> tuple[Path, Path, Path]:
    ref_root = STAGE6_ROOT / 'tests' / 'fmea' / 'seed_references'
    if ref_root.exists():
        shutil.rmtree(ref_root)
    ref_root.mkdir(parents=True, exist_ok=True)

    assets = {
        'genome.fa': '>chr1\nACGT\n',
        'genome.fa.fai': 'chr1\t4\t6\t4\t5\n',
        'genome.dict': '@HD\tVN:1.6\n@SQ\tSN:chr1\tLN:4\n',
        'hotspots.bed': 'chr1\t1\t2\tHOTSPOT\n',
        'clinvar.vcf.gz': 'stub\n',
        'gnomad.vcf.gz': 'stub\n',
        'hgmd.tsv': 'gene\tvariant\n',
        'sf.bed': 'chr1\t1\t2\tGENE\n',
        'prs_weights.tsv': 'marker\tweight\n',
        'preflight.lock': 'STAGE0_PREFLIGHT_LOCK_PASS\n',
    }
    for name, content in assets.items():
        write_text(ref_root / name, content)

    references_payload = {
        'ref_data_root': str(ref_root),
        'references': {
            'reference_genome': 'genome.fa',
            'reference_fai': 'genome.fa.fai',
            'reference_dict': 'genome.dict',
            'hotspot_registry': 'hotspots.bed',
            'clinvar_db': 'clinvar.vcf.gz',
            'gnomad_db': 'gnomad.vcf.gz',
            'hgmd_db': 'hgmd.tsv',
            'sf_bed': 'sf.bed',
            'prs_weights': 'prs_weights.tsv',
            'preflight_lock': str(ref_root / 'preflight.lock'),
            'preflight_lock_status': 'STAGE0_PREFLIGHT_LOCK_PASS',
        },
    }
    references_file = ref_root / 'references.yaml'
    references_file.write_text(
        "\n".join([
            f"ref_data_root: \"{references_payload['ref_data_root']}\"",
            'references:',
            '  reference_genome: "genome.fa"',
            '  reference_fai: "genome.fa.fai"',
            '  reference_dict: "genome.dict"',
            '  hotspot_registry: "hotspots.bed"',
            '  clinvar_db: "clinvar.vcf.gz"',
            '  gnomad_db: "gnomad.vcf.gz"',
            '  hgmd_db: "hgmd.tsv"',
            '  sf_bed: "sf.bed"',
            '  prs_weights: "prs_weights.tsv"',
            f"  preflight_lock: \"{(ref_root / 'preflight.lock').as_posix()}\"",
            '  preflight_lock_status: "STAGE0_PREFLIGHT_LOCK_PASS"',
            '',
        ]),
        encoding='utf-8',
    )

    thresholds_file = THRESHOLDS if THRESHOLDS.exists() else (STAGE6_ROOT / 'tests' / 'fmea' / 'seed_thresholds.yaml')
    if not thresholds_file.exists():
        write_text(thresholds_file, 'clinical:\n  placeholder: true\n')
    return references_file, thresholds_file, ref_root


def write_input(text: str, name: str, stage5_copy: Path | None = None) -> Path:
    if stage5_copy is None:
        stage5_copy = copy_stage5_fixture(name)
    path = stage5_copy / 'samples_stage5_fmea_input_banked_stage5.yaml'
    write_text(path, text)
    return path


def tsv_row(name: str, result: ScenarioResult) -> str:
    details = result.details.replace('\n', '\\n')[:420]
    return '\t'.join([
        name,
        'PASS' if result.passed else 'FAIL',
        str(result.exit_code),
        f'observed_ok={result.observed_ok}; expected_ok={result.expected_ok}; {details}',
    ])


def main() -> None:
    references_file, thresholds_file, ref_dir = ensure_stage6_reference_fixture()
    base_text = read_text(pick_base_input())
    SUMMARY.parent.mkdir(parents=True, exist_ok=True)

    results: List[ScenarioResult] = []

    baseline_copy = copy_stage5_fixture('baseline')
    baseline_input = write_input(base_text, 'baseline', baseline_copy)
    results.append(
        run_case(
            'baseline_success',
            baseline_input,
            expect_ok=True,
            references_path=references_file,
            thresholds_path=thresholds_file,
            ref_dir=str(ref_dir),
        )
    )

    invalid_copy = copy_stage5_fixture('invalid_token')
    invalid_token_input = write_input(mutate_invalid_token(base_text), 'invalid_token', invalid_copy)
    results.append(
        run_case(
            'corrupted_stage5_token',
            invalid_token_input,
            expect_ok=False,
            references_path=references_file,
            thresholds_path=thresholds_file,
            ref_dir=str(ref_dir),
        )
    )

    signature_copy = copy_stage5_fixture('signature_mismatch')
    mutate_signature_mismatch(signature_copy)
    signature_input = write_input(base_text, 'signature_mismatch', signature_copy)
    results.append(
        run_case_with_expected_fatal(
            'signature_mismatch',
            signature_input,
            expected_fatal='STAGE6_SIGNATURE_VERIFICATION_FATAL',
            references_path=references_file,
            thresholds_path=thresholds_file,
            ref_dir=str(ref_dir),
        )
    )

    disparity_copy = copy_stage5_fixture('candidate_disparity')
    mutate_candidate_vus_disparity(disparity_copy)
    disparity_input = write_input(base_text, 'candidate_disparity', disparity_copy)
    results.append(
        run_case(
            'variant_count_disparity',
            disparity_input,
            expect_ok=False,
            references_path=references_file,
            thresholds_path=thresholds_file,
            ref_dir=str(ref_dir),
        )
    )

    missing_copy = copy_stage5_fixture('missing_refs')
    missing_ref_input = write_input(base_text, 'missing_refs', missing_copy)
    results.append(
        run_case(
            'missing_reference_mount',
            missing_ref_input,
            expect_ok=True,
            references_path=references_file,
            thresholds_path=thresholds_file,
            ref_dir='/nonexistent/stage6_refs',
        )
    )

    missing_validation_fixture = STAGE6_ROOT / 'tests' / 'fmea' / 'runs' / 'missing_regulated_metadata' / 'fixture'
    fragments_glob, provenance_glob, metrics_glob = build_missing_validation_token_fragments(
        source_outdir=STAGE6_ROOT / 'tests' / 'fmea' / 'runs' / 'baseline_success' / 'out',
        target_dir=missing_validation_fixture,
    )
    results.append(
        run_manifest_assembly_case(
            name='missing_regulated_metadata',
            fragments_glob=fragments_glob,
            provenance_glob=provenance_glob,
            metrics_glob=metrics_glob,
            expect_ok=False,
            expected_fatal='STAGE6_MANIFEST_ERROR',
        )
    )

    lines = ['scenario\tstatus\texit_code\tdetails']
    for result in results:
        lines.append(tsv_row(result.name, result))
    write_text(
        SUMMARY,
        '# FMEA Regulatory Audit Summary\n'
        '# stage: 6\n'
        f'# cases_exercised: {len(results)}\n'
        + '\n'.join(lines)
        + '\n',
    )
    print(SUMMARY.read_text(encoding='utf-8'))


if __name__ == '__main__':
    main()
