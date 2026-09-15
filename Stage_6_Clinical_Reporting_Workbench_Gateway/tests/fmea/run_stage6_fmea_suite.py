#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import List

ROOT = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_6_Clinical_Reporting_Workbench_Gateway')
BASE_INPUT_CANDIDATES = [
    Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_5_Clinical_Annotation_PGx_Triage/tests/mini_control/samples_hg002_banked_stage5.yaml'),
    Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_5_Clinical_Annotation_PGx_Triage/tests/fixtures/banked_stage5/samples_hg002_banked_stage5.yaml'),
    Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/results/master_orchestrator/samples_hg002_banked_stage5.yaml'),
]
REFS = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/conf/references.yaml')
THRESHOLDS = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/conf/thresholds.yaml')
SUMMARY = ROOT / 'tests/fmea/stage6_fmea_summary.tsv'


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
    for candidate in BASE_INPUT_CANDIDATES:
        if candidate.exists():
            return candidate
    raise FileNotFoundError('No Stage 5 banked manifest found for Stage 6 FMEA')


def stage6_cmd(input_path: Path, outdir: Path, ref_dir: str | None = None) -> List[str]:
    cmd = [
        'nextflow', 'run', str(ROOT / 'main.nf'),
        '-profile', 'docker',
        '--input', str(input_path),
        '--references', str(REFS),
        '--thresholds', str(THRESHOLDS),
        '--outdir', str(outdir),
        '-ansi-log', 'false',
    ]
    if ref_dir is not None:
        cmd.extend(['--ref_dir', ref_dir])
    return cmd


def run_case(name: str, input_path: Path, expect_ok: bool, ref_dir: str | None = None) -> ScenarioResult:
    run_dir = ROOT / 'tests/fmea/runs' / name
    outdir = run_dir / 'out'
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    proc = subprocess.run(
        stage6_cmd(input_path, outdir, ref_dir=ref_dir),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

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


def mutate_invalid_token(base_text: str) -> str:
    return base_text.replace('VALID_PASS|VARIANTS_HARMONIZED|STAGE5_COMPLETE', 'INVALID_STAGE5_TOKEN', 1)


def copy_stage5_fixture(name: str) -> Path:
    tmp_dir = Path(tempfile.mkdtemp(prefix=f'stage6_fmea_{name}_'))
    stage5_copy = tmp_dir / 'banked_stage5'
    shutil.copytree(pick_base_input().parent, stage5_copy)
    return stage5_copy


def mutate_candidate_vus_disparity(stage5_copy: Path) -> None:
    candidate_file = stage5_copy / 'annotation' / 'HG002_FULL_CONTROL_WES.stage5_candidate_vus.json'
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


def write_input(text: str, name: str, stage5_copy: Path | None = None) -> Path:
    if stage5_copy is None:
        stage5_copy = copy_stage5_fixture(name)
    path = stage5_copy / 'samples_hg002_banked_stage5.yaml'
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
    base_text = read_text(pick_base_input())
    SUMMARY.parent.mkdir(parents=True, exist_ok=True)

    results: List[ScenarioResult] = []

    baseline_copy = copy_stage5_fixture('baseline')
    baseline_input = write_input(base_text, 'baseline', baseline_copy)
    results.append(run_case('baseline_success', baseline_input, expect_ok=True))

    invalid_copy = copy_stage5_fixture('invalid_token')
    invalid_token_input = write_input(mutate_invalid_token(base_text), 'invalid_token', invalid_copy)
    results.append(run_case('corrupted_stage5_token', invalid_token_input, expect_ok=False))

    disparity_copy = copy_stage5_fixture('candidate_disparity')
    mutate_candidate_vus_disparity(disparity_copy)
    disparity_input = write_input(base_text, 'candidate_disparity', disparity_copy)
    results.append(run_case('variant_count_disparity', disparity_input, expect_ok=False))

    missing_copy = copy_stage5_fixture('missing_refs')
    missing_ref_input = write_input(base_text, 'missing_refs', missing_copy)
    results.append(run_case('missing_reference_mount', missing_ref_input, expect_ok=True, ref_dir='/nonexistent/stage6_refs'))

    lines = ['scenario\tstatus\texit_code\tdetails']
    for result in results:
        lines.append(tsv_row(result.name, result))
    write_text(SUMMARY, '\n'.join(lines) + '\n')
    print(SUMMARY.read_text(encoding='utf-8'))


if __name__ == '__main__':
    main()
