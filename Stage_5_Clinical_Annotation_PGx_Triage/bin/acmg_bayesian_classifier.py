#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


RULE_WEIGHTS = {
    'PVS1': 2.50,
    'PS1': 1.20,
    'PM2': 0.70,
    'PP3': 0.40,
    'BP4': -0.40,
    'BS1': -0.90,
    'BA1': -2.20,
}


def clinvar_weight(assertion: str, stars: int) -> float:
    text = (assertion or '').lower()
    if stars < 2:
        return 0.0
    if 'pathogenic' in text and 'likely' not in text:
        return 1.10
    if 'likely_pathogenic' in text or 'likely pathogenic' in text:
        return 0.70
    if 'benign' in text and 'likely' not in text:
        return -1.30
    if 'likely_benign' in text or 'likely benign' in text:
        return -0.80
    return 0.0


def tier_from_score(score: float) -> str:
    if score >= 2.40:
        return 'Tier I'
    if score >= 1.20:
        return 'Tier II'
    if score >= 0.20:
        return 'Tier III'
    return 'Tier IV'


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
        evidence_trace = []
        score = 0.0

        for rule in sorted(rules):
            delta = RULE_WEIGHTS.get(rule, 0.0)
            if delta != 0.0:
                score += delta
                evidence_trace.append({'source': 'acmg_rule', 'rule': rule, 'delta': round(delta, 3)})

        freq_rule = str(freq_row.get('rule') or '').upper()
        if freq_rule in RULE_WEIGHTS:
            delta = RULE_WEIGHTS[freq_rule]
            score += delta
            evidence_trace.append({'source': 'frequency_rule', 'rule': freq_rule, 'delta': round(delta, 3)})

        stars = int(clinvar_row.get('stars', 0) or 0)
        clinvar_assertion = clinvar_row.get('assertion', 'NONE')
        cdelta = clinvar_weight(clinvar_assertion, stars)
        if cdelta != 0.0:
            score += cdelta
            evidence_trace.append({'source': 'clinvar', 'assertion': clinvar_assertion, 'stars': stars, 'delta': round(cdelta, 3)})

        tier = tier_from_score(score)

        out_row = {
            'variant': variant,
            'posterior_score': round(score, 3),
            'tier': tier,
            'vep_rules': sorted(rules),
            'freq_rule': freq_row.get('rule'),
            'clinvar_stars': stars,
            'clinvar_assertion': clinvar_assertion,
            'evidence_trace': evidence_trace,
        }
        tiers[tier].append(out_row)
        if tier == 'Tier III':
            candidate_vus.append(out_row)

    payload = {
        'node': 'acmg_bayesian_classifier.py',
        'classifier_version': 'stage5_bayes_evidence_v1',
        'sample_id': args.sample_id,
        'rule_weights': RULE_WEIGHTS,
        'tiers': tiers,
        'candidate_vus': candidate_vus,
    }
    Path(args.out).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
