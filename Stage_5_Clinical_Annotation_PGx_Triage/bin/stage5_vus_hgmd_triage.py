#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import pysam


def load_hgmd_keys(path_text):
    if not path_text:
        return set()
    p = Path(path_text)
    if not p.exists():
        raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: missing HGMD DB {p}")

    keys = set()
    if p.suffix in {".tsv", ".txt"}:
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            keys.add(line.split("\t")[0])
        return keys

    vf = pysam.VariantFile(str(p))
    for rec in vf:
        key = f"{rec.contig}:{rec.pos}:{rec.ref}:{','.join(rec.alts or ['.'])}"
        cl = str(rec.info.get("CLASS") or rec.info.get("HGMD_CLASS") or "")
        if cl.upper().startswith("DM"):
            keys.add(key)
    return keys


def key_for_record(rec):
    return f"{rec.contig}:{rec.pos}:{rec.ref}:{','.join(rec.alts or ['.'])}"


def main():
    ap = argparse.ArgumentParser(description="HGMD triage for Stage5 VUS set")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--vus-vcf", required=True)
    ap.add_argument("--scores-json", required=True)
    ap.add_argument("--hgmd-db", required=True)
    ap.add_argument("--out-vcf", required=True)
    ap.add_argument("--out-audit", required=True)
    args = ap.parse_args()

    hgmd_dm = load_hgmd_keys(args.hgmd_db)
    scored = json.loads(Path(args.scores_json).read_text(encoding="utf-8")).get("scores", {})

    invcf = pysam.VariantFile(args.vus_vcf)
    out = pysam.VariantFile(args.out_vcf, "wz", header=invcf.header)

    upgraded = 0
    total = 0
    details = []
    for rec in invcf:
        total += 1
        key = key_for_record(rec)
        s = scored.get(key, {})
        score = float(s.get("score", 0.0) or 0.0)
        hit = key in hgmd_dm
        triage = "RETAIN_VUS"
        if hit and score >= 0.8:
            triage = "ESCALATE_REVIEW"
            upgraded += 1
        details.append({"key": key, "hgmd_dm": hit, "score": score, "triage": triage})
        out.write(rec)

    out.close()
    pysam.tabix_index(args.out_vcf, preset="vcf", force=True)

    audit = {
        "sample_id": args.sample_id,
        "node": "VUS_HGMD_TRIAGE",
        "input_vus_rows": total,
        "output_vus_rows": total,
        "hgmd_hits": sum(1 for d in details if d["hgmd_dm"]),
        "escalated_review_count": upgraded,
        "details": details,
        "status": "PASS",
    }
    Path(args.out_audit).write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
