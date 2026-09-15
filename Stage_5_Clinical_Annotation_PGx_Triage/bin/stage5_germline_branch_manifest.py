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


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main():
    ap = argparse.ArgumentParser(description="Build Stage5 germline branch manifest")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--benign-vcf", required=True)
    ap.add_argument("--pathogenic-vcf", required=True)
    ap.add_argument("--vus-vcf", required=True)
    ap.add_argument("--vus-triaged-vcf", required=True)
    ap.add_argument("--partition-audit", required=True)
    ap.add_argument("--zero-loss-audit", required=True)
    ap.add_argument("--hgmd-audit", required=True)
    ap.add_argument("--out-manifest", required=True)
    args = ap.parse_args()

    b = Path(args.benign_vcf)
    p = Path(args.pathogenic_vcf)
    v = Path(args.vus_vcf)
    vt = Path(args.vus_triaged_vcf)

    partition = load_json(args.partition_audit)
    zero_loss = load_json(args.zero_loss_audit)

    manifest = {
        "sample_id": args.sample_id,
        "branch": "germline",
        "primary_vcf": str(vt.resolve()),
        "primary_vcf_tbi": str(Path(str(vt) + ".tbi").resolve()),
        "primary_vcf_sha256": sha256(vt),
        "primary_vcf_tbi_sha256": sha256(Path(str(vt) + ".tbi")),
        "input_rows": int(partition.get("input_rows", 0)),
        "output_rows": int(partition.get("input_rows", 0)),
        "dropped_rows": int(zero_loss.get("dropped_rows", 0)),
        "artifacts": {
            "benign_vcf": str(b.resolve()),
            "benign_vcf_tbi": str(Path(str(b) + ".tbi").resolve()),
            "pathogenic_vcf": str(p.resolve()),
            "pathogenic_vcf_tbi": str(Path(str(p) + ".tbi").resolve()),
            "vus_vcf": str(v.resolve()),
            "vus_vcf_tbi": str(Path(str(v) + ".tbi").resolve()),
            "vus_triaged_vcf": str(vt.resolve()),
            "vus_triaged_vcf_tbi": str(Path(str(vt) + ".tbi").resolve()),
        },
        "audit_json": {
            "partition": str(Path(args.partition_audit).resolve()),
            "zero_loss": str(Path(args.zero_loss_audit).resolve()),
            "hgmd_triage": str(Path(args.hgmd_audit).resolve()),
        },
    }
    Path(args.out_manifest).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
