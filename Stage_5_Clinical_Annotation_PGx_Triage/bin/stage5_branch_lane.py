#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import pysam


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_criteria(path_text):
    if not path_text:
        return set()
    p = Path(path_text)
    if not p.exists():
        raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: criteria file missing {p}")
    vals = set()
    for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        vals.add(line.split("\t")[0])
    return vals


def info_token(rec, *keys):
    for k in keys:
        v = rec.info.get(k)
        if v is None:
            continue
        if isinstance(v, (tuple, list)):
            return str(v[0]) if v else ""
        return str(v)
    return ""


def main():
    ap = argparse.ArgumentParser(description="Stage5 isolated branch lane extractor")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--mode", required=True, choices=["pgx", "sf", "prs", "somatic"])
    ap.add_argument("--in-vcf", required=True)
    ap.add_argument("--criteria", default="")
    ap.add_argument("--out-vcf", required=True)
    ap.add_argument("--out-audit", required=True)
    ap.add_argument("--out-manifest", required=True)
    args = ap.parse_args()

    criteria = load_criteria(args.criteria) if args.mode in {"pgx", "sf", "prs"} else set()

    invcf = pysam.VariantFile(args.in_vcf)
    out = pysam.VariantFile(args.out_vcf, "wz", header=invcf.header)

    input_rows = 0
    output_rows = 0

    for rec in invcf:
        input_rows += 1
        keep = True

        if args.mode in {"pgx", "sf"}:
            gene = info_token(rec, "GENE", "SYMBOL", "GENE_SYMBOL")
            keep = gene in criteria if criteria else False
        elif args.mode == "prs":
            key = f"{rec.contig}:{rec.pos}:{rec.ref}:{','.join(rec.alts or ['.'])}"
            keep = key in criteria if criteria else False
        elif args.mode == "somatic":
            branch = info_token(rec, "BRANCH").lower()
            keep = branch in {"structural_variants", "copy_number_cnv", "trisomy_aneuploidy"}

        if keep:
            out.write(rec)
            output_rows += 1

    out.close()
    pysam.tabix_index(args.out_vcf, preset="vcf", force=True)

    dropped_rows = input_rows - output_rows
    audit = {
        "sample_id": args.sample_id,
        "node": f"STAGE5_{args.mode.upper()}_LANE",
        "input_rows": input_rows,
        "output_rows": output_rows,
        "dropped_rows": dropped_rows,
        "status": "PASS",
    }
    Path(args.out_audit).write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")

    out_vcf = Path(args.out_vcf)
    out_tbi = Path(args.out_vcf + ".tbi")
    manifest = {
        "sample_id": args.sample_id,
        "branch": args.mode,
        "primary_vcf": str(out_vcf.resolve()),
        "primary_vcf_tbi": str(out_tbi.resolve()),
        "primary_vcf_sha256": sha256(out_vcf),
        "primary_vcf_tbi_sha256": sha256(out_tbi),
        "input_rows": input_rows,
        "output_rows": output_rows,
        "dropped_rows": dropped_rows,
        "audit_json": str(Path(args.out_audit).resolve()),
    }
    Path(args.out_manifest).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
