#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def to_float(text):
    try:
        return float(text)
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description="ACMG computational predictor synthesis")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--joined-tsv", required=True)
    ap.add_argument("--out-json", required=True)
    args = ap.parse_args()

    payload = {"sample_id": args.sample_id, "node": "RULE_COMP_SYNTHESIS", "rules": {}}

    for raw in Path(args.joined_tsv).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        key, _cons, cadd_s, revel_s, alpha_s, splice_s, _cln, _stars, _af = raw.split("\t")
        scores = {
            "cadd": to_float(cadd_s),
            "revel": to_float(revel_s),
            "alphamissense": to_float(alpha_s),
            "spliceai": to_float(splice_s),
        }
        deleterious_votes = 0
        benign_votes = 0

        if scores["cadd"] is not None:
            deleterious_votes += 1 if scores["cadd"] >= 25 else 0
            benign_votes += 1 if scores["cadd"] < 15 else 0
        if scores["revel"] is not None:
            deleterious_votes += 1 if scores["revel"] >= 0.7 else 0
            benign_votes += 1 if scores["revel"] < 0.4 else 0
        if scores["alphamissense"] is not None:
            deleterious_votes += 1 if scores["alphamissense"] >= 0.7 else 0
            benign_votes += 1 if scores["alphamissense"] < 0.4 else 0
        if scores["spliceai"] is not None:
            deleterious_votes += 1 if scores["spliceai"] >= 0.5 else 0
            benign_votes += 1 if scores["spliceai"] < 0.2 else 0

        rules = []
        if deleterious_votes >= 3:
            rules.append("PP3")
        elif benign_votes >= 3:
            rules.append("BP4")
        else:
            rules.append("NO_EVIDENCE")

        payload["rules"][key] = {"rules": rules, "scores": scores}

    Path(args.out_json).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
