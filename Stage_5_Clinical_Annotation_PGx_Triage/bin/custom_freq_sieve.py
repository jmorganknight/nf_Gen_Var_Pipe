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


def parse_info_map(info_text: str) -> dict:
    info = {}
    for item in info_text.split(';'):
        token = item.strip()
        if not token:
            continue
        if '=' in token:
            key, value = token.split('=', 1)
            info[key] = value
        else:
            info[token] = True
    return info


def first_float(values):
    for raw in values:
        if raw is None:
            continue
        text = str(raw).strip()
        if not text or text == '.':
            continue
        for piece in text.split(','):
            piece = piece.strip()
            if not piece or piece == '.':
                continue
            try:
                return float(piece)
            except ValueError:
                continue
    return None


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
            if len(parts) < 8:
                continue
            chrom, pos, _vid, ref, alt, _qual, _flt, info_text = parts[:8]
            info = parse_info_map(info_text)
            popmax_af = first_float([
                info.get('POPMAX_AF'),
                info.get('GNOMAD_POPMAX_AF'),
                info.get('GNOMAD_AF'),
                info.get('AF'),
            ])

            if popmax_af is None:
                rule = 'UNSET'
                source = 'NO_FREQ_DATA'
            elif popmax_af >= ba1_cutoff:
                rule = 'BA1'
                source = 'POPMAX_AF'
            elif popmax_af >= bs1_cutoff:
                rule = 'BS1'
                source = 'POPMAX_AF'
            elif popmax_af <= 0.0001:
                rule = 'PM2'
                source = 'POPMAX_AF'
            else:
                rule = 'UNSET'
                source = 'POPMAX_AF'

            rules.append({
                'variant': f'{chrom}:{pos}:{ref}:{alt}',
                'popmax_af': None if popmax_af is None else round(popmax_af, 6),
                'rule': rule,
                'frequency_source': source,
                'ancestry_label': ancestry,
            })

    payload = {
        'node': 'custom_freq_sieve.py',
        'frequency_rule_engine_version': 'stage5-frequency-evidence-v1',
        'sample_id': args.sample_id,
        'ancestry_label': ancestry,
        'rules': rules,
    }
    Path(args.out).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
