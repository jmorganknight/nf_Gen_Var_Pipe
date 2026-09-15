#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


ALLOWED_BRANCHES = ["germline", "pgx", "sf", "prs", "somatic"]
STATUS_COMPLETED = "COMPLETED"
STATUS_SKIPPED = "SKIPPED_BY_CLINICAL_DIRECTIVE"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_manifest(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if "sample_id" not in data:
        raise SystemExit(f"STAGE5_MANIFEST_FAILURE: branch manifest missing sample_id: {path}")
    return data


def normalize_requested(branch_payload: dict) -> list[str]:
    raw = branch_payload.get("requested_branches", [])
    if not isinstance(raw, list):
        return []
    normalized = []
    for item in raw:
        text = str(item).strip().lower()
        if text and text not in normalized:
            normalized.append(text)
    return normalized


def assert_branch_payload_integrity(branch_name: str, payload: dict) -> None:
    status = payload.get("status")
    if not isinstance(status, str) or not status.strip():
        raise SystemExit(
            f"STAGE5_CLINICAL_INTEGRITY_FAILURE: missing required status for branch '{branch_name}'"
        )
    status = status.strip()
    if status not in {STATUS_COMPLETED, STATUS_SKIPPED}:
        raise SystemExit(
            f"STAGE5_CLINICAL_INTEGRITY_FAILURE: invalid status '{status}' for branch '{branch_name}'"
        )
    if status == STATUS_SKIPPED:
        reason = str(payload.get("skip_reason", "")).strip()
        if not reason:
            raise SystemExit(
                f"STAGE5_CLINICAL_INTEGRITY_FAILURE: missing skip_reason for skipped branch '{branch_name}'"
            )
        requested = payload.get("requested_branches")
        if not isinstance(requested, list):
            raise SystemExit(
                f"STAGE5_CLINICAL_INTEGRITY_FAILURE: requested_branches must be a list for skipped branch '{branch_name}'"
            )


def assert_branch_sample_ids(branches: dict[str, dict], expected_sample_id: str) -> None:
    mismatches = []
    for branch_name, payload in branches.items():
        observed = str(payload.get("sample_id", "")).strip()
        if observed != expected_sample_id:
            mismatches.append(
                f"{branch_name}: observed_sample_id='{observed or 'MISSING'}' expected_sample_id='{expected_sample_id}'"
            )
    if mismatches:
        raise SystemExit(
            "STAGE5_CLINICAL_INTEGRITY_FAILURE: branch manifest sample_id mismatch detected; "
            + "; ".join(mismatches)
        )


def main():
    ap = argparse.ArgumentParser(description="Assemble immutable Stage5 multi-branch manifest")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--germline", required=True)
    ap.add_argument("--pgx", required=True)
    ap.add_argument("--sf", required=True)
    ap.add_argument("--prs", required=True)
    ap.add_argument("--somatic", required=True)
    ap.add_argument("--out-yaml", required=True)
    args = ap.parse_args()

    files = {
        "germline": Path(args.germline),
        "pgx": Path(args.pgx),
        "sf": Path(args.sf),
        "prs": Path(args.prs),
        "somatic": Path(args.somatic),
    }

    branches = {name: load_manifest(path) for name, path in files.items()}
    sid = args.sample_id
    assert_branch_sample_ids(branches, sid)

    requested_sets = []
    for name in ALLOWED_BRANCHES:
        payload = branches[name]
        assert_branch_payload_integrity(name, payload)
        requested = normalize_requested(payload)
        if requested:
            requested_sets.append((name, requested))

    if requested_sets:
        canonical = requested_sets[0][1]
        mismatched = [
            f"{name}={requested}" for name, requested in requested_sets[1:] if requested != canonical
        ]
        if mismatched:
            raise SystemExit(
                "STAGE5_CLINICAL_INTEGRITY_FAILURE: inconsistent requested_branches across branch manifests; "
                + f"expected={canonical} mismatched={mismatched}"
            )

    lines = [
        "# ==============================================================================",
        "# STAGE 5 BANKED MANIFEST (IMMUTABLE)",
        "# ==============================================================================",
        "samples:",
        f'  - sample_id: "{sid}"',
        '    validation_token: "VALID_PASS|VARIANTS_HARMONIZED"',
        "    branches:",
    ]

    for name in ALLOWED_BRANCHES:
        b = branches[name]
        status = str(b.get("status", "")).strip()
        requested = normalize_requested(b)
        lines.append(f"      {name}:")
        lines.append(f'        status: "{status}"')
        lines.append(f'        skip_reason: "{str(b.get("skip_reason", ""))}"')
        lines.append(f'        requested_branches: {json.dumps(requested)}')
        lines.append(f'        skipped: {str(status == STATUS_SKIPPED).lower()}')
        lines.append('        bypass_policy: "CLINICAL_DIRECTIVE_CONTROL_PLANE"')
        lines.append(f'        branch_manifest_json: "{str(files[name].resolve())}"')
        lines.append(f'        branch_manifest_sha256: "{sha256(files[name])}"')
        lines.append(f'        primary_vcf: "{b.get("primary_vcf", "")}"')
        lines.append(f'        primary_vcf_tbi: "{b.get("primary_vcf_tbi", "")}"')
        lines.append(f'        primary_vcf_sha256: "{b.get("primary_vcf_sha256", "")}"')
        lines.append(f'        primary_vcf_tbi_sha256: "{b.get("primary_vcf_tbi_sha256", "")}"')
        lines.append(f'        input_rows: {int(b.get("input_rows", 0))}')
        lines.append(f'        output_rows: {int(b.get("output_rows", 0))}')
        lines.append(f'        dropped_rows: {int(b.get("dropped_rows", 0))}')

    Path(args.out_yaml).write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
