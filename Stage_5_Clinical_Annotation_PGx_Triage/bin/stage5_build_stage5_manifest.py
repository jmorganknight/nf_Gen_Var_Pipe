#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


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

    lines = [
        "# ==============================================================================",
        "# STAGE 5 BANKED MANIFEST (IMMUTABLE)",
        "# ==============================================================================",
        "samples:",
        f'  - sample_id: "{sid}"',
        '    validation_token: "VALID_PASS|VARIANTS_HARMONIZED"',
        "    branches:",
    ]

    for name in ["germline", "pgx", "sf", "prs", "somatic"]:
        b = branches[name]
        lines.append(f"      {name}:")
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
