#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import json
from pathlib import Path


def open_text(path: Path):
    if path.suffix == '.gz':
        return gzip.open(path, 'rt', encoding='utf-8')
    return path.open('r', encoding='utf-8')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--vcf', required=True)
    parser.add_argument('--sample-id', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()

    records = []
    with open_text(Path(args.vcf)) as handle:
        for raw in handle:
            if raw.startswith('#'):
                continue
            parts = raw.rstrip().split('\t')
            if len(parts) < 6:
                continue
            chrom, pos, _vid, ref, alt, qual = parts[:6]
            pos_i = int(pos)
            qual_f = 0.0 if qual in ('.', '') else float(qual)
            consequence = 'missense_variant'
            rules = []
            if pos_i % 17 == 0:
                consequence = 'frameshift_variant'
                rules.append('PVS1')
            if qual_f >= 80:
                rules.append('PP3')
            elif qual_f <= 20:
                rules.append('BP4')
            records.append({
                'variant': f'{chrom}:{pos}:{ref}:{alt}',
                'qual': qual_f,
                'synthetic_consequence': consequence,
                'assigned_rules': rules,
            })

    payload = {
        'node': 'translate_vep_to_acmg.py',
        'sample_id': args.sample_id,
        'variant_count': len(records),
        'records': records,
    }
    Path(args.out).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
