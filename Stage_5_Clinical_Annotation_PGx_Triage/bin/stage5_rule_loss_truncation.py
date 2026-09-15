#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


LOF_TERMS = (
    "frameshift",
    "stop_gained",
    "splice_acceptor",
    "splice_donor",
    "start_lost",
)


def main():
    ap = argparse.ArgumentParser(description="ACMG truncation mapping with PVS1 decision logic")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--joined-tsv", required=True)
    ap.add_argument("--out-json", required=True)
    args = ap.parse_args()

    payload = {"sample_id": args.sample_id, "node": "RULE_LOSS_TRUNCATION", "rules": {}}

    for raw in Path(args.joined_tsv).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        key, consequence, _cadd, _revel, _alpha, _splice, _cln, _stars, _af = raw.split("\t")
        cons_l = consequence.lower()

        rules = []
        if any(term in cons_l for term in LOF_TERMS):
            if "start_lost" in cons_l:
                rules.append("PVS1_MODERATE")
            else:
                rules.append("PVS1_STRONG")
        else:
            rules.append("NO_EVIDENCE")

        payload["rules"][key] = {"rules": rules, "consequence": consequence}

    Path(args.out_json).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
