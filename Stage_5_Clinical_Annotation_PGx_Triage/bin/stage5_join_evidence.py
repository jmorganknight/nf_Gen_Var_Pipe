#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def read_tsv(path, expected_cols):
    rows = {}
    duplicates = []
    for raw in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        cols = raw.split("\t")
        if len(cols) < expected_cols:
            raise SystemExit(f"STAGE5_JOIN_FAILURE: malformed line in {path}: {raw}")
        key = cols[0]
        if key in rows:
            duplicates.append(key)
            continue
        rows[key] = cols[1:]
    if duplicates:
        preview = sorted(set(duplicates))[:20]
        raise SystemExit(
            "STAGE5_ZERO_LOSS_FAILURE: duplicate variant keys detected in evidence stream; "
            f"file={path} duplicate_count={len(duplicates)} preview={preview}"
        )
    return rows


def main():
    ap = argparse.ArgumentParser(description="Join Stage5 VEP/ClinVar/gnomAD evidence")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--vep-tsv", required=True)
    ap.add_argument("--clinvar-tsv", required=True)
    ap.add_argument("--gnomad-tsv", required=True)
    ap.add_argument("--out-joined-tsv", required=True)
    ap.add_argument("--out-audit", required=True)
    args = ap.parse_args()

    vep = read_tsv(args.vep_tsv, 6)
    clin = read_tsv(args.clinvar_tsv, 3)
    gno = read_tsv(args.gnomad_tsv, 2)

    vep_keys = set(vep.keys())
    clin_keys = set(clin.keys())
    gno_keys = set(gno.keys())

    mismatch = sorted((vep_keys ^ clin_keys) | (vep_keys ^ gno_keys) | (clin_keys ^ gno_keys))
    if mismatch:
        preview = mismatch[:20]
        raise SystemExit(
            "STAGE5_ZERO_LOSS_FAILURE: evidence streams key mismatch; "
            f"mismatch_count={len(mismatch)} preview={preview}"
        )

    joined_keys = sorted(vep_keys)
    out_lines = []
    for key in joined_keys:
        consequence, cadd, revel, alpha, spliceai = vep[key]
        clnsig, stars = clin[key]
        af = gno[key][0]
        out_lines.append("\t".join([key, consequence, cadd, revel, alpha, spliceai, clnsig, stars, af]))

    Path(args.out_joined_tsv).write_text("\n".join(out_lines) + ("\n" if out_lines else ""), encoding="utf-8")

    audit = {
        "sample_id": args.sample_id,
        "node": "STAGE5_JOIN_EVIDENCE",
        "vep_rows": len(vep),
        "clinvar_rows": len(clin),
        "gnomad_rows": len(gno),
        "joined_rows": len(joined_keys),
        "dropped_rows": 0,
        "status": "PASS",
    }
    Path(args.out_audit).write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
