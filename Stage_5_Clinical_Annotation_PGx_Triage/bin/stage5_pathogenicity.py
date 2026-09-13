#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import math
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def read_text(path: Path) -> str:
    if path.suffix == '.gz':
        with gzip.open(path, 'rt', encoding='utf-8') as handle:
            return handle.read()
    return path.read_text(encoding='utf-8')


def load_structured(path: Path) -> Any:
    text = read_text(path)
    suffix = path.suffix.lower()
    if suffix == '.gz':
        suffix = path.with_suffix('').suffix.lower()
    if suffix in {'.json'}:
        return json.loads(text)
    if suffix in {'.yaml', '.yml'}:
        if yaml is None:
            raise RuntimeError(f'PyYAML is required to parse {path}')
        return yaml.safe_load(text)
    if suffix in {'.tsv', '.txt', '.csv'}:
        delimiter = '\t' if suffix == '.tsv' or '\t' in (text.splitlines()[0] if text.splitlines() else '') else ','
        return list(csv.DictReader(text.splitlines(), delimiter=delimiter))
    raise RuntimeError(f'Unsupported structured file: {path}')


def flatten_records(obj: Any) -> List[Dict[str, Any]]:
    if obj is None:
        return []
    if isinstance(obj, list):
        out: List[Dict[str, Any]] = []
        for item in obj:
            out.extend(flatten_records(item))
        return out
    if isinstance(obj, dict):
        for key in ('records', 'rows', 'entries', 'variants', 'alleles', 'genes'):
            if key in obj and isinstance(obj[key], list):
                return flatten_records(obj[key])
        return [obj]
    return []


def normalize_gene(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip().upper()
    return text or None


def split_tokens(value: Any) -> List[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    if isinstance(value, dict):
        tokens: List[str] = []
        for v in value.values():
            tokens.extend(split_tokens(v))
        return tokens
    text = str(value).strip()
    if not text:
        return []
    text = text.replace('|', ';').replace(',', ';')
    out = []
    for chunk in text.split(';'):
        token = chunk.strip().strip('"').strip("'")
        if token:
            out.append(token)
    return out


def as_float(value: Any) -> Optional[float]:
    if value in (None, ''):
        return None
    try:
        return float(value)
    except Exception:
        return None


def normalize_chrom(chrom: str) -> str:
    chrom = str(chrom).strip()
    return chrom[3:] if chrom.lower().startswith('chr') else chrom


def variant_tokens(chrom: str, pos: int, ref: str, alt: str, vid: Optional[str]) -> List[str]:
    chrom = normalize_chrom(chrom)
    toks = {
        f'{chrom}:{pos}:{ref}:{alt}',
        f'chr{chrom}:{pos}:{ref}:{alt}',
        f'{chrom}:{pos}:{ref}>{alt}',
        f'chr{chrom}:{pos}:{ref}>{alt}',
    }
    if vid and vid not in {'.', ''}:
        toks.add(str(vid).strip())
        if str(vid).startswith('rs'):
            toks.add(str(vid).lower())
    return sorted(toks)


def parse_vcf(vcf_path: Path) -> List[Dict[str, Any]]:
    opener = gzip.open if vcf_path.suffix == '.gz' else open
    variants = []
    sample_name = None
    with opener(vcf_path, 'rt', encoding='utf-8') as handle:
        for raw in handle:
            if raw.startswith('##'):
                continue
            if raw.startswith('#CHROM'):
                cols = raw.rstrip('\n').split('\t')
                if len(cols) > 9:
                    sample_name = cols[9]
                continue
            line = raw.rstrip('\n')
            if not line:
                continue
            parts = line.split('\t')
            if len(parts) < 10:
                continue
            chrom, pos_s, vid, ref, alts_s, qual, flt, info, fmt, sample_data = parts[:10]
            try:
                pos = int(pos_s)
            except Exception:
                continue
            alts = alts_s.split(',')
            fmt_keys = fmt.split(':')
            fmt_vals = sample_data.split(':')
            fmt_map = {k: fmt_vals[i] if i < len(fmt_vals) else '' for i, k in enumerate(fmt_keys)}
            gt = fmt_map.get('GT', '')
            phased = '|' in gt
            ps = fmt_map.get('PS') or fmt_map.get('PID') or ''
            alleles = gt.replace('|', '/').split('/') if gt else []
            token_bank = []
            hap_tokens = {1: set(), 2: set()}
            for idx, alt in enumerate(alts):
                toks = variant_tokens(chrom, pos, ref, alt, vid)
                token_bank.extend(toks)
                if phased and len(alleles) == 2:
                    if alleles[0] == str(idx + 1):
                        hap_tokens[1].update(toks)
                    if alleles[1] == str(idx + 1):
                        hap_tokens[2].update(toks)
                elif len(alleles) == 2 and alleles[0] == alleles[1] == str(idx + 1):
                    hap_tokens[1].update(toks)
                    hap_tokens[2].update(toks)
            variants.append({
                'sample_name': sample_name,
                'chrom': chrom,
                'pos': pos,
                'id': vid,
                'ref': ref,
                'alts': alts,
                'gt': gt,
                'phase_set': ps,
                'phased': phased,
                'format': fmt_map,
                'tokens': sorted(set(token_bank)),
                'hap_tokens': {1: sorted(hap_tokens[1]), 2: sorted(hap_tokens[2])},
                'raw_info': info,
            })
    return variants


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def reference_token(path: Path) -> Dict[str, Any]:
    return {
        'path': str(path),
        'sha256': file_sha256(path),
        'size': path.stat().st_size,
    }


def optional_path(value: Optional[str]) -> Optional[Path]:
    if not value:
        return None
    p = Path(value)
    return p if p.exists() else None


def load_reference_records(path: Optional[Path]) -> List[Dict[str, Any]]:
    if not path:
        return []
    records: List[Dict[str, Any]] = []
    if path.is_dir():
        files = sorted([p for p in path.rglob('*') if p.is_file()])
    else:
        files = [path]
    for file_path in files:
        try:
            loaded = load_structured(file_path)
        except Exception:
            continue
        for rec in flatten_records(loaded):
            if isinstance(rec, dict):
                normalized = {str(k).strip().lower(): v for k, v in rec.items()}
                normalized['__source_file'] = str(file_path)
                records.append(normalized)
    return records


def gene_from_record(rec: Dict[str, Any]) -> Optional[str]:
    for key in ('gene', 'gene_symbol', 'gene_name', 'symbol'):
        if rec.get(key):
            return normalize_gene(rec[key])
    return None


def allele_from_record(rec: Dict[str, Any]) -> Optional[str]:
    for key in ('allele', 'star_allele', 'haplotype', 'diplotype', 'name'):
        if rec.get(key):
            return str(rec[key]).strip()
    return None


def record_variant_tokens(rec: Dict[str, Any]) -> List[str]:
    for key in ('required_variants', 'variants', 'defining_variants', 'variant_tokens', 'markers', 'allele_markers', 'signature'):
        if key in rec and rec[key] not in (None, ''):
            return split_tokens(rec[key])
    return []


def load_variant_lookup(path: Optional[Path]) -> Dict[str, List[Dict[str, Any]]]:
    lookup: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for rec in load_reference_records(path):
        tokens = record_variant_tokens(rec)
        gene = gene_from_record(rec)
        if not tokens and not gene:
            continue
        score = as_float(rec.get('activity_score') or rec.get('function_score') or rec.get('score'))
        evidence = str(rec.get('evidence_level') or rec.get('cpic_level') or rec.get('evidence') or '').strip()
        phenotype = str(rec.get('phenotype') or rec.get('functional_phenotype') or rec.get('function') or '').strip()
        entry = {
            'gene': gene,
            'allele': allele_from_record(rec),
            'required_variants': tokens,
            'activity_score': score,
            'evidence_level': evidence,
            'phenotype': phenotype,
            'raw': rec,
        }
        if tokens:
            for token in tokens:
                lookup[token].append(entry)
        if gene and rec.get('allele'):
            lookup[f'{gene}:{rec.get("allele")}'.upper()].append(entry)
    return lookup


def score_stream1(variant: Dict[str, Any], lookup: Dict[str, List[Dict[str, Any]]]) -> Tuple[float, Dict[str, Any]]:
    matches = []
    for token in variant['tokens']:
        for rec in lookup.get(token, []):
            row = rec['raw']
            predictors = []
            for key in ('revel', 'alphamissense', 'alpha_missense', 'cadd', 'spliceai', 'splice_ai'):
                if key in row:
                    val = as_float(row.get(key))
                    if val is not None:
                        if key in {'cadd'}:
                            predictors.append(min(1.0, max(0.0, val / 30.0)))
                        elif key in {'spliceai', 'splice_ai'}:
                            predictors.append(min(1.0, max(0.0, val)))
                        else:
                            predictors.append(min(1.0, max(0.0, val)))
            if predictors:
                matches.append(sum(predictors) / len(predictors))
    if not matches:
        # If variant already carries annotations, use them; otherwise neutral.
        info = variant.get('raw_info', '')
        ann_scores = []
        for key in ('REVEL', 'AlphaMissense', 'CADD', 'SpliceAI'):
            m = re.search(rf'{key}=([^;]+)', info)
            if m:
                try:
                    val = float(m.group(1).split(',')[0])
                    if key == 'CADD':
                        ann_scores.append(min(1.0, max(0.0, val / 30.0)))
                    else:
                        ann_scores.append(min(1.0, max(0.0, val)))
                except Exception:
                    pass
        if ann_scores:
            return sum(ann_scores) / len(ann_scores), {'source': 'vcf_info', 'scores': ann_scores}
        return 0.5, {'source': 'neutral', 'scores': []}
    return sum(matches) / len(matches), {'source': 'reference_lookup', 'scores': matches}


def clinvar_score(variant: Dict[str, Any], clinvar_records: List[Dict[str, Any]]) -> Tuple[float, Dict[str, Any]]:
    if not clinvar_records:
        return 0.5, {'source': 'neutral', 'assertions': []}
    scores = []
    assertions = []
    for rec in clinvar_records:
        record_tokens = set(record_variant_tokens(rec))
        if not record_tokens.intersection(set(variant['tokens'])):
            continue
        text = ' '.join(str(rec.get(k, '')) for k in ('clinical_significance', 'significance', 'assertion', 'review_status', 'star_rating', 'conflicting', 'conflict_flag')).lower()
        assertions.append(text)
        if 'pathogenic' in text and 'likely' not in text:
            scores.append(0.96)
        elif 'likely pathogenic' in text:
            scores.append(0.85)
        elif 'benign' in text and 'likely' not in text:
            scores.append(0.08)
        elif 'likely benign' in text:
            scores.append(0.20)
        elif 'conflict' in text:
            scores.append(0.50)
        else:
            scores.append(0.55)
    if not scores:
        return 0.5, {'source': 'no_match', 'assertions': []}
    return sum(scores) / len(scores), {'source': 'clinvar_lookup', 'assertions': assertions}


def gnomad_score(variant: Dict[str, Any], gnomad_records: List[Dict[str, Any]]) -> Tuple[float, Dict[str, Any]]:
    if not gnomad_records:
        return 0.5, {'source': 'neutral', 'popmax': None}
    freqs = []
    details = []
    for rec in gnomad_records:
        tokens = set(record_variant_tokens(rec))
        if not tokens.intersection(set(variant['tokens'])):
            continue
        values = []
        for key in ('popmax_af', 'gnomad_popmax', 'popmax', 'af_popmax', 'allele_frequency'):
            val = as_float(rec.get(key))
            if val is not None:
                values.append(val)
        if values:
            freq = max(values)
            freqs.append(freq)
            details.append(freq)
    if not freqs:
        return 0.5, {'source': 'no_match', 'popmax': None}
    popmax = max(freqs)
    if popmax <= 1e-5:
        score = 0.97
    elif popmax <= 1e-4:
        score = 0.90
    elif popmax <= 1e-3:
        score = 0.72
    elif popmax <= 1e-2:
        score = 0.35
    else:
        score = 0.08
    return score, {'source': 'gnomad_lookup', 'popmax': popmax, 'frequencies': details}


def sigmoid(x: float) -> float:
    try:
        return 1.0 / (1.0 + math.exp(-x))
    except OverflowError:
        return 0.0 if x < 0 else 1.0


def logit(p: float) -> float:
    p = min(max(p, 1e-6), 1 - 1e-6)
    return math.log(p / (1 - p))


def posterior_from_streams(stream1: float, stream2: float, stream3: float, mode: str) -> float:
    if mode == 'somatic':
        weights = (0.45, 0.20, 0.35)
        bias = -0.05
    else:
        weights = (0.40, 0.35, 0.25)
        bias = 0.0
    x = weights[0] * logit(stream1) + weights[1] * logit(stream2) + weights[2] * logit(stream3) + bias
    return sigmoid(x)


def tier_from_posterior(p: float) -> str:
    if p >= 0.90:
        return 'Pathogenic'
    if p >= 0.75:
        return 'Likely Pathogenic'
    if p >= 0.35:
        return 'VUS'
    if p >= 0.15:
        return 'Likely Benign'
    return 'Benign'


def hotspot_flag(variant: Dict[str, Any], pfam_records: List[Dict[str, Any]], alphafold_records: List[Dict[str, Any]]) -> Dict[str, Any]:
    genes = []
    for rec in pfam_records + alphafold_records:
        gene = gene_from_record(rec)
        if gene:
            genes.append(gene)
    if not genes:
        return {'hotspot': False, 'source': 'unavailable'}
    token_text = ' '.join(variant['tokens'])
    gene_hit = None
    for gene in genes:
        if gene in token_text.upper():
            gene_hit = gene
            break
    return {'hotspot': gene_hit is not None, 'gene': gene_hit, 'source': 'reference_lookup' if gene_hit else 'no_match'}


def literature_score(variant: Dict[str, Any], lit_paths: Sequence[Path]) -> Dict[str, Any]:
    hits = []
    for p in lit_paths:
        if not p.exists():
            continue
        try:
            text = read_text(p).lower()
        except Exception:
            continue
        for token in variant['tokens'][:5]:
            if token.lower() in text:
                hits.append({'source': p.name, 'token': token})
                break
    return {'hits': hits, 'count': len(hits)}


def phase_context(variant: Dict[str, Any], variants: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not variant.get('phased'):
        return {'cis_trans': 'unphased'}
    same_ps = [v for v in variants if v.get('phase_set') and v.get('phase_set') == variant.get('phase_set') and v['tokens'] != variant['tokens']]
    return {'cis_trans': 'phase_set_cohort' if same_ps else 'singleton_phase_set', 'co_phased_variant_count': len(same_ps)}


def vus_ranking(variant: Dict[str, Any], posterior: float, lit: Dict[str, Any], hotspot: Dict[str, Any], phase: Dict[str, Any]) -> Dict[str, Any]:
    score = 0.0
    score += max(0.0, 1.0 - abs(posterior - 0.5) * 2.0) * 0.35
    score += min(1.0, lit.get('count', 0) / 3.0) * 0.30
    score += (1.0 if hotspot.get('hotspot') else 0.0) * 0.20
    score += (1.0 if phase.get('cis_trans') == 'phase_set_cohort' else 0.25) * 0.15
    return {
        'rank_score': round(score, 4),
        'literature': lit,
        'hotspot': hotspot,
        'phase_context': phase,
    }


def classify_variants(mode: str, sample_id: str, vcf: Path, ancestry_path: Optional[Path], phasing_path: Optional[Path], refs: Dict[str, Optional[Path]]) -> Dict[str, Any]:
    variants = parse_vcf(vcf)
    lookup = load_variant_lookup(refs.get('revel'))
    # broaden lookup with other predictors and gene-specific tables
    for ref_key in ('alphamissense', 'cadd', 'spliceai', 'clinvar', 'gnomad', 'pgx_gene_panel', 'gene_rule_set', 'pfam_domains', 'alphafold_annotations'):
        for rec in load_reference_records(refs.get(ref_key)):
            tokens = record_variant_tokens(rec)
            if not tokens:
                continue
            entry = {'raw': rec}
            for token in tokens:
                lookup[token].append(entry)
    clinvar_records = load_reference_records(refs.get('clinvar'))
    gnomad_records = load_reference_records(refs.get('gnomad'))
    pfam_records = load_reference_records(refs.get('pfam_domains'))
    alphafold_records = load_reference_records(refs.get('alphafold_annotations'))
    lit_paths = [p for k in ('litvar', 'pmc', 'mastermind') if (p := refs.get(k))]

    classified = []
    vus_candidates = []
    tier_counts = defaultdict(int)
    pathogenic_counts = defaultdict(int)
    unresolved = 0

    for variant in variants:
        s1, s1_meta = score_stream1(variant, lookup)
        s2, s2_meta = clinvar_score(variant, clinvar_records)
        s3, s3_meta = gnomad_score(variant, gnomad_records)
        posterior = posterior_from_streams(s1, s2, s3, mode)
        tier = tier_from_posterior(posterior)
        tier_counts[tier] += 1
        gene = None
        # derive gene from record tokens if available, else leave null
        for rec in clinvar_records + gnomad_records + pfam_records + alphafold_records:
            if set(record_variant_tokens(rec)).intersection(set(variant['tokens'])):
                gene = gene_from_record(rec)
                if gene:
                    break
        if gene:
            pathogenic_counts[gene] += 1
        phase = phase_context(variant, variants)
        lit = literature_score(variant, lit_paths)
        hotspot = hotspot_flag(variant, pfam_records, alphafold_records)
        vus = None
        if tier == 'VUS':
            vus = vus_ranking(variant, posterior, lit, hotspot, phase)
            vus_candidates.append({
                'variant_tokens': variant['tokens'],
                'posterior_probability': round(posterior, 6),
                'rank_score': vus['rank_score'],
                'literature': vus['literature'],
                'hotspot': vus['hotspot'],
                'phase_context': vus['phase_context'],
                'stream_scores': {
                    'vep_ensemble': round(s1, 6),
                    'clinvar_assertions': round(s2, 6),
                    'gnomad_frequency': round(s3, 6),
                },
            })
        classified.append({
            'chrom': variant['chrom'],
            'pos': variant['pos'],
            'id': variant['id'],
            'ref': variant['ref'],
            'alts': variant['alts'],
            'gt': variant['gt'],
            'phased': variant['phased'],
            'phase_set': variant.get('phase_set'),
            'gene': gene,
            'stream_scores': {
                'vep_ensemble': round(s1, 6),
                'clinvar_assertions': round(s2, 6),
                'gnomad_frequency': round(s3, 6),
            },
            'posterior_probability': round(posterior, 6),
            'tier': tier,
            'stream_meta': {
                'vep_ensemble': s1_meta,
                'clinvar_assertions': s2_meta,
                'gnomad_frequency': s3_meta,
            },
            'vus_triage': vus,
        })
        if tier == 'VUS':
            unresolved += 1

    vus_candidates.sort(key=lambda r: (r['rank_score'], r['posterior_probability']), reverse=True)
    overall = 'PASS'
    if any(v['tier'] == 'Pathogenic' for v in classified):
        overall = 'HIGH'
    elif any(v['tier'] == 'Likely Pathogenic' for v in classified):
        overall = 'MODERATE'
    elif unresolved:
        overall = 'VUS_REVIEW'

    return {
        'node': f'{mode.upper()}_TRIAGE_ENGINE',
        'sample_id': sample_id,
        'mode': mode,
        'computed_utc': datetime.now(timezone.utc).isoformat(),
        'input_vcf': str(vcf),
        'input_ancestry_json': str(ancestry_path) if ancestry_path else None,
        'input_phasing_json': str(phasing_path) if phasing_path else None,
        'stream_weights': {'vep_ensemble': 0.40 if mode == 'germline' else 0.45, 'clinvar_assertions': 0.35 if mode == 'germline' else 0.20, 'gnomad_frequency': 0.25 if mode == 'germline' else 0.35},
        'tier_counts': dict(tier_counts),
        'pathogenicity_summary': {
            'overall_signal': overall,
            'variant_count': len(classified),
            'vus_count': unresolved,
            'pathogenic_count': tier_counts.get('Pathogenic', 0),
            'likely_pathogenic_count': tier_counts.get('Likely Pathogenic', 0),
            'likely_benign_count': tier_counts.get('Likely Benign', 0),
            'benign_count': tier_counts.get('Benign', 0),
        },
        'variants': classified,
        'vus_triage': vus_candidates,
        'reference_manifest': {k: reference_token(v) for k, v in refs.items() if v},
        'source': 'observed_phased_variants_and_reference_lookup_tables',
    }


def prs_score(sample_id: str, vcf: Path, refs: Dict[str, Optional[Path]]) -> Dict[str, Any]:
    variants = parse_vcf(vcf)
    weights = load_reference_records(refs.get('pgx_gene_panel')) or load_reference_records(refs.get('gene_rule_set'))
    weight_lookup = load_variant_lookup(refs.get('gene_rule_set'))
    total = 0.0
    contributing = []
    for variant in variants:
        score = 0.0
        for token in variant['tokens']:
            for rec in weight_lookup.get(token, []):
                val = as_float(rec['raw'].get('weight') or rec['raw'].get('prs_weight') or rec['raw'].get('beta') or rec['raw'].get('effect_size'))
                if val is not None:
                    score += val
        if score:
            total += score
            contributing.append({'variant_tokens': variant['tokens'], 'score': round(score, 6)})
    return {
        'node': 'PRS_RISK_SCORE_ENGINE',
        'sample_id': sample_id,
        'computed_utc': datetime.now(timezone.utc).isoformat(),
        'prs_score': round(total, 6),
        'contributing_loci': contributing,
        'reference_manifest': {k: reference_token(v) for k, v in refs.items() if v},
        'source': 'observed_dosage_from_phased_variants_and_reference_weights',
    }


def acmg_sf73(sample_id: str, vcf: Path, refs: Dict[str, Optional[Path]]) -> Dict[str, Any]:
    variants = parse_vcf(vcf)
    sf_records = load_reference_records(refs.get('acmg_schema'))
    gene_list = set()
    for rec in sf_records:
        gene = gene_from_record(rec)
        if gene:
            gene_list.add(gene)
    if not gene_list:
        # fall back to gene panel content if schema is gene-coded
        for rec in load_reference_records(refs.get('pgx_gene_panel')):
            gene = gene_from_record(rec)
            if gene:
                gene_list.add(gene)
    flagged = []
    for variant in variants:
        for rec in sf_records:
            tokens = set(record_variant_tokens(rec))
            if not tokens.intersection(set(variant['tokens'])):
                continue
            gene = gene_from_record(rec)
            if gene and gene_list and gene not in gene_list:
                continue
            flagged.append({
                'gene': gene,
                'variant_tokens': variant['tokens'],
                'assertion': str(rec.get('clinical_significance') or rec.get('assertion') or rec.get('tier') or 'UNSET'),
                'evidence_level': str(rec.get('evidence_level') or rec.get('cpic_level') or 'UNSET'),
            })
    return {
        'node': 'ACMG_SF73_CLASSIFIER',
        'sample_id': sample_id,
        'computed_utc': datetime.now(timezone.utc).isoformat(),
        'sf_gene_count': len(gene_list),
        'flagged_findings': flagged,
        'flagged_count': len(flagged),
        'reference_manifest': {k: reference_token(v) for k, v in refs.items() if v},
        'source': 'observed_phased_variants_and_acmg_schema_lookup',
    }


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def build_refs(args: argparse.Namespace, keys: Sequence[str]) -> Dict[str, Optional[Path]]:
    refs: Dict[str, Optional[Path]] = {}
    for key in keys:
        value = getattr(args, key, None)
        refs[key] = Path(value) if value and Path(value).exists() else None
    return refs


def require_refs(refs: Dict[str, Optional[Path]], keys: Sequence[str]) -> None:
    missing = [k for k in keys if not refs.get(k)]
    if missing:
        raise SystemExit(f"STAGE5_REFERENCE_FAILURE: missing required refs: {missing}")


def main() -> int:
    parser = argparse.ArgumentParser(description='Stage 5 decoupled pathogenicity engine')
    sub = parser.add_subparsers(dest='command', required=True)

    for name in ('germline', 'somatic'):
        p = sub.add_parser(name)
        p.add_argument('--sample-id', required=True)
        p.add_argument('--vcf', required=True)
        p.add_argument('--ancestry-json')
        p.add_argument('--phasing-json')
        p.add_argument('--out', required=True)
        for key in ('revel', 'alphamissense', 'cadd', 'spliceai', 'clinvar', 'gnomad', 'pfam_domains', 'alphafold_annotations', 'litvar', 'pmc', 'mastermind'):
            p.add_argument(f'--{key}')

    p = sub.add_parser('prs')
    p.add_argument('--sample-id', required=True)
    p.add_argument('--vcf', required=True)
    p.add_argument('--out', required=True)
    for key in ('pgx_gene_panel', 'gene_rule_set'):
        p.add_argument(f'--{key}')

    p = sub.add_parser('sf73')
    p.add_argument('--sample-id', required=True)
    p.add_argument('--vcf', required=True)
    p.add_argument('--out', required=True)
    for key in ('acmg_schema', 'clinvar', 'gnomad', 'pgx_gene_panel'):
        p.add_argument(f'--{key}')

    args = parser.parse_args()

    if args.command in ('germline', 'somatic'):
        refs = build_refs(args, ('revel', 'alphamissense', 'cadd', 'spliceai', 'clinvar', 'gnomad', 'pfam_domains', 'alphafold_annotations', 'litvar', 'pmc', 'mastermind'))
        require_refs(refs, ('revel', 'alphamissense', 'cadd', 'spliceai', 'clinvar', 'gnomad'))
        payload = classify_variants(
            mode=args.command,
            sample_id=args.sample_id,
            vcf=Path(args.vcf),
            ancestry_path=Path(args.ancestry_json) if args.ancestry_json else None,
            phasing_path=Path(args.phasing_json) if args.phasing_json else None,
            refs=refs,
        )
        write_json(Path(args.out), payload)
        return 0

    if args.command == 'prs':
        refs = build_refs(args, ('pgx_gene_panel', 'gene_rule_set'))
        require_refs(refs, ('gene_rule_set',))
        payload = prs_score(args.sample_id, Path(args.vcf), refs)
        write_json(Path(args.out), payload)
        return 0

    if args.command == 'sf73':
        refs = build_refs(args, ('acmg_schema', 'clinvar', 'gnomad', 'pgx_gene_panel'))
        require_refs(refs, ('acmg_schema', 'clinvar', 'gnomad'))
        payload = acmg_sf73(args.sample_id, Path(args.vcf), refs)
        write_json(Path(args.out), payload)
        return 0

    return 2


if __name__ == '__main__':
    raise SystemExit(main())
