#!/usr/bin/env python3
"""Run Stage 1 chaos/FMEA scenarios and emit STAGE1_FMEA_SUMMARY.tsv."""

from __future__ import annotations

import shutil
import subprocess
import sys
import time
from pathlib import Path
import textwrap


def run_nf(stage1_root: Path, input_yaml: Path, references_yaml: Path, thresholds_yaml: Path, outdir: Path, stub: bool = False) -> tuple[int, float, str]:
    cmd = [
        "nextflow",
        "run",
        str(stage1_root / "main.nf"),
        "-profile",
        "docker",
        "--input",
        str(input_yaml),
        "--references",
        str(references_yaml),
        "--thresholds",
        str(thresholds_yaml),
        "--outdir",
        str(outdir),
        "-ansi-log",
        "false",
    ]
    if stub:
        cmd.append("-stub")

    t0 = time.time()
    proc = subprocess.run(cmd, cwd=stage1_root, capture_output=True, text=True)
    elapsed = time.time() - t0
    output = (proc.stdout or "") + "\n" + (proc.stderr or "")
    return proc.returncode, elapsed, output


def row(name: str, ok: bool, elapsed: float, code: int, details: str) -> str:
    return f"{name}\t{'PASS' if ok else 'FAIL'}\t{elapsed:.2f}\t{code}\t{details}\n"


def write_manifest(path: Path, text: str) -> None:
    path.write_text(textwrap.dedent(text).lstrip(), encoding="utf-8")


def load_rejection_reason(path: Path) -> list[str]:
    import json

    payload = json.loads(path.read_text(encoding="utf-8"))
    reasons = payload.get("rejection_reasons", [])
    if reasons:
        return reasons
    reason = payload.get("reason")
    return [reason] if reason else []


def main() -> int:
    stage1_root = Path(__file__).resolve().parents[2]
    fmea_root = Path(__file__).resolve().parent
    inputs = fmea_root / "inputs"
    runs = fmea_root / "runs"
    runs.mkdir(parents=True, exist_ok=True)

    references = Path("/media/drive_c/nf_pipes/nf_WES_Onco_Risk/references.yaml")
    thresholds = Path("/media/drive_c/nf_pipes/nf_WES_Onco_Risk/thresholds.yaml")
    stage0_nominal_candidates = [
        Path("/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_0_Preflight_Ingest_Gate/tests/mini_control/samples_hg002_banked_stage0.yaml"),
        Path("/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_0_Preflight_Ingest_Gate/tests/fixtures/banked_stage0/samples_hg002_banked_stage0.yaml"),
    ]
    stage0_nominal = next((path for path in stage0_nominal_candidates if path.exists()), stage0_nominal_candidates[0])

    scenarios = [
        {
            "name": "unvalidated_stage0_manifest",
            "input": inputs / "unvalidated_stage0_manifest.yaml",
            "references": references,
            "expect_code": "nonzero",
            "expect_rejection": True,
            "stub": True,
        },
        {
            "name": "corrupt_bam_header",
            "input": inputs / "corrupt_bam_header_manifest.yaml",
            "references": references,
            "expect_code": "nonzero",
            "expect_rejection": True,
            "stub": True,
        },
        {
            "name": "invalid_bwa_index",
            "input": stage0_nominal,
            "references": inputs / "invalid_bwa_index.yaml",
            "expect_code": "nonzero",
            "expect_rejection": True,
            "stub": True,
        },
        {
            "name": "nominal_hg002",
            "input": stage0_nominal,
            "references": references,
            "expect_code": "zero",
            "expect_rejection": False,
            "stub": True,
        },
        {
            "name": "invalid_variant_branches_schema",
            "input": inputs / "invalid_variant_branches_schema.yaml",
            "references": references,
            "expect_code": "nonzero",
            "expect_rejection": True,
            "stub": True,
        },
        {
            "name": "missing_enabled_branch_target_file",
            "input": inputs / "missing_enabled_branch_target_file.yaml",
            "references": references,
            "expect_code": "nonzero",
            "expect_rejection": True,
            "stub": True,
        },
    ]

    lines = ["scenario\tstatus\telapsed_seconds\texit_code\tdetails\n"]
    failed = False

    for sc in scenarios:
        outdir = runs / sc["name"] / "out"
        if outdir.parent.exists():
            shutil.rmtree(outdir.parent)
        outdir.parent.mkdir(parents=True, exist_ok=True)

        input_yaml = Path(sc["input"])
        if sc["name"] in {"invalid_variant_branches_schema", "missing_enabled_branch_target_file"}:
            scenario_input = runs / sc["name"] / "input.yaml"
            base_text = stage0_nominal.read_text(encoding="utf-8")
            if sc["name"] == "invalid_variant_branches_schema":
                mutated = base_text.replace(
                    "\n    save_dir:",
                    "\n    variant_branches: \"snv_indel=true\"\n    save_dir:",
                    1,
                )
            else:
                mutated = base_text.replace(
                    "\n    save_dir:",
                    "\n    branch_target_catalog: \"/tmp/missing_stage1_branch_catalog.tsv\"\n    variant_branches:\n      snv_indel: true\n      str_expansions: true\n    save_dir:",
                    1,
                )
            write_manifest(scenario_input, mutated)
            input_yaml = scenario_input

        code, elapsed, output = run_nf(
            stage1_root=stage1_root,
            input_yaml=input_yaml,
            references_yaml=Path(sc["references"]),
            thresholds_yaml=thresholds,
            outdir=outdir,
            stub=bool(sc["stub"]),
        )

        rejection_json = outdir / "audit_and_qc" / "stage1" / "stage1_rejection_audit.json"

        rejection_candidates = [rejection_json, runs / sc["name"] / "stage1_rejection_audit.json", runs / sc["name"] / "out" / "stage1_rejection_audit.json"]
        rejection = next((p for p in rejection_candidates if p.exists()), None)
        banked = outdir / "samples_hg002_banked_stage1.yaml"

        checks = []
        if sc["expect_code"] == "zero":
            checks.append((code == 0, f"expected exit_code=0 observed={code}"))
            checks.append((banked.exists(), f"missing banked manifest: {banked}"))
        else:
            checks.append((code != 0, f"expected non-zero exit_code observed={code}"))

        if sc["expect_rejection"]:
            checks.append((rejection is not None, f"missing rejection audit: {rejection_candidates[0]}"))

        if sc["name"] == "invalid_bwa_index":
            checks.append(("BWA index" in output or "BWA_INDEX_MISSING" in output, "missing BWA index signal in output"))
        if sc["name"] == "unvalidated_stage0_manifest":
            checks.append(("STAGE1_PRECONDITION_FAILURE" in output or code != 0, "missing Stage 1 precondition failure signal"))
        if sc["name"] == "invalid_variant_branches_schema":
            if rejection_json.exists():
                checks.append(("INVALID_VARIANT_BRANCHES_SCHEMA" in load_rejection_reason(rejection_json), "missing INVALID_VARIANT_BRANCHES_SCHEMA signal in audit"))
            else:
                checks.append(("INVALID_VARIANT_BRANCHES_SCHEMA" in output, "missing INVALID_VARIANT_BRANCHES_SCHEMA signal in output"))
        if sc["name"] == "missing_enabled_branch_target_file":
            if rejection_json.exists():
                checks.append(("REJECT_MISSING_BRANCH_CATALOG" in load_rejection_reason(rejection_json), "missing REJECT_MISSING_BRANCH_CATALOG signal in audit"))
            else:
                checks.append(("REJECT_MISSING_BRANCH_CATALOG" in output, "missing REJECT_MISSING_BRANCH_CATALOG signal in output"))

        errs = [msg for ok, msg in checks if not ok]
        ok = not errs
        if not ok:
            failed = True
        details = "OK" if ok else " | ".join(errs)
        lines.append(row(sc["name"], ok, elapsed, code, details))

    summary = fmea_root / "STAGE1_FMEA_SUMMARY.tsv"
    summary.write_text("".join(lines), encoding="utf-8")

    print(f"[Stage1 FMEA] wrote summary: {summary}")
    for line in lines[1:]:
        print("[Stage1 FMEA] " + line.strip())

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
