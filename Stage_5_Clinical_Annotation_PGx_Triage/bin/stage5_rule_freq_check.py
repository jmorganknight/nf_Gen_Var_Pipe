#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def to_float(text):
    try:
        return float(text)
    except Exception:
        return None


def load_hotspot_keys(path_text):
    if not path_text:
        return set()
    p = Path(path_text)
    if not p.exists():
        return set()
    keys = set()
    for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        keys.add(line.split("\t")[0])
    return keys


def main():
    ap = argparse.ArgumentParser(description="ACMG population frequency sieve")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--joined-tsv", required=True)
    ap.add_argument("--hotspot-registry", default="")
    ap.add_argument("--out-json", required=True)
    args = ap.parse_args()

    hotspot = load_hotspot_keys(args.hotspot_registry)
    payload = {"sample_id": args.sample_id, "node": "RULE_FREQ_CHECK", "rules": {}}

    for raw in Path(args.joined_tsv).read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            continue
        key, _cons, _cadd, _revel, _alpha, _splice, _cln, _stars, af_s = raw.split("\t")
        af = to_float(af_s)

        rules = []
        if key in hotspot:
            rules.append("HOTSPOT_EXCEPTION_BYPASS")
        elif af is None:
            rules.append("NO_EVIDENCE")
        elif af >= 0.05:
            rules.append("BA1")
        elif af >= 0.01:
            rules.append("BS1")
        elif af <= 0.0001:
            rules.append("PM2")
        else:
            rules.append("NO_EVIDENCE")

        payload["rules"][key] = {"rules": rules, "af": af}

    Path(args.out_json).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
