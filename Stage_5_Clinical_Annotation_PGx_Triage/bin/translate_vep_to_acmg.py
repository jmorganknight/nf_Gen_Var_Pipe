#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import json
from pathlib import Path


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


def first_float(values) -> float | None:
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


def infer_consequence(info: dict) -> str:
    for key in ('CSQ', 'ANN', 'Consequence', 'VEP_CONSEQUENCE'):
        value = info.get(key)
        if value:
            return str(value).split(',')[0]
    return 'unknown_consequence'


def assign_rules(consequence: str, cadd: float | None, revel: float | None, alpha: float | None, spliceai: float | None, qual: float) -> list[str]:
    rules = []

    high_impact_terms = (
        'frameshift_variant',
        'stop_gained',
        'splice_acceptor_variant',
        'splice_donor_variant',
        'start_lost',
    )
    consequence_text = consequence.lower()
    if any(term in consequence_text for term in high_impact_terms):
        rules.append('PVS1')

    deleterious_votes = 0
    benign_votes = 0
    if cadd is not None:
        if cadd >= 20.0:
            deleterious_votes += 1
        elif cadd <= 10.0:
            benign_votes += 1
    if revel is not None:
        if revel >= 0.75:
            deleterious_votes += 1
        elif revel <= 0.30:
            benign_votes += 1
    if alpha is not None:
        if alpha >= 0.56:
            deleterious_votes += 1
        elif alpha <= 0.34:
            benign_votes += 1
    if spliceai is not None:
        if spliceai >= 0.20:
            deleterious_votes += 1
        elif spliceai <= 0.10:
            benign_votes += 1

    if deleterious_votes >= 2:
        rules.append('PP3')
    if benign_votes >= 2 and deleterious_votes == 0:
        rules.append('BP4')

    if qual >= 150 and 'PP3' in rules and 'PVS1' in rules:
        rules.append('PS1')

    return sorted(set(rules))


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
            if len(parts) < 8:
                continue
            chrom, pos, _vid, ref, alt, qual, _flt, info_text = parts[:8]
            qual_f = 0.0 if qual in ('.', '') else float(qual)
            info = parse_info_map(info_text)

            cadd = first_float([info.get('CADD'), info.get('CADD_PHRED')])
            revel = first_float([info.get('REVEL')])
            alpha = first_float([info.get('AlphaMissense'), info.get('ALPHAMISSENSE')])
            spliceai = first_float([info.get('SpliceAI'), info.get('SPLICEAI')])
            consequence = infer_consequence(info)
            rules = assign_rules(consequence, cadd, revel, alpha, spliceai, qual_f)

            records.append({
                'variant': f'{chrom}:{pos}:{ref}:{alt}',
                'qual': qual_f,
                'consequence': consequence,
                'cadd_phred': cadd,
                'revel': revel,
                'alphamissense': alpha,
                'spliceai': spliceai,
                'assigned_rules': rules,
            })

    payload = {
        'node': 'translate_vep_to_acmg.py',
        'rule_engine_version': 'stage5-acmg-evidence-v1',
        'sample_id': args.sample_id,
        'variant_count': len(records),
        'records': records,
    }
    Path(args.out).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
