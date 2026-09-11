#!/usr/bin/env python3
"""Run Stage 3 chaos/FMEA scenarios and emit STAGE3_FMEA_SUMMARY.tsv."""

from __future__ import annotations

import json
import shutil
import subprocess
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAIN_NF = ROOT / "main.nf"
BASE_STAGE2 = Path("/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_2_PostAlign_Sample_Validation_Gate/tests/fixtures/banked_stage2/samples_hg002_banked_stage2.yaml")


def run_nf(input_yaml: Path, outdir: Path, work_dir: Path) -> tuple[int, float, str]:
    cmd = [
        "nextflow",
        "run",
        str(MAIN_NF),
        "-profile",
        "docker",
        "--input",
        str(input_yaml),
        "--outdir",
        str(outdir),
        "-work-dir",
        str(work_dir),
        "-ansi-log",
        "false",
    ]
    t0 = time.time()
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    elapsed = time.time() - t0
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    return proc.returncode, elapsed, output


def write_text(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")


def stage2_manifest_mutation(base_text: str, *, validation_token: str, bam: Path, bai: Path, branch_block: str, faults_block: str = "") -> str:
    del base_text
    variant_branches = {
        'snv_indel': False,
        'structural_variants': False,
        'copy_number_cnv': False,
        'str_expansions': False,
        'trisomy_aneuploidy': False,
        'homologous_pseudogenes': False,
    }
    if 'snv_indel: true' in branch_block:
        variant_branches['snv_indel'] = True
    if 'structural_variants: true' in branch_block:
        variant_branches['structural_variants'] = True
    if 'copy_number_cnv: true' in branch_block:
        variant_branches['copy_number_cnv'] = True
    if 'str_expansions: true' in branch_block:
        variant_branches['str_expansions'] = True
    if 'trisomy_aneuploidy: true' in branch_block:
        variant_branches['trisomy_aneuploidy'] = True
    if 'homologous_pseudogenes: true' in branch_block:
        variant_branches['homologous_pseudogenes'] = True

    sample = {
        'sample_id': 'HG002_FULL_CONTROL_WES',
        'validation_token': validation_token,
        'sorted_bam': str(bam),
        'sorted_bai': str(bai),
        'stage2_router_token': 'WES|TARGET_VALIDATED',
        'variant_branches': variant_branches,
        'reference_build': {
            'reference_genome': '/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa',
            'reference_dict': '/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.dict',
            'reference_fai': '/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa.fai',
            'capture_wes_bed': '/opt/reference/beds/OncoPanel_v4.2_Master_hs38DH.bed',
            'onco_target_bed': '/opt/reference/beds/OncoPanel_v4.2_Master_hs38DH.bed',
            'sf_bed': '/opt/reference/beds/ACMG_SF_v3.2_hs38DH.bed',
            'clinvar_db': '/opt/reference/clinvar/clinvar_20260601.vcf.gz',
        },
        'save_dir': '/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_3_Variant_Discovery_Engine/tests/fmea/stage3_fmea_out',
    }
    if 'corrupt_vcf_header: true' in faults_block:
        sample['stage3_faults'] = {'corrupt_vcf_header': True}
    return json.dumps({'samples': [sample]}, indent=2) + '\n'


def scenario_manifest(base_text: str, scenario_dir: Path, *, validation_token: str, bam_exists: bool, branch_block: str, faults_block: str = "") -> Path:
    input_dir = scenario_dir / "input"
    input_dir.mkdir(parents=True, exist_ok=True)
    bam = input_dir / "sorted.bam"
    bai = input_dir / "sorted.bam.bai"
    if bam_exists:
        bam.write_text("BAM_PLACEHOLDER\n", encoding="utf-8")
        bai.write_text("BAI_PLACEHOLDER\n", encoding="utf-8")
    input_yaml = scenario_dir / "input.yaml"
    write_text(
        input_yaml,
        stage2_manifest_mutation(
            base_text,
            validation_token=validation_token,
            bam=bam,
            bai=bai,
            branch_block=branch_block,
            faults_block=faults_block,
        ),
    )
    return input_yaml


def main() -> int:
    if not BASE_STAGE2.exists():
        raise FileNotFoundError(f"missing Stage 2 fixture: {BASE_STAGE2}")

    base_text = BASE_STAGE2.read_text(encoding="utf-8")
    fmea_root = Path(__file__).resolve().parent
    runs = fmea_root / "runs"
    runs.mkdir(parents=True, exist_ok=True)

    scenarios = [
        {
            "name": "unvalidated_stage2_manifest",
            "manifest": lambda d: scenario_manifest(
                base_text,
                d,
                validation_token="BADTOKEN",
                bam_exists=True,
                branch_block='    variant_branches:\n      snv_indel: true\n      structural_variants: true\n      copy_number_cnv: true\n      str_expansions: false\n      trisomy_aneuploidy: true\n      homologous_pseudogenes: false\n',
            ),
            "expect_code": "nonzero",
            "expect_token": "STAGE3_PRECONDITION_FAILURE",
        },
        {
            "name": "all_branches_disabled_graceful_skip",
            "manifest": lambda d: scenario_manifest(
                base_text,
                d,
                validation_token="VALID_PASS|SAMPLE_VALIDATED",
                bam_exists=True,
                branch_block='    variant_branches:\n      snv_indel: false\n      structural_variants: false\n      copy_number_cnv: false\n      str_expansions: false\n      trisomy_aneuploidy: false\n      homologous_pseudogenes: false\n',
            ),
            "expect_code": "zero",
            "expect_token": None,
        },
        {
            "name": "corrupt_vcf_header_fail_closed",
            "manifest": lambda d: scenario_manifest(
                base_text,
                d,
                validation_token="VALID_PASS|SAMPLE_VALIDATED",
                bam_exists=True,
                branch_block='    variant_branches:\n      snv_indel: true\n      structural_variants: false\n      copy_number_cnv: false\n      str_expansions: false\n      trisomy_aneuploidy: false\n      homologous_pseudogenes: false\n',
                faults_block='    stage3_faults:\n      corrupt_vcf_header: true\n',
            ),
            "expect_code": "nonzero",
            "expect_token": "STAGE3_HARMONIZATION_FAILURE",
        },
    ]

    lines = ["scenario\tstatus\telapsed_seconds\texit_code\tdetails\n"]
    failed = False

    for sc in scenarios:
        scenario_dir = runs / sc["name"]
        if scenario_dir.exists():
            shutil.rmtree(scenario_dir)
        scenario_dir.mkdir(parents=True, exist_ok=True)

        input_yaml = sc["manifest"](scenario_dir)
        outdir = scenario_dir / "out"
        work_dir = scenario_dir / "work"

        code, elapsed, output = run_nf(input_yaml, outdir, work_dir)
        banked = outdir / "samples_hg002_banked_stage3.yaml"

        checks: list[tuple[bool, str]] = []
        if sc["expect_code"] == "zero":
            checks.append((code == 0, f"expected exit_code=0 observed={code}"))
            checks.append((banked.exists(), f"missing banked manifest: {banked}"))
            if banked.exists():
                banked_text = banked.read_text(encoding="utf-8")
                checks.append(("\"active_branches\": []" in banked_text or "active_branches: []" in banked_text, "banked manifest did not record an empty branch set"))
        else:
            checks.append((code != 0, f"expected non-zero exit_code observed={code}"))
            if sc["expect_token"]:
                checks.append((sc["expect_token"] in output, f"missing {sc['expect_token']} signal in output"))

        errors = [msg for ok, msg in checks if not ok]
        ok = not errors
        if not ok:
            failed = True
        lines.append(f"{sc['name']}\t{'PASS' if ok else 'FAIL'}\t{elapsed:.2f}\t{code}\t{'OK' if ok else ' | '.join(errors)}\n")

    summary = fmea_root / "STAGE3_FMEA_SUMMARY.tsv"
    summary.write_text("".join(lines), encoding="utf-8")

    print(f"[Stage3 FMEA] wrote summary: {summary}")
    for line in lines[1:]:
        print("[Stage3 FMEA] " + line.strip())

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())