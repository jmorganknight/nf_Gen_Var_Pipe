#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import List

ROOT = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_5_Clinical_Annotation_PGx_Triage')
BASE_INPUT = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_4_Ancestry_Phasing_Highway/tests/fixtures/banked_stage4/samples_hg002_banked_stage4.yaml')
REFS = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/conf/references.yaml')
THRESHOLDS = Path('/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/conf/thresholds.yaml')
SUMMARY = ROOT / 'tests/fmea/stage5_fmea_summary.tsv'


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


def make_container_visible_tiny_bed(name: str) -> Path:
    host_dir = Path('/scratch/tmp/stage5_fmea_beds')
    host_dir.mkdir(parents=True, exist_ok=True)
    host_path = host_dir / f'{name}.bed'
    write_text(host_path, 'chr1\t100\t120\n')
    return Path('/tmp/stage5_fmea_beds') / f'{name}.bed'


def stage5_cmd(input_path: Path, outdir: Path) -> List[str]:
    return [
        'nextflow', 'run', str(ROOT / 'main.nf'),
        '-profile', 'docker',
        '--input', str(input_path),
        '--references', str(REFS),
        '--thresholds', str(THRESHOLDS),
        '--outdir', str(outdir),
        '-ansi-log', 'false',
    ]


def run_case(name: str, input_path: Path, expect_ok: bool) -> ScenarioResult:
    run_dir = ROOT / 'tests/fmea/runs' / name
    outdir = run_dir / 'out'
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    proc = subprocess.run(
        stage5_cmd(input_path, outdir),
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
    return base_text.replace('VALID_PASS|VARIANTS_HARMONIZED', 'INVALID_STAGE4_TOKEN', 1)


def mutate_unconsented(base_text: str) -> str:
    text = base_text
    text = text.replace('secondary_findings: "CONSENTED|SF_ENABLED"', 'secondary_findings: "WITHHELD|SF_DISABLED"')
    text = text.replace('prs_reporting: "CONSENTED|PRS_ENABLED"', 'prs_reporting: "WITHHELD|PRS_DISABLED"')
    return text


def mutate_sf_unconsented(base_text: str) -> str:
    return base_text.replace('secondary_findings: "CONSENTED|SF_ENABLED"', 'secondary_findings: "WITHHELD|SF_DISABLED"')


def mutate_prs_unconsented(base_text: str) -> str:
    return base_text.replace('prs_reporting: "CONSENTED|PRS_ENABLED"', 'prs_reporting: "WITHHELD|PRS_DISABLED"')


def mutate_mask_conflict(base_text: str, tiny_bed: Path) -> str:
    text = mutate_unconsented(base_text)
    text = text.replace('secondary_findings: "WITHHELD|SF_DISABLED"', 'secondary_findings: "CONSENTED|SF_ENABLED"', 1)
    text = text.replace('prs_reporting: "WITHHELD|PRS_DISABLED"', 'prs_reporting: "CONSENTED|PRS_ENABLED"', 1)

    if 'snv_mask_bed:' in text:
        text = re.sub(r'^\s*snv_mask_bed:.*$', f'    snv_mask_bed: "{tiny_bed}"', text, flags=re.MULTILINE)
        return text

    marker = '    subpopulation:'
    idx = text.find(marker)
    if idx == -1:
        return text + f'\n    snv_mask_bed: "{tiny_bed}"\n'

    line_end = text.find('\n', idx)
    insert_at = len(text) if line_end == -1 else line_end + 1
    insertion = f'    sequencing_type: "WES"\n    snv_mask_bed: "{tiny_bed}"\n'
    return text[:insert_at] + insertion + text[insert_at:]


def mutate_insufficient_prs_coverage(base_text: str, tiny_bed: Path) -> str:
    text = base_text
    if 'snv_mask_bed:' in text:
        return re.sub(r'^\s*snv_mask_bed:.*$', f'    snv_mask_bed: "{tiny_bed}"', text, flags=re.MULTILINE)
    marker = '    subpopulation:'
    idx = text.find(marker)
    if idx == -1:
        return text + f'\n    snv_mask_bed: "{tiny_bed}"\n'
    line_end = text.find('\n', idx)
    insert_at = len(text) if line_end == -1 else line_end + 1
    insertion = f'    sequencing_type: "WES"\n    snv_mask_bed: "{tiny_bed}"\n'
    return text[:insert_at] + insertion + text[insert_at:]


def write_input(text: str, name: str) -> Path:
    stage4_dir = BASE_INPUT.parent
    phased_vcf_abs = stage4_dir / 'phased' / 'HG002_FULL_CONTROL_WES.phased.vcf.gz'
    phased_tbi_abs = stage4_dir / 'phased' / 'HG002_FULL_CONTROL_WES.phased.vcf.gz.tbi'
    text = re.sub(r'^\s*phased_vcf:\s*".*"\s*$', f'    phased_vcf: "{phased_vcf_abs}"', text, flags=re.MULTILINE)
    text = re.sub(r'^\s*phased_vcf_tbi:\s*".*"\s*$', f'    phased_vcf_tbi: "{phased_tbi_abs}"', text, flags=re.MULTILINE)

    tmp_dir = Path(tempfile.mkdtemp(prefix=f'stage5_fmea_{name}_'))
    path = tmp_dir / 'samples_hg002_banked_stage4.yaml'
    write_text(path, text)
    return path


def require_contains(path: Path, needle: str) -> None:
    raw = path.read_text(encoding='utf-8')
    if needle not in raw:
        raise AssertionError(f'Expected "{needle}" in {path}')


def tsv_row(name: str, result: ScenarioResult) -> str:
    details = result.details.replace('\n', '\\n')[:420]
    return '\t'.join([
        name,
        'PASS' if result.passed else 'FAIL',
        str(result.exit_code),
        f'observed_ok={result.observed_ok}; expected_ok={result.expected_ok}; {details}',
    ])


def main() -> None:
    base_text = read_text(BASE_INPUT)
    SUMMARY.parent.mkdir(parents=True, exist_ok=True)

    results: List[ScenarioResult] = []

    invalid_token_input = write_input(mutate_invalid_token(base_text), 'invalid_token')
    results.append(run_case('invalid_stage4_token', invalid_token_input, expect_ok=False))

    sf_unconsented_input = write_input(mutate_sf_unconsented(base_text), 'sf_unconsented')
    sf_unconsented_result = run_case('unconsented_sf_access_attempt', sf_unconsented_input, expect_ok=True)
    results.append(sf_unconsented_result)

    sf_unconsented_out = ROOT / 'tests/fmea/runs/unconsented_sf_access_attempt/out'
    require_contains(sf_unconsented_out / 'secondary_findings/HG002_FULL_CONTROL_WES.acmg_sf_bypassed_audit.json', '"consent_state": "BYPASS"')

    prs_unconsented_input = write_input(mutate_prs_unconsented(base_text), 'prs_unconsented')
    prs_unconsented_result = run_case('unconsented_prs_access_attempt', prs_unconsented_input, expect_ok=True)
    results.append(prs_unconsented_result)

    prs_unconsented_out = ROOT / 'tests/fmea/runs/unconsented_prs_access_attempt/out'
    require_contains(prs_unconsented_out / 'prs/HG002_FULL_CONTROL_WES.prs_bypassed_audit.json', '"consent_state": "BYPASS"')

    tiny_bed = make_container_visible_tiny_bed('tiny_mask')
    mask_conflict_input = write_input(mutate_mask_conflict(base_text, tiny_bed), 'mask_conflict')
    mask_result = run_case('target_bed_sf_mask_conflict_warning', mask_conflict_input, expect_ok=True)
    results.append(mask_result)

    mask_out = ROOT / 'tests/fmea/runs/target_bed_sf_mask_conflict_warning/out'
    require_contains(mask_out / 'audit_and_qc/stage5/HG002_FULL_CONTROL_WES.stage5_router.json', 'ACMG_SF_TARGET_MASK_WARNING')

    prs_coverage_input = write_input(mutate_insufficient_prs_coverage(base_text, tiny_bed), 'prs_coverage')
    prs_coverage_result = run_case('insufficient_prs_backbone_coverage', prs_coverage_input, expect_ok=True)
    results.append(prs_coverage_result)

    prs_coverage_out = ROOT / 'tests/fmea/runs/insufficient_prs_backbone_coverage/out'
    require_contains(prs_coverage_out / 'prs/HG002_FULL_CONTROL_WES.prs_insufficient_coverage_audit.json', 'INSUFFICIENT_BACKBONE_COVERAGE')

    lines = ['scenario\tstatus\texit_code\tdetails']
    for result in results:
        lines.append(tsv_row(result.name, result))
    write_text(SUMMARY, '\n'.join(lines) + '\n')
    print(SUMMARY.read_text(encoding='utf-8'))


if __name__ == '__main__':
    main()
