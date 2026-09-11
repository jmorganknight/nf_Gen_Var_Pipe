#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path_text: str):
    return json.loads(Path(path_text).read_text(encoding='utf-8'))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--sample-id', required=True)
    parser.add_argument('--vep-rules', required=True)
    parser.add_argument('--clinvar', required=True)
    parser.add_argument('--freq-rules', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args()

    vep = load_json(args.vep_rules)
    clinvar = load_json(args.clinvar)
    freq = load_json(args.freq_rules)

    clinvar_index = {row['variant']: row for row in clinvar.get('assertions', [])}
    freq_index = {row['variant']: row for row in freq.get('rules', [])}

    tiers = {'Tier I': [], 'Tier II': [], 'Tier III': [], 'Tier IV': []}
    candidate_vus = []

    for record in vep.get('records', []):
        variant = record['variant']
        rules = set(record.get('assigned_rules', []))
        freq_row = freq_index.get(variant, {})
        clinvar_row = clinvar_index.get(variant, {})
        score = 0.0
        if 'PVS1' in rules:
            score += 1.6
        if 'PP3' in rules:
            score += 0.7
        if 'BP4' in rules:
            score -= 0.6
        if freq_row.get('rule') == 'PM2':
            score += 0.4
        if freq_row.get('rule') == 'BS1':
            score -= 0.4
        if freq_row.get('rule') == 'BA1':
            score -= 1.2
        if int(clinvar_row.get('stars', 0) or 0) >= 2:
            score += 0.5

        if score >= 1.8:
            tier = 'Tier I'
        elif score >= 1.0:
            tier = 'Tier II'
        elif score >= 0.0:
            tier = 'Tier III'
        else:
            tier = 'Tier IV'

        out_row = {
            'variant': variant,
            'posterior_score': round(score, 3),
            'tier': tier,
            'vep_rules': sorted(rules),
            'freq_rule': freq_row.get('rule'),
            'clinvar_stars': clinvar_row.get('stars', 0),
            'clinvar_assertion': clinvar_row.get('assertion', 'NONE'),
        }
        tiers[tier].append(out_row)
        if tier == 'Tier III':
            candidate_vus.append(out_row)

    payload = {
        'node': 'acmg_bayesian_classifier.py',
        'sample_id': args.sample_id,
        'tiers': tiers,
        'candidate_vus': candidate_vus,
    }
    Path(args.out).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
