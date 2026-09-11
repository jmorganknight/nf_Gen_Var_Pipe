#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

ROOT = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_4_Ancestry_Phasing_Highway')
STAGE3_FIXTURE = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_3_Variant_Discovery_Engine/tests/fixtures/banked_stage3/samples_hg002_banked_stage3.yaml')
REFS = Path('/media/drive_c/nf_pipes/nf_WES_Onco_Risk/references.yaml')
THRESHOLDS = Path('/media/drive_c/nf_pipes/nf_WES_Onco_Risk/thresholds.yaml')
SUMMARY = ROOT / 'tests/fmea/stage4_fmea_summary.tsv'


@dataclass
class ScenarioResult:
    name: str
    passed: bool
    observed_ok: bool
    expected_ok: bool
    exit_code: int
    details: str


def load_manifest(path: Path) -> Dict:
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path: Path, data: Dict) -> None:
    path.write_text(json.dumps(data, indent=2), encoding='utf-8')


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding='utf-8')


def stage4_cmd(input_path: Path, refs_path: Path, outdir: Path) -> List[str]:
    return [
        'nextflow', 'run', str(ROOT / 'main.nf'),
        '-profile', 'docker',
        '--input', str(input_path),
        '--references', str(refs_path),
        '--thresholds', str(THRESHOLDS),
        '--outdir', str(outdir),
        '-ansi-log', 'false',
    ]


def run_case(name: str, input_path: Path, refs_path: Path, expect_ok: bool = False) -> ScenarioResult:
    run_dir = ROOT / 'tests/fmea/runs' / name
    run_dir.mkdir(parents=True, exist_ok=True)
    outdir = run_dir / 'out'
    if outdir.exists():
        shutil.rmtree(outdir)
    proc = subprocess.run(stage4_cmd(input_path, refs_path, outdir), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    observed_ok = proc.returncode == 0
    passed = observed_ok == expect_ok
    if not passed:
        raise AssertionError(f'{name}: expected ok={expect_ok} but got exit={proc.returncode}\n{proc.stdout}')
    return ScenarioResult(name=name, passed=passed, observed_ok=observed_ok, expected_ok=expect_ok, exit_code=proc.returncode, details=proc.stdout[-4000:])


def make_temp_manifest(base: Dict, tweaks: Dict) -> Path:
    data = json.loads(json.dumps(base))
    sample = data['samples'][0]
    for key, value in tweaks.items():
        if key.startswith('sample.'):
            sample[key.split('.', 1)[1]] = value
        else:
            data[key] = value
    temp_dir = Path(tempfile.mkdtemp(prefix='stage4_fmea_'))
    path = temp_dir / 'stage3_input.yaml'
    write_json(path, data)
    return path


def make_temp_refs(missing_models: bool = False) -> Path:
    raw = REFS.read_text(encoding='utf-8')
    if missing_models:
        raw = raw.replace('poppca_models: "/opt/reference/models/PopPCA_models"', 'poppca_models: "/tmp/missing_PopPCA_models"')
        raw = raw.replace('poppca_models: "/opt/reference/PopPCA_models"', 'poppca_models: "/tmp/missing_PopPCA_models"')
    temp_dir = Path(tempfile.mkdtemp(prefix='stage4_refs_'))
    path = temp_dir / 'references.yaml'
    write_text(path, raw)
    return path


def tsv_row(name: str, result: ScenarioResult) -> str:
    return '\t'.join([
        name,
        'PASS' if result.passed else 'FAIL',
        str(result.exit_code),
        f'observed_ok={result.observed_ok}; expected_ok={result.expected_ok}; {result.details.replace("\n", "\\n")[:420]}'
    ])


def main() -> None:
    base = load_manifest(STAGE3_FIXTURE)
    SUMMARY.parent.mkdir(parents=True, exist_ok=True)

    results: List[ScenarioResult] = []

    invalid_token = make_temp_manifest(base, {'sample.validation_token': 'INVALID_STAGE3_TOKEN'})
    results.append(run_case('invalid_stage3_token', invalid_token, REFS, expect_ok=False))

    missing_models_refs = make_temp_refs(missing_models=True)
    results.append(run_case('missing_poppca_models', STAGE3_FIXTURE, missing_models_refs, expect_ok=False))

    missing_tbi = make_temp_manifest(base, {'sample.normalized_vcf_tbi': '/tmp/missing_stage4_input.vcf.tbi'})
    results.append(run_case('unphased_vcf_fallback_fails_closed', missing_tbi, REFS, expect_ok=False))

    lines = ['scenario\tstatus\texit_code\tdetails']
    for result in results:
        lines.append(tsv_row(result.name, result))
    write_text(SUMMARY, '\n'.join(lines) + '\n')
    print(SUMMARY.read_text(encoding='utf-8'))


if __name__ == '__main__':
    main()
