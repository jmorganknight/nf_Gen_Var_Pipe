#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import pysam


def info_str(value):
    if value is None:
        return ""
    if isinstance(value, (tuple, list)):
        return ",".join(str(v) for v in value)
    return str(value)


def first_float(value):
    if value is None:
        return ""
    if isinstance(value, (tuple, list)) and value:
        value = value[0]
    try:
        return f"{float(value):.6g}"
    except Exception:
        return ""


def main():
    ap = argparse.ArgumentParser(description="Extract Stage5 evidence stream TSV from VCF")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--stream", required=True, choices=["vep", "clinvar", "gnomad"])
    ap.add_argument("--in-vcf", required=True)
    ap.add_argument("--out-tsv", required=True)
    ap.add_argument("--out-audit", required=True)
    args = ap.parse_args()

    in_vcf = Path(args.in_vcf)
    if not in_vcf.exists():
        raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: missing VCF {in_vcf}")

    records = 0
    out_lines = []

    vf = pysam.VariantFile(str(in_vcf))
    for rec in vf:
        records += 1
        key = f"{rec.contig}:{rec.pos}:{rec.ref}:{','.join(rec.alts or ['.'])}"
        info = rec.info
        if args.stream == "vep":
            consequence = info_str(info.get("CSQ") or info.get("Consequence"))
            cadd = first_float(info.get("CADD") or info.get("CADD_PHRED"))
            revel = first_float(info.get("REVEL"))
            alpha = first_float(info.get("ALPHAMISSENSE") or info.get("ALPHA_MISSENSE"))
            spliceai = first_float(info.get("SPLICEAI"))
            out_lines.append("\t".join([key, consequence, cadd, revel, alpha, spliceai]))
        elif args.stream == "clinvar":
            clnsig = info_str(info.get("CLNSIG") or info.get("CLINVAR_SIG"))
            revstat = info_str(info.get("CLNREVSTAT") or info.get("CLINVAR_REVIEW_STATUS"))
            stars = 0
            rs = revstat.lower()
            if "practice_guideline" in rs:
                stars = 4
            elif "expert_panel" in rs:
                stars = 3
            elif "multiple_submitters" in rs:
                stars = 2
            elif "single_submitter" in rs:
                stars = 1
            out_lines.append("\t".join([key, clnsig, str(stars)]))
        else:
            af = first_float(info.get("POPMAX_AF") or info.get("GNOMAD_AF") or info.get("AF"))
            out_lines.append("\t".join([key, af]))

    out_tsv = Path(args.out_tsv)
    out_tsv.write_text("\n".join(out_lines) + ("\n" if out_lines else ""), encoding="utf-8")

    audit = {
        "sample_id": args.sample_id,
        "node": f"STAGE5_{args.stream.upper()}_STREAM",
        "stream": args.stream,
        "input_vcf": str(in_vcf.resolve()),
        "input_rows": records,
        "output_rows": len(out_lines),
        "status": "PASS" if records == len(out_lines) else "FAIL",
    }
    Path(args.out_audit).write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")

    if records != len(out_lines):
        raise SystemExit(
            f"STAGE5_ZERO_LOSS_FAILURE: stream {args.stream} rows mismatch input={records} output={len(out_lines)}"
        )


if __name__ == "__main__":
    main()
