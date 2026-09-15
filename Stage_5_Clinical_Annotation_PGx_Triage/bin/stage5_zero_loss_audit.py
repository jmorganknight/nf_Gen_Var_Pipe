#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def read_count(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return int(data.get("input_rows", 0)), int(data.get("benign_rows", 0)), int(data.get("pathogenic_rows", 0)), int(data.get("vus_rows", 0))


def main():
    ap = argparse.ArgumentParser(description="Zero-loss gate for Stage5 partition")
    ap.add_argument("--sample-id", required=True)
    ap.add_argument("--partition-audit", required=True)
    ap.add_argument("--out-audit", required=True)
    args = ap.parse_args()

    inp, benign, patho, vus = read_count(args.partition_audit)
    dropped = inp - (benign + patho + vus)

    payload = {
        "sample_id": args.sample_id,
        "node": "GERMLINE_ZERO_LOSS_GATE",
        "input_rows": inp,
        "benign_rows": benign,
        "pathogenic_rows": patho,
        "vus_rows": vus,
        "dropped_rows": dropped,
        "status": "PASS" if dropped == 0 else "FAIL",
    }
    Path(args.out_audit).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    if dropped != 0:
        raise SystemExit(
            f"STAGE5_ZERO_LOSS_FAILURE: dropped_rows={dropped} input={inp} benign={benign} pathogenic={patho} vus={vus}"
        )


if __name__ == "__main__":
    main()
