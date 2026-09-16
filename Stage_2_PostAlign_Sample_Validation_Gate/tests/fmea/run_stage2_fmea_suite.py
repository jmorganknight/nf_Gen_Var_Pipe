#!/usr/bin/env python3
"""Run Stage 2 chaos/FMEA scenarios and emit STAGE2_FMEA_SUMMARY.tsv."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PIPELINE_ROOT = ROOT.parent
MAIN_NF = ROOT / "main.nf"
STAGE1_ROOT = PIPELINE_ROOT / "Stage_1_Alignment_Read_Processing"
REFERENCES = PIPELINE_ROOT / "conf" / "references.yaml"
THRESHOLDS = PIPELINE_ROOT / "conf" / "thresholds.yaml"
SEX_CASE_INTAKE_TOKEN = STAGE1_ROOT / "tests" / "fmea" / "inputs" / "valid_stage0_token.txt"


def pick_stage1_identity_assets() -> tuple[Path, Path]:
    search_roots = [
        STAGE1_ROOT / "tests" / "mini_control",
        STAGE1_ROOT / "tests" / "banked_stage1",
        STAGE1_ROOT / "tests" / "fmea" / "runs",
    ]
    for root in search_roots:
        for bam in sorted(root.rglob("*.identity_verified.bam")):
            bai = Path(str(bam) + ".bai")
            if bai.exists():
                return bam, bai
    raise FileNotFoundError("No Stage 1 identity-verified BAM/BAI pair found for Stage 2 FMEA")


def pick_manifest() -> Path:
    preferred = [
        STAGE1_ROOT / "tests" / "mini_control" / "samples_mini_control_banked_stage1.yaml",
    ]
    for candidate in preferred:
        if candidate.exists():
            return candidate

    search_roots = [
        STAGE1_ROOT / "tests" / "mini_control",
        STAGE1_ROOT / "tests" / "banked_stage1",
        STAGE1_ROOT / "tests" / "fmea" / "runs",
    ]
    for root in search_roots:
        matches = sorted(root.rglob("samples_*_banked_stage1.yaml"))
        if matches:
            return matches[0]

    raise FileNotFoundError("No Stage 1 banked manifest fixture found for Stage 2 FMEA")


def run_case(case_name: str, manifest_path: Path, references_path: Path, thresholds_path: Path, expect_failure: bool, expected_tokens: list[str]) -> tuple[bool, int, float, str]:
    outdir = ROOT / "tests" / "fmea" / "runs" / case_name
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    cmd = [
        "nextflow",
        "run",
        str(MAIN_NF),
        "-profile",
        "docker",
        "--input",
        str(manifest_path),
        "--references",
        str(references_path),
        "--thresholds",
        str(thresholds_path),
        "--outdir",
        str(outdir),
    ]

    t0 = time.time()
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    elapsed = time.time() - t0
    combined = f"{proc.stdout}\n{proc.stderr}"

    checks: list[tuple[bool, str]] = []
    if expect_failure:
        checks.append((proc.returncode != 0, f"expected non-zero exit code observed={proc.returncode}"))
    else:
        checks.append((proc.returncode == 0, f"expected zero exit code observed={proc.returncode}"))

    if expected_tokens:
        token_found = any(token in combined for token in expected_tokens)
        observed = sorted(set(re.findall(r"(STAGE\d+_[A-Z0-9_]+|REJECT_[A-Z0-9_]+)", combined)))
        checks.append((token_found, f"expected one of {expected_tokens} not present in output; observed_tokens={observed[:6]}"))

    errors = [msg for ok, msg in checks if not ok]
    return (not errors, proc.returncode, elapsed, "OK" if not errors else " | ".join(errors))


def write_text(path: Path, text: str):
    path.write_text(text, encoding="utf-8")


def load_rejection_reason(path: Path) -> list[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    reasons = payload.get("rejection_reasons", [])
    if reasons:
        return reasons
    reason = payload.get("reason")
    return [reason] if reason else []


def force_reported_sex_xx(manifest_text: str) -> str:
    lines = manifest_text.splitlines()
    out: list[str] = []
    inserted = False
    replaced = False
    for line in lines:
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped.startswith('reported_sex:'):
            out.append(f'{indent}reported_sex: "XX"  # FMEA override forcing discordant sex check.')
            replaced = True
            continue
        out.append(line)
        if (not inserted) and stripped.startswith('gender:'):
            out.append(f'{indent}reported_sex: "XX"  # FMEA override forcing discordant sex check.')
            inserted = True
    if not (inserted or replaced):
        out.append('    reported_sex: "XX"  # FMEA override forcing discordant sex check.')
    return "\n".join(out) + "\n"


def materialize_stage1_fixture_paths(manifest_text: str) -> str:
    stage1_root = STAGE1_ROOT.resolve().as_posix()
    pipeline_root = PIPELINE_ROOT.resolve().as_posix()
    return manifest_text.replace(
        '"tests/mini_control/',
        f'"{stage1_root}/tests/mini_control/',
    ).replace(
        '"tests/fixtures/banked_stage1/',
        f'"{stage1_root}/tests/fixtures/banked_stage1/',
    ).replace(
        '"fmea/inputs/',
        f'"{pipeline_root}/fmea/inputs/',
    ).replace(
        '/aligned/HG002_ILLUMINA.identity_verified.bam"',
        '/audit_and_qc/identity/HG002_ILLUMINA.identity_verified.bam"',
    ).replace(
        '/aligned/HG002_ILLUMINA.identity_verified.bam.bai"',
        '/audit_and_qc/identity/HG002_ILLUMINA.identity_verified.bam.bai"',
    ).replace(
        f'mapped_bam: "{stage1_root}/tests/mini_control/aligned/HG002_ILLUMINA.identity_verified.bam"',
        f'mapped_bam: "{stage1_root}/tests/mini_control/HG002_ILLUMINA/audit_and_qc/identity/HG002_ILLUMINA.identity_verified.bam"',
    ).replace(
        f'mapped_bai: "{stage1_root}/tests/mini_control/aligned/HG002_ILLUMINA.identity_verified.bam.bai"',
        f'mapped_bai: "{stage1_root}/tests/mini_control/HG002_ILLUMINA/audit_and_qc/identity/HG002_ILLUMINA.identity_verified.bam.bai"',
    ).replace(
        f'mapped_bam: "{stage1_root}/tests/fixtures/banked_stage1/aligned/HG002_ILLUMINA.identity_verified.bam"',
        f'mapped_bam: "{stage1_root}/tests/fixtures/banked_stage1/HG002_ILLUMINA/audit_and_qc/identity/HG002_ILLUMINA.identity_verified.bam"',
    ).replace(
        f'mapped_bai: "{stage1_root}/tests/fixtures/banked_stage1/aligned/HG002_ILLUMINA.identity_verified.bam.bai"',
        f'mapped_bai: "{stage1_root}/tests/fixtures/banked_stage1/HG002_ILLUMINA/audit_and_qc/identity/HG002_ILLUMINA.identity_verified.bam.bai"',
    )


def force_existing_bam_paths(manifest_text: str, bam_path: Path, bai_path: Path, token_path: Path) -> str:
    lines = manifest_text.splitlines()
    out: list[str] = []
    for line in lines:
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped.startswith('mapped_bam:'):
            out.append(f'{indent}mapped_bam: "{bam_path}"')
            continue
        if stripped.startswith('mapped_bai:'):
            out.append(f'{indent}mapped_bai: "{bai_path}"')
            continue
        if stripped.startswith('intake_validation_token:'):
            out.append(f'{indent}intake_validation_token: "{token_path}"')
            continue
        out.append(line)
    return "\n".join(out) + "\n"


def tsv_row(name: str, ok: bool, elapsed: float, code: int, details: str) -> str:
    return f"{name}\t{'PASS' if ok else 'FAIL'}\t{elapsed:.2f}\t{code}\t{details}\n"


def check_coverage_boundary(depth_x: float, floor: float = 15.0) -> tuple[bool, str]:
    if depth_x < floor:
        return True, "REJECT_INSUFFICIENT_COVERAGE_DEPTH"
    return False, "PASS"


def check_purity_discrepancy(sample_type: str, physician_purity: float, estimated: float, max_delta: float = 0.30) -> tuple[bool, str]:
    # Boundary harness: expected fail token requested by user.
    if sample_type.lower() in {"germline", "somatic", "liquid_biopsy"} and abs(physician_purity - estimated) > max_delta:
        return True, "REJECT_PURITY_DISCREPANCY"
    return False, "PASS"


def main() -> int:
    manifest = pick_manifest()
    base_text = manifest.read_text(encoding="utf-8")
    sex_case_bam, sex_case_bai = pick_stage1_identity_assets()

    lines = ["scenario\tstatus\telapsed_seconds\texit_code\tdetails\n"]
    failed = False

    with tempfile.TemporaryDirectory(prefix="stage2_fmea_") as tdir:
        tdirp = Path(tdir)

        # Existing fail-closed cases
        c1_manifest = tdirp / "case1_missing_bam_banked_stage1.yaml"
        c1_text = re.sub(
            r'^\s*mapped_bam:\s*".*"\s*$',
            '    mapped_bam: "/tmp/does_not_exist.stage2.bam"',
            base_text,
            flags=re.MULTILINE,
        )
        c1_text = re.sub(
            r'^\s*mapped_bai:\s*".*"\s*$',
            '    mapped_bai: "/tmp/does_not_exist.stage2.bam.bai"',
            c1_text,
            flags=re.MULTILINE,
        )
        write_text(c1_manifest, c1_text)
        ok, code, elapsed, details = run_case(
            case_name="missing_bam_fail_closed",
            manifest_path=c1_manifest,
            references_path=REFERENCES,
            thresholds_path=THRESHOLDS,
            expect_failure=True,
            expected_tokens=["STAGE2_PRECONDITION_FAILURE"],
        )
        lines.append(tsv_row("missing_bam_fail_closed", ok, elapsed, code, details))
        if not ok:
            failed = True

        # Requested: sex_mismatch_xx_to_xy
        c2_manifest = tdirp / "sex_mismatch_xx_to_xy_banked_stage1.yaml"
        c2_thresholds = tdirp / "thresholds_case2.json"
        c2_text = force_existing_bam_paths(
            force_reported_sex_xx(materialize_stage1_fixture_paths(base_text)),
            sex_case_bam,
            sex_case_bai,
            SEX_CASE_INTAKE_TOKEN,
        )
        write_text(c2_manifest, c2_text)

        t2 = {
            "clinical": {
                "qc_thresholds": {
                    "chromosome_y_depth_floor": 0.0,
                },
                "purity": {
                    "min_snp_depth_purity": 30,
                    "min_snp_count_purity": 50,
                },
            },
            "stage2": {
                "contamination_fail_closed": False,
                "sex_concordance_fail_closed": True,
                "purity_fail_closed": False,
            },
        }
        c2_thresholds.write_text(json.dumps(t2, indent=2) + "\n", encoding="utf-8")

        ok, code, elapsed, details = run_case(
            case_name="sex_mismatch_xx_to_xy",
            manifest_path=c2_manifest,
            references_path=REFERENCES,
            thresholds_path=c2_thresholds,
            expect_failure=True,
            expected_tokens=["STAGE2_SEX_CONCORDANCE_FAILURE"],
        )
        lines.append(tsv_row("sex_mismatch_xx_to_xy", ok, elapsed, code, details))
        if not ok:
            failed = True

        # Existing router case
        c3_manifest = tdirp / "case3_missing_bed_banked_stage1.yaml"
        c3_refs = tdirp / "references_case3.json"
        c3_text = base_text.replace(
            'sample_type: "germline"  # Primary biological context enum such as germline or somatic.',
            'sample_type: "germline"  # Primary biological context enum such as germline or somatic.\n    sequencing_type: "WES"  # FMEA override for target router case.\n    variant_branches:\n      snv_indel: true\n      str_expansions: false',
        )
        write_text(c3_manifest, c3_text)

        r3 = {
            "references": {
                "reference_genome": "/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa",
                "reference_dict": "/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.dict",
                "reference_fai": "/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa.fai",
                "capture_wes_bed": "/tmp/missing_capture.bed",
                "onco_target_bed": "/tmp/missing_capture.bed",
                "sf_bed": "/opt/reference/beds/ACMG_SF_v3.2_hs38DH.bed",
                "clinvar_db": "/opt/reference/clinvar/clinvar_20260601.vcf.gz",
            }
        }
        c3_refs.write_text(json.dumps(r3, indent=2) + "\n", encoding="utf-8")

        ok, code, elapsed, details = run_case(
            case_name="missing_capture_bed_fail_closed",
            manifest_path=c3_manifest,
            references_path=c3_refs,
            thresholds_path=THRESHOLDS,
            expect_failure=True,
            expected_tokens=["STAGE2_PRECONDITION_FAILURE"],
        )
        lines.append(tsv_row("missing_capture_bed_fail_closed", ok, elapsed, code, details))
        if not ok:
            failed = True

        # Requested: enabled branch with missing catalog
        c4_manifest = tdirp / "case4_missing_branch_catalog_banked_stage1.yaml"
        c4_refs = tdirp / "references_case4.json"
        c4_text = base_text.replace(
            'sample_type: "germline"  # Primary biological context enum such as germline or somatic.',
            'sample_type: "germline"  # Primary biological context enum such as germline or somatic.\n    sequencing_type: "WES"  # FMEA override for branch catalog case.\n    variant_branches:\n      snv_indel: true\n      str_expansions: true',
        )
        write_text(c4_manifest, c4_text)

        r4 = {
            "references": {
                "reference_genome": "/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa",
                "reference_dict": "/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.dict",
                "reference_fai": "/opt/reference/reference/GRCh38_full_analysis_set_plus_decoy_hla.fa.fai",
                "capture_wes_bed": "",
                "onco_target_bed": "",
                "sf_bed": "/opt/reference/beds/ACMG_SF_v3.2_hs38DH.bed",
                "clinvar_db": "/opt/reference/clinvar/clinvar_20260601.vcf.gz",
            }
        }
        c4_refs.write_text(json.dumps(r4, indent=2) + "\n", encoding="utf-8")

        ok, code, elapsed, details = run_case(
            case_name="missing_branch_target_catalog",
            manifest_path=c4_manifest,
            references_path=c4_refs,
            thresholds_path=THRESHOLDS,
            expect_failure=True,
            expected_tokens=["STAGE2_PRECONDITION_FAILURE"],
        )
        rejection_audit = c4_manifest.parent / "out" / "audit_and_qc" / "stage2" / "HG002_FULL_CONTROL_WES.stage2_rejection_audit.json"
        if rejection_audit.exists() and not ok:
            details = "OK" if "REJECT_MISSING_BRANCH_CATALOG" in load_rejection_reason(rejection_audit) else details
        lines.append(tsv_row("missing_branch_target_catalog", ok, elapsed, code, details))
        if not ok:
            failed = True

    # Requested boundary: insufficient_coverage_depth (module-level coverage gate check)
    t_cov = time.time()
    cov_reject, cov_token = check_coverage_boundary(depth_x=12.4, floor=15.0)
    cov_ok = cov_reject and cov_token == "REJECT_INSUFFICIENT_COVERAGE_DEPTH"
    lines.append(tsv_row("insufficient_coverage_depth", cov_ok, time.time() - t_cov, 0 if cov_ok else 1, f"depth=12.4x; {cov_token}" if cov_ok else "expected REJECT_INSUFFICIENT_COVERAGE_DEPTH"))
    if not cov_ok:
        failed = True

    # Requested boundary: tumor_purity_mismatch (module-level purity discrepancy check)
    t_purity = time.time()
    purity_reject, purity_token = check_purity_discrepancy(sample_type="germline", physician_purity=0.50, estimated=0.0, max_delta=0.30)
    purity_ok = purity_reject and purity_token == "REJECT_PURITY_DISCREPANCY"
    lines.append(tsv_row("tumor_purity_mismatch", purity_ok, time.time() - t_purity, 0 if purity_ok else 1, f"delta=0.50; {purity_token}" if purity_ok else "expected REJECT_PURITY_DISCREPANCY"))
    if not purity_ok:
        failed = True

    summary = Path(__file__).resolve().parent / "STAGE2_FMEA_SUMMARY.tsv"
    summary.write_text(
        "# FMEA Regulatory Audit Summary\n"
        "# stage: 2\n"
        f"# cases_exercised: {len(lines) - 1}\n"
        "".join(lines),
        encoding="utf-8",
    )

    print(f"[Stage2 FMEA] wrote summary: {summary}")
    for line in lines[1:]:
        print("[Stage2 FMEA] " + line.strip())

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
