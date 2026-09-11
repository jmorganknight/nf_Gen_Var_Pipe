#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import json
from pathlib import Path


AF_CUTOFFS = {
    'AFR': (0.05, 0.01),
    'AMR': (0.04, 0.008),
    'EAS': (0.03, 0.006),
    'EUR': (0.02, 0.005),
    'SAS': (0.03, 0.006),
}


def open_text(path: Path):
    if path.suffix == '.gz':
        return gzip.open(path, 'rt', encoding='utf-8')
    return path.open('r', encoding='utf-8')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--vcf', required=True)
    parser.add_argument('--sample-id', required=True)
    parser.add_argument('--ancestry-label', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()

    ancestry = args.ancestry_label.upper()
    ba1_cutoff, bs1_cutoff = AF_CUTOFFS.get(ancestry, AF_CUTOFFS['EUR'])
    rules = []

    with open_text(Path(args.vcf)) as handle:
        for raw in handle:
            if raw.startswith('#'):
                continue
            parts = raw.rstrip().split('\t')
            if len(parts) < 5:
                continue
            chrom, pos, _vid, ref, alt = parts[:5]
            pos_i = int(pos)
            synthetic_af = (pos_i % 97) / 1000.0
            if synthetic_af >= ba1_cutoff:
                rule = 'BA1'
            elif synthetic_af >= bs1_cutoff:
                rule = 'BS1'
            else:
                rule = 'PM2'
            rules.append({
                'variant': f'{chrom}:{pos}:{ref}:{alt}',
                'synthetic_popmax_af': round(synthetic_af, 6),
                'rule': rule,
                'ancestry_label': ancestry,
            })

    payload = {
        'node': 'custom_freq_sieve.py',
        'sample_id': args.sample_id,
        'ancestry_label': ancestry,
        'rules': rules,
    }
    Path(args.out).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
