#!/usr/bin/env python3
"""Run Stage 0 chaos/FMEA scenarios and emit STAGE0_FMEA_SUMMARY.tsv."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import textwrap
import time
from pathlib import Path


FAST_FAIL_TARGET_SECONDS = 10.0
FAST_FAIL_ASSERT_SECONDS = 15.0
SAMPLE_TEMPLATE = textwrap.dedent(
    """\
    samples:
      - sample_id: "{sample_id}"
        sample_type: "germline"
        pathologist_tumor_burden: 0.0
        gender: "{gender}"
        consent:
          prs_opt_in: {prs_opt_in}
          sf_opt_in: {sf_opt_in}
        sequencer:
          platform: "illumina"
          model: "NovaSeqX"
          flowcell_geometry: "native"
        fastq_forward: "{fastq_r1}"
        fastq_reverse: "{fastq_r2}"
        ingest_manifest:
          strict_pair_count_check: {strict_pair_count_check}
{ingest_manifest_extra}
        save_dir: "{save_dir}"
    """
)


def render_ingest_manifest_extra(extra: dict[str, object] | None) -> str:
    if not extra:
        return ""
    lines: list[str] = []
    for key, value in extra.items():
        if isinstance(value, bool):
            vtxt = "true" if value else "false"
        elif value is None:
            vtxt = "null"
        elif isinstance(value, (int, float)):
            vtxt = str(value)
        else:
            vtxt = json.dumps(str(value))
        lines.append(f"          {key}: {vtxt}")
    return "\n".join(lines)


def write_samples_yaml(
    path: Path,
    sample_id: str,
    fastq_r1: Path,
    fastq_r2: Path,
    strict_check: bool,
    outdir: Path,
    *,
    gender: str = "male",
    prs_opt_in: object = True,
    sf_opt_in: object = True,
    ingest_manifest_extra: dict[str, object] | None = None,
) -> None:
    def boolish(v: object) -> str:
        if isinstance(v, bool):
            return str(v).lower()
        if v is None:
            return "null"
        return str(v)

    path.write_text(
        SAMPLE_TEMPLATE.format(
            sample_id=sample_id,
            fastq_r1=str(fastq_r1),
            fastq_r2=str(fastq_r2),
            strict_pair_count_check=str(strict_check).lower(),
            save_dir=str(outdir),
            gender=gender,
            prs_opt_in=boolish(prs_opt_in),
            sf_opt_in=boolish(sf_opt_in),
            ingest_manifest_extra=render_ingest_manifest_extra(ingest_manifest_extra),
        ),
        encoding="utf-8",
    )


def run_nextflow(stage_root: Path, main_nf: Path, samples_yaml: Path, references_yaml: Path, thresholds_yaml: Path, infrastructure_yaml: Path, outdir: Path, work_dir: Path) -> tuple[int, float, str]:
    cmd = [
        "nextflow",
        "run",
        str(main_nf),
        "-profile",
        "docker",
        "--input",
        str(samples_yaml),
        "--references",
        str(references_yaml),
        "--thresholds",
        str(thresholds_yaml),
        "--infrastructure",
        str(infrastructure_yaml),
        "--outdir",
        str(outdir),
        "-work-dir",
        str(work_dir),
        "-ansi-log",
        "false",
    ]
    t0 = time.time()
    proc = subprocess.run(cmd, cwd=stage_root, capture_output=True, text=True)
    elapsed = time.time() - t0
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    return proc.returncode, elapsed, output


def load_rejection_reason(rejection_json: Path) -> list[str]:
    payload = json.loads(rejection_json.read_text(encoding="utf-8"))
    reasons = payload.get("rejection_reasons", [])
    if reasons:
        return reasons
    reason = payload.get("reason")
    return [reason] if reason else []


def reason_match(actual_reasons: list[str], expected: str) -> bool:
    aliases: dict[str, set[str]] = {
        "REJECT_LOW_QUALITY_FASTQ": {"LOW_Q30", "REJECT_LOW_QUALITY_FASTQ"},
        "REJECT_CONSENT_AMBIGUITY": {"REJECT_CONSENT_AMBIGUITY", "CONSENT_AMBIGUITY"},
    }
    accepted = aliases.get(expected, {expected})
    return any(r in accepted for r in actual_reasons)


def main() -> int:
    stage_root = Path(__file__).resolve().parents[2]
    inputs_dir = Path(__file__).resolve().parent / "inputs"
    run_root = Path(__file__).resolve().parent / "runs"
    run_root.mkdir(parents=True, exist_ok=True)

    main_nf = stage_root / "main.nf"
    thresholds_yaml = Path("/media/drive_c/nf_pipes/nf_WES_Onco_Risk/thresholds.yaml")
    default_refs_yaml = Path("/media/drive_c/nf_pipes/nf_WES_Onco_Risk/references.yaml")
    infrastructure_yaml = stage_root / "infrastructure.yaml"

    scenarios = [
        {
            "name": "corrupt_gzip_r1",
            "sample_id": "FMEA_CORRUPT_GZIP",
            "r1": inputs_dir / "corrupt_R1.fastq.gz",
            "r2": inputs_dir / "valid_R2.fastq.gz",
            "references": default_refs_yaml,
            "strict": True,
            "expect_exit_zero": True,
            "expect_rejection_reason": "FASTQ_CORRUPT_GZIP",
            "sample_overrides": {},
        },
        {
            "name": "asymmetric_pairs",
            "sample_id": "FMEA_ASYMMETRIC_PAIRS",
            "r1": inputs_dir / "valid_R1.fastq.gz",
            "r2": inputs_dir / "asymmetric_R2.fastq.gz",
            "references": default_refs_yaml,
            "strict": True,
            "expect_exit_zero": True,
            "expect_rejection_reason": "READ_PAIR_COUNT_MISMATCH",
            "sample_overrides": {},
        },
        {
            "name": "tampered_references_checksum",
            "sample_id": "FMEA_TAMPERED_REFERENCES",
            "r1": inputs_dir / "valid_R1.fastq.gz",
            "r2": inputs_dir / "valid_R2.fastq.gz",
            "references": inputs_dir / "tampered_references.yaml",
            "strict": False,
            "expect_exit_zero": False,
            "expect_rejection_reason": None,
            "sample_overrides": {},
        },
        {
            "name": "low_q_score_fastqs",
            "sample_id": "FMEA_LOW_Q_FASTQ",
            "r1": inputs_dir / "valid_R1.fastq.gz",
            "r2": inputs_dir / "valid_R2.fastq.gz",
            "references": default_refs_yaml,
            "strict": False,
            "expect_exit_zero": True,
            "expect_rejection_reason": "REJECT_LOW_QUALITY_FASTQ",
            "sample_overrides": {
                "ingest_manifest_extra": {
                    "observed_q30_fraction": 0.70,
                    "low_q_fraction": 0.20,
                    "low_q_floor": 20,
                }
            },
        },
        {
            "name": "missing_consent_token_map",
            "sample_id": "FMEA_MISSING_CONSENT",
            "r1": inputs_dir / "valid_R1.fastq.gz",
            "r2": inputs_dir / "valid_R2.fastq.gz",
            "references": default_refs_yaml,
            "strict": False,
            "expect_exit_zero": False,
            "expect_rejection_reason": "REJECT_CONSENT_AMBIGUITY",
            "sample_overrides": {
                "prs_opt_in": None,
                "sf_opt_in": None,
            },
        },
        {
            "name": "invalid_variant_branches_schema",
            "sample_id": "FMEA_BAD_BRANCH_SCHEMA",
            "r1": inputs_dir / "valid_R1.fastq.gz",
            "r2": inputs_dir / "valid_R2.fastq.gz",
            "references": default_refs_yaml,
            "strict": False,
            "expect_exit_zero": False,
            "expect_rejection_reason": "INVALID_VARIANT_BRANCHES_SCHEMA",
            "sample_overrides": {
                "variant_branches": "snv_indel=true",
            },
        },
    ]

    results = []

    for scenario in scenarios:
        scenario_dir = run_root / scenario["name"]
        if scenario_dir.exists():
            shutil.rmtree(scenario_dir)
        scenario_dir.mkdir(parents=True, exist_ok=True)

        outdir = scenario_dir / "out"
        work_dir = scenario_dir / "work"
        samples_yaml = scenario_dir / "samples.yaml"

        overrides = scenario.get("sample_overrides", {})
        write_samples_yaml(
            samples_yaml,
            sample_id=scenario["sample_id"],
            fastq_r1=scenario["r1"],
            fastq_r2=scenario["r2"],
            strict_check=scenario["strict"],
            outdir=outdir,
            gender=overrides.get("gender", "male"),
            prs_opt_in=overrides.get("prs_opt_in", True),
            sf_opt_in=overrides.get("sf_opt_in", True),
            ingest_manifest_extra=overrides.get("ingest_manifest_extra"),
        )

        if "variant_branches" in overrides:
            text = samples_yaml.read_text(encoding="utf-8")
            text = text.replace(
                '        save_dir: "' + str(outdir) + '"\n',
                '        variant_branches: "' + str(overrides["variant_branches"]) + '"\n        save_dir: "' + str(outdir) + '"\n',
            )
            samples_yaml.write_text(text, encoding="utf-8")

        code, elapsed, output = run_nextflow(
            stage_root=stage_root,
            main_nf=main_nf,
            samples_yaml=samples_yaml,
            references_yaml=scenario["references"],
            thresholds_yaml=thresholds_yaml,
            infrastructure_yaml=infrastructure_yaml,
            outdir=outdir,
            work_dir=work_dir,
        )

        rejection_candidates = [
            outdir / "audit_and_qc" / "stage0" / f"{scenario['sample_id']}.stage0_rejection_audit.json",
            outdir / scenario["sample_id"] / "audit_and_qc" / f"{scenario['sample_id']}.ingest_rejection_audit.json",
            outdir / scenario["sample_id"] / "audit_and_qc" / f"{scenario['sample_id']}.ingest_rejection_audit.json.json",
        ]
        rejection_json = next((p for p in rejection_candidates if p.exists()), rejection_candidates[0])

        checks = []

        if scenario["expect_exit_zero"]:
            checks.append((code == 0, f"expected exit_code=0 observed={code}"))
            checks.append((rejection_json.exists(), f"missing rejection audit: {rejection_json}"))
            if rejection_json.exists() and scenario["expect_rejection_reason"]:
                reasons = load_rejection_reason(rejection_json)
                checks.append(
                    (
                        reason_match(reasons, scenario["expect_rejection_reason"]),
                        f"expected reason {scenario['expect_rejection_reason']} not in {reasons}",
                    )
                )
        else:
            checks.append((code != 0, f"expected non-zero exit observed={code}"))
            if scenario["name"] == "tampered_references_checksum":
                checks.append(("Checksum mismatch" in output or "expected_sha256" in output, "tampered reference checksum signal not found"))
            if scenario["name"] == "missing_consent_token_map":
                checks.append(("REJECT_CONSENT_AMBIGUITY" in output, "missing REJECT_CONSENT_AMBIGUITY signal in output"))
            if scenario["name"] == "invalid_variant_branches_schema":
                if rejection_json.exists():
                    reasons = load_rejection_reason(rejection_json)
                    checks.append(
                        (
                            reason_match(reasons, "INVALID_VARIANT_BRANCHES_SCHEMA"),
                            f"expected INVALID_VARIANT_BRANCHES_SCHEMA not in {reasons}",
                        )
                    )
                else:
                    checks.append(("INVALID_VARIANT_BRANCHES_SCHEMA" in output, "missing INVALID_VARIANT_BRANCHES_SCHEMA signal in output"))

        checks.append((elapsed <= FAST_FAIL_ASSERT_SECONDS, f"elapsed={elapsed:.2f}s exceeds {FAST_FAIL_ASSERT_SECONDS:.1f}s"))

        failed_checks = [msg for ok, msg in checks if not ok]
        passed = not failed_checks
        details = "OK" if passed else " | ".join(failed_checks)
        if passed and elapsed > FAST_FAIL_TARGET_SECONDS:
            details = f"OK_WITHIN_ASSERT_BOUND (>{FAST_FAIL_TARGET_SECONDS:.1f}s objective)"

        results.append(
            {
                "scenario": scenario["name"],
                "status": "PASS" if passed else "FAIL",
                "elapsed_seconds": f"{elapsed:.2f}",
                "exit_code": str(code),
                "details": details,
            }
        )

    summary_path = Path(__file__).resolve().parent / "STAGE0_FMEA_SUMMARY.tsv"
    with summary_path.open("w", encoding="utf-8") as handle:
        handle.write("scenario\tstatus\telapsed_seconds\texit_code\tdetails\n")
        for row in results:
            handle.write(
                f"{row['scenario']}\t{row['status']}\t{row['elapsed_seconds']}\t{row['exit_code']}\t{row['details']}\n"
            )

    failing = [row for row in results if row["status"] == "FAIL"]
    print(f"[Stage0 FMEA] wrote summary: {summary_path}")
    for row in results:
        print(f"[Stage0 FMEA] {row['scenario']}: {row['status']} ({row['elapsed_seconds']}s)")

    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
