#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import pysam


WEIGHTS = {
    "PVS1_STRONG": 2.5,
    "PVS1_MODERATE": 1.5,
    "PP3": 0.4,
    "BP4": -0.4,
    "BA1": -2.2,
    "BS1": -0.9,
    "PM2": 0.7,
}


def parse_rules(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return data.get("rules", {})


def to_int(text, default=0):
    try:
        return int(text)
    except Exception:
        return default


def clinvar_delta(assertion, stars):
    a = (assertion or "").lower()
    if "pathogenic" in a and "likely" not in a and stars >= 2:
        return 1.1
    if "likely_pathogenic" in a and stars >= 2:
        return 0.7
    if "benign" in a and "likely" not in a and stars >= 2:
        return -1.3
    if "likely_benign" in a and stars >= 2:
        return -0.8
    return 0.0


def key_for_record(rec):
    return f"{rec.contig}:{rec.pos}:{rec.ref}:{','.join(rec.alts or ['.'])}"


def main():
    ap = argparse.ArgumentParser(description="Bayesian scoring and partition for Stage5 germline")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--in-vcf", required=True)
    ap.add_argument("--joined-tsv", required=True)
    ap.add_argument("--comp-rules", required=True)
    ap.add_argument("--loss-rules", required=True)
    ap.add_argument("--freq-rules", required=True)
    ap.add_argument("--out-benign-vcf", required=True)
    ap.add_argument("--out-pathogenic-vcf", required=True)
    ap.add_argument("--out-vus-vcf", required=True)
    ap.add_argument("--out-score-json", required=True)
    ap.add_argument("--out-audit", required=True)
    args = ap.parse_args()

    comp = parse_rules(args.comp_rules)
    loss = parse_rules(args.loss_rules)
    freq = parse_rules(args.freq_rules)

    joined = {}
    for raw in Path(args.joined_tsv).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        key, _cons, _cadd, _revel, _alpha, _splice, cln, stars, _af = raw.split("\t")
        joined[key] = {"clinvar": cln, "stars": to_int(stars)}

    invcf = pysam.VariantFile(args.in_vcf)
    bcf = pysam.VariantFile(args.out_benign_vcf, "wz", header=invcf.header)
    pcf = pysam.VariantFile(args.out_pathogenic_vcf, "wz", header=invcf.header)
    vcf = pysam.VariantFile(args.out_vus_vcf, "wz", header=invcf.header)

    scored = {}
    counts = {"benign": 0, "pathogenic": 0, "vus": 0, "input": 0}

    for rec in invcf:
        counts["input"] += 1
        key = key_for_record(rec)
        evidence = []
        score = 0.0

        for src in (comp.get(key, {}), loss.get(key, {}), freq.get(key, {})):
            for rule in src.get("rules", []):
                if rule in WEIGHTS:
                    score += WEIGHTS[rule]
                    evidence.append({"rule": rule, "delta": WEIGHTS[rule]})

        clin = joined.get(key, {"clinvar": "", "stars": 0})
        cdelta = clinvar_delta(clin["clinvar"], clin["stars"])
        score += cdelta
        if cdelta != 0.0:
            evidence.append({"rule": "CLINVAR", "delta": cdelta})

        if score >= 1.2:
            label = "pathogenic"
            pcf.write(rec)
            counts["pathogenic"] += 1
        elif score <= -0.5:
            label = "benign"
            bcf.write(rec)
            counts["benign"] += 1
        else:
            label = "vus"
            vcf.write(rec)
            counts["vus"] += 1

        scored[key] = {
            "score": round(score, 4),
            "classification": label,
            "clinvar_assertion": clin.get("clinvar", ""),
            "clinvar_stars": clin.get("stars", 0),
            "evidence_trace": evidence,
        }

    bcf.close()
    pcf.close()
    vcf.close()

    pysam.tabix_index(args.out_benign_vcf, preset="vcf", force=True)
    pysam.tabix_index(args.out_pathogenic_vcf, preset="vcf", force=True)
    pysam.tabix_index(args.out_vus_vcf, preset="vcf", force=True)

    Path(args.out_score_json).write_text(
        json.dumps({"sample_id": args.sample_id, "node": "BAYESIAN_PARTITION", "scores": scored}, indent=2) + "\n",
        encoding="utf-8",
    )

    audit = {
        "sample_id": args.sample_id,
        "node": "BAYESIAN_PARTITION",
        "input_rows": counts["input"],
        "benign_rows": counts["benign"],
        "pathogenic_rows": counts["pathogenic"],
        "vus_rows": counts["vus"],
        "status": "PASS" if counts["input"] == (counts["benign"] + counts["pathogenic"] + counts["vus"]) else "FAIL",
    }
    Path(args.out_audit).write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")

    if audit["status"] != "PASS":
        raise SystemExit(
            "STAGE5_ZERO_LOSS_FAILURE: partition mismatch "
            f"input={counts['input']} benign={counts['benign']} pathogenic={counts['pathogenic']} vus={counts['vus']}"
        )


if __name__ == "__main__":
    main()
