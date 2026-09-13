#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import shutil
import sys
import tarfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    yaml = None


JSON_EXTS = {'.json'}
TABLE_EXTS = {'.tsv', '.txt', '.csv'}
YAML_EXTS = {'.yaml', '.yml'}
STRUCTURED_EXTS = JSON_EXTS | TABLE_EXTS | YAML_EXTS


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def load_text(path: Path) -> str:
    if path.suffix == '.gz':
        with gzip.open(path, 'rt', encoding='utf-8') as handle:
            return handle.read()
    return path.read_text(encoding='utf-8')


def load_structured_document(path: Path) -> Any:
    text = load_text(path)
    suffix = path.suffix.lower()
    if suffix == '.gz':
        suffix = path.with_suffix('').suffix.lower()
    if suffix in JSON_EXTS:
        return json.loads(text)
    if suffix in YAML_EXTS:
        if yaml is None:
            raise RuntimeError(f'PyYAML is required to parse {path}')
        return yaml.safe_load(text)
    if suffix in TABLE_EXTS:
        delimiter = '\t' if suffix == '.tsv' or '\t' in (text.splitlines()[0] if text.splitlines() else '') else ','
        rows = []
        reader = csv.DictReader(text.splitlines(), delimiter=delimiter)
        for row in reader:
            rows.append(row)
        return rows
    raise RuntimeError(f'Unsupported structured document: {path}')


def iter_reference_files(path: Path) -> Iterable[Path]:
    if path.is_file():
        yield path
        return
    for item in sorted(path.rglob('*')):
        if item.is_file() and (item.suffix.lower() in STRUCTURED_EXTS or item.suffix.lower() == '.gz'):
            yield item


def flatten_entries(obj: Any) -> List[Dict[str, Any]]:
    if obj is None:
        return []
    if isinstance(obj, list):
        out: List[Dict[str, Any]] = []
        for item in obj:
            out.extend(flatten_entries(item))
        return out
    if isinstance(obj, dict):
        # Common wrapper patterns: {genes: [...]}, {records: [...]}, {pgx: {...}}
        for key in ('records', 'rows', 'entries', 'alleles', 'genes'):
            if key in obj and isinstance(obj[key], list):
                return flatten_entries(obj[key])
        return [obj]
    return []


def normalize_record(record: Dict[str, Any]) -> Dict[str, Any]:
    out = {str(k).strip().lower(): v for k, v in record.items()}
    return out


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
    if text.startswith('[') and text.endswith(']'):
        try:
            return split_tokens(json.loads(text))
        except Exception:
            pass
    parts = []
    for chunk in text.replace('|', ';').replace(',', ';').split(';'):
        token = chunk.strip().strip('"').strip("'")
        if token:
            parts.append(token)
    return parts


def as_float(value: Any) -> Optional[float]:
    if value is None or value == '':
        return None
    try:
        return float(value)
    except Exception:
        return None


def normalize_chrom(chrom: str) -> str:
    chrom = str(chrom).strip()
    return chrom[3:] if chrom.lower().startswith('chr') else chrom


def variant_tokens(chrom: str, pos: int, ref: str, alt: str, vid: Optional[str] = None) -> List[str]:
    tokens = {
        f'{normalize_chrom(chrom)}:{pos}:{ref}:{alt}',
        f'chr{normalize_chrom(chrom)}:{pos}:{ref}:{alt}',
        f'{normalize_chrom(chrom)}:{pos}:{ref}>{alt}',
        f'chr{normalize_chrom(chrom)}:{pos}:{ref}>{alt}',
    }
    if vid and vid not in {'.', ''}:
        tokens.add(str(vid).strip())
        if str(vid).startswith('rs'):
            tokens.add(str(vid).lower())
    return sorted(tokens)


def parse_vcf(vcf_path: Path) -> List[Dict[str, Any]]:
    opener = gzip.open if vcf_path.suffix == '.gz' else open
    variants: List[Dict[str, Any]] = []
    sample_name: Optional[str] = None
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
            chrom, pos_s, vid, ref, alt_s, qual, flt, info, fmt, sample_data = parts[:10]
            try:
                pos = int(pos_s)
            except Exception:
                continue
            alts = alt_s.split(',')
            fmt_keys = fmt.split(':')
            sample_vals = sample_data.split(':')
            fmt_map = {k: sample_vals[i] if i < len(sample_vals) else '' for i, k in enumerate(fmt_keys)}
            gt = fmt_map.get('GT', '')
            ps = fmt_map.get('PS') or fmt_map.get('PID') or ''
            phased = '|' in gt
            allele_codes = gt.replace('|', '/').split('/') if gt else []
            tokens = []
            for alt in alts:
                tokens.extend(variant_tokens(chrom, pos, ref, alt, vid))
            variant = {
                'sample_name': sample_name,
                'chrom': chrom,
                'pos': pos,
                'id': vid,
                'ref': ref,
                'alts': alts,
                'qual': qual,
                'filter': flt,
                'info': info,
                'format': fmt_map,
                'gt': gt,
                'phased': phased,
                'phase_set': ps,
                'tokens': tokens,
            }
            hap_tokens = {1: set(), 2: set()}
            if phased and len(allele_codes) == 2:
                for idx, allele in enumerate(allele_codes, start=1):
                    if allele in {'1', '2', '3', '4', '5', '6', '7', '8', '9'}:
                        alt_idx = int(allele) - 1
                        if 0 <= alt_idx < len(alts):
                            hap_tokens[idx].update(variant_tokens(chrom, pos, ref, alts[alt_idx], vid))
            elif len(allele_codes) == 2 and allele_codes[0] == allele_codes[1] and allele_codes[0] in {'1', '2', '3', '4', '5', '6', '7', '8', '9'}:
                alt_idx = int(allele_codes[0]) - 1
                if 0 <= alt_idx < len(alts):
                    toks = set(variant_tokens(chrom, pos, ref, alts[alt_idx], vid))
                    hap_tokens[1].update(toks)
                    hap_tokens[2].update(toks)
            variant['hap_tokens'] = hap_tokens
            variants.append(variant)
    return variants


def load_bed_intervals(path_text: Optional[str]) -> Dict[str, List[Tuple[int, int]]]:
    intervals: Dict[str, List[Tuple[int, int]]] = defaultdict(list)
    if not path_text:
        return intervals
    path = Path(path_text)
    if not path.exists():
        return intervals
    with open(path, 'r', encoding='utf-8') as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 3:
                continue
            chrom = normalize_chrom(parts[0])
            try:
                start = int(parts[1])
                end = int(parts[2])
            except Exception:
                continue
            intervals[chrom].append((start, end))
    return intervals


def in_intervals(intervals: Dict[str, List[Tuple[int, int]]], chrom: str, pos: int) -> bool:
    chrom = normalize_chrom(chrom)
    for start, end in intervals.get(chrom, []):
        if start <= pos - 1 < end:
            return True
    return False


def load_reference_assets(asset_path: Optional[str]) -> List[Dict[str, Any]]:
    if not asset_path:
        return []
    path = Path(asset_path)
    if not path.exists():
        return []
    records: List[Dict[str, Any]] = []
    if path.is_file() and path.suffix.lower() not in STRUCTURED_EXTS and path.suffix.lower() != '.gz':
        return []
    for file_path in iter_reference_files(path):
        try:
            loaded = load_structured_document(file_path)
        except Exception:
            continue
        for rec in flatten_entries(loaded):
            if isinstance(rec, dict):
                n = normalize_record(rec)
                n['__source_file'] = str(file_path)
                records.append(n)
    return records


def record_gene(record: Dict[str, Any]) -> Optional[str]:
    for key in ('gene', 'gene_symbol', 'gene_name', 'symbol'):
        if record.get(key):
            return str(record[key]).strip().upper()
    return None


def record_allele(record: Dict[str, Any]) -> Optional[str]:
    for key in ('allele', 'star_allele', 'haplotype', 'diplotype', 'name'):
        if record.get(key):
            return str(record[key]).strip()
    return None


def record_variants(record: Dict[str, Any]) -> List[str]:
    variants: List[str] = []
    for key in ('required_variants', 'variants', 'defining_variants', 'variant_tokens', 'markers', 'allele_markers', 'haplotype_markers', 'signature'):
        if key in record and record[key] not in (None, ''):
            variants.extend(split_tokens(record[key]))
    # preserve order, de-duplicate
    seen: set[str] = set()
    out: List[str] = []
    for token in variants:
        if token not in seen:
            out.append(token)
            seen.add(token)
    return out


def alleles_by_gene(records: Sequence[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    by_gene: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for rec in records:
        gene = record_gene(rec)
        allele = record_allele(rec)
        if not gene or not allele:
            continue
        normalized = dict(rec)
        normalized['gene'] = gene
        normalized['allele'] = allele
        normalized['required_variants'] = record_variants(rec)
        normalized['activity_score'] = as_float(rec.get('activity_score') or rec.get('score') or rec.get('function_score'))
        normalized['evidence_level'] = str(rec.get('evidence_level') or rec.get('evidence') or rec.get('cpic_level') or rec.get('level') or '').strip()
        normalized['phenotype'] = str(rec.get('phenotype') or rec.get('functional_phenotype') or rec.get('function') or '').strip()
        normalized['guidance'] = rec.get('therapy_guidance') or rec.get('guidance') or rec.get('recommendation') or rec.get('rule')
        normalized['is_reference'] = str(rec.get('is_reference') or rec.get('reference_allele') or '').strip().lower() in {'1', 'true', 'yes', 'y'} or normalized['allele'] in {'*1', '*1/*1'}
        by_gene[gene].append(normalized)
    return by_gene


def rule_sets_by_gene(records: Sequence[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    out: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for rec in records:
        gene = record_gene(rec)
        if not gene:
            continue
        normalized = dict(rec)
        normalized['gene'] = gene
        out[gene].append(normalized)
    return out


def choose_best_allele(hap_tokens: set[str], records: List[Dict[str, Any]], gene: str) -> Optional[Dict[str, Any]]:
    best: Optional[Dict[str, Any]] = None
    best_score: Tuple[int, float, int] = (-1, -1.0, -1)
    for rec in records:
        req = set(rec.get('required_variants') or [])
        if req and not req.issubset(hap_tokens):
            continue
        if not req and not rec.get('is_reference'):
            continue
        score = len(req)
        act = rec.get('activity_score') if rec.get('activity_score') is not None else -1.0
        ref_bonus = 1 if rec.get('is_reference') else 0
        ranked = (score, float(act), ref_bonus)
        if ranked > best_score:
            best_score = ranked
            best = rec
    return best


def phenotype_from_activity(gene: str, activity: Optional[float], explicit: Optional[str] = None) -> str:
    if explicit:
        return explicit
    if activity is None:
        return 'INDETERMINATE'
    if gene in {'CYP2D6', 'CYP2C19'}:
        if activity <= 0.0:
            return 'Poor Metabolizer'
        if activity < 1.0:
            return 'Intermediate Metabolizer'
        if activity <= 2.0:
            return 'Normal Metabolizer'
        return 'Ultrarapid Metabolizer'
    if gene == 'DPYD':
        if activity <= 0.0:
            return 'Poor Metabolizer'
        if activity < 2.0:
            return 'Intermediate Metabolizer'
        return 'Normal Metabolizer'
    return 'INDETERMINATE'


def risk_tier_from_phenotype(gene: str, phenotype: str) -> str:
    p = phenotype.lower()
    if 'poor' in p or 'ultrarapid' in p:
        return 'HIGH'
    if 'intermediate' in p or 'decreased' in p:
        return 'MODERATE'
    if 'normal' in p:
        return 'LOW'
    if 'indeterminate' in p or 'unresolved' in p:
        return 'UNKNOWN'
    return 'UNKNOWN'


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def sha256_tree(path: Path) -> str:
    h = hashlib.sha256()
    for file_path in sorted([p for p in path.rglob('*') if p.is_file()]):
        rel = str(file_path.relative_to(path)).replace(os.sep, '/')
        h.update(rel.encode('utf-8'))
        h.update(b'\0')
        h.update(sha256_file(file_path).encode('utf-8'))
        h.update(b'\0')
    return h.hexdigest()


def asset_token(value: Any) -> Dict[str, Any]:
    if not value:
        return {'path': None, 'sha256': None, 'type': 'missing'}
    path = Path(str(value))
    if not path.exists():
        return {'path': str(path), 'sha256': None, 'type': 'missing'}
    if path.is_dir():
        return {'path': str(path), 'sha256': sha256_tree(path), 'type': 'directory'}
    return {'path': str(path), 'sha256': sha256_file(path), 'type': 'file'}


def read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding='utf-8'))


def write_json(path: Path, payload: Dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def build_reference_manifest(reference_meta: Dict[str, Any]) -> Dict[str, Any]:
    manifest: Dict[str, Any] = {}
    for key, value in reference_meta.items():
        if isinstance(value, dict):
            manifest[key] = build_reference_manifest(value)
        else:
            manifest[key] = asset_token(value)
    return manifest


def resolve_stage4_payload(meta: Dict[str, Any]) -> Dict[str, Any]:
    required = ['sample_id', 'phased_vcf', 'phased_vcf_tbi', 'ancestry_metrics_json', 'phasing_audit_json']
    missing = [k for k in required if k not in meta or meta[k] in (None, '')]
    if missing:
        raise SystemExit(f"STAGE5_PRECONDITION_FAILURE: canonical meta missing fields: {missing}")
    return meta


def load_gene_panel_records(reference_meta: Dict[str, Any]) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    for key in ('cpic_allele_table', 'pharmvar_star_alleles', 'pgx_gene_panel', 'gene_rule_set'):
        value = reference_meta.get(key)
        if not value:
            continue
        records.extend(load_reference_assets(str(value)))
    return records


def resolve_gene_calls(sample_id: str, meta: Dict[str, Any], reference_meta: Dict[str, Any]) -> Dict[str, Any]:
    vcf_path = Path(meta['phased_vcf'])
    variants = parse_vcf(vcf_path)
    mask = load_bed_intervals(reference_meta.get('cyp2d6_mask_bed'))
    safe_regions = load_bed_intervals(reference_meta.get('paralog_safe_regions'))
    allele_records = load_gene_panel_records(reference_meta)
    alleles = alleles_by_gene(allele_records)
    rule_records = load_reference_assets(str(reference_meta.get('gene_rule_set') or ''))
    rules = rule_sets_by_gene(rule_records)

    observed = []
    hap_tokens = {1: set(), 2: set()}
    masked_variants = []
    for var in variants:
        tokens = set(var['tokens'])
        for hap in (1, 2):
            if var['hap_tokens'][hap]:
                hap_tokens[hap].update(var['hap_tokens'][hap])
        observed.append({
            'chrom': var['chrom'],
            'pos': var['pos'],
            'id': var['id'],
            'ref': var['ref'],
            'alts': var['alts'],
            'gt': var['gt'],
            'phased': var['phased'],
            'tokens': sorted(tokens),
        })
        if normalize_chrom(var['chrom']) == '22':
            continue
        if normalize_chrom(var['chrom']) == '19':
            continue
        if normalize_chrom(var['chrom']) == '5':
            continue
        # Paralog-safe filter only for CYP2D6 calls; we filter when the record is used.

    genes = ['CYP2D6', 'CYP2C19', 'DPYD']
    gene_results: Dict[str, Any] = {}
    for gene in genes:
        gene_alleles = alleles.get(gene, [])
        if gene == 'CYP2D6':
            # Filter observed variants against paralog masks and safe regions by position.
            filtered_variants = []
            for var in variants:
                if in_intervals(mask, var['chrom'], var['pos']) and not in_intervals(safe_regions, var['chrom'], var['pos']):
                    masked_variants.append({'chrom': var['chrom'], 'pos': var['pos'], 'id': var['id']})
                    continue
                filtered_variants.append(var)
            variants_for_gene = filtered_variants
            hap_gene_tokens = {1: set(), 2: set()}
            for var in variants_for_gene:
                for hap in (1, 2):
                    hap_gene_tokens[hap].update(var['hap_tokens'][hap])
        else:
            variants_for_gene = variants
            hap_gene_tokens = hap_tokens

        hap_calls = {}
        activity_scores = []
        matched_rules = []
        for hap in (1, 2):
            best = choose_best_allele(hap_gene_tokens[hap], gene_alleles, gene)
            if best:
                activity_scores.append(best.get('activity_score'))
                matched_rules.append(best)
                hap_calls[str(hap)] = {
                    'allele': best['allele'],
                    'matched_variants': sorted(best.get('required_variants') or []),
                    'activity_score': best.get('activity_score'),
                    'evidence_level': best.get('evidence_level') or None,
                    'source': best.get('__source_file'),
                }
            else:
                hap_calls[str(hap)] = {
                    'allele': 'UNRESOLVED',
                    'matched_variants': [],
                    'activity_score': None,
                    'evidence_level': None,
                    'source': None,
                }

        diplotype = f"{hap_calls['1']['allele']}/{hap_calls['2']['allele']}"
        explicit_phenotype = None
        explicit_guidance = None
        explicit_evidence = None
        for rule in rules.get(gene, []):
            rule_tokens = set(split_tokens(rule.get('diplotype') or rule.get('allele') or rule.get('required_variants') or rule.get('variants')))
            if rule_tokens and rule_tokens.issubset({hap_calls['1']['allele'], hap_calls['2']['allele'], diplotype}):
                explicit_phenotype = str(rule.get('phenotype') or rule.get('metabolizer_status') or '').strip() or None
                explicit_guidance = rule.get('guidance') or rule.get('recommendation') or rule.get('therapy_guidance')
                explicit_evidence = str(rule.get('evidence_level') or rule.get('cpic_level') or '').strip() or None
                break

        # Aggregate score only when both alleles provide values.
        numeric_scores = [s for s in activity_scores if isinstance(s, (int, float))]
        total_activity = float(sum(numeric_scores)) if numeric_scores and len(numeric_scores) == len(activity_scores) else None
        phenotype = phenotype_from_activity(gene, total_activity, explicit_phenotype)
        if phenotype == 'INDETERMINATE' and all(hap_calls[h]['allele'] != 'UNRESOLVED' for h in ('1', '2')):
            phenotype = explicit_phenotype or 'INDETERMINATE'
        risk_tier = risk_tier_from_phenotype(gene, phenotype)
        evidence_level = explicit_evidence or max([str(x.get('evidence_level') or '') for x in matched_rules] + ['']) or None

        gene_results[gene] = {
            'gene': gene,
            'haplotypes': hap_calls,
            'diplotype': diplotype,
            'activity_score': total_activity,
            'phenotype': phenotype,
            'therapeutic_risk_tier': risk_tier,
            'evidence_level': evidence_level,
            'matched_variants': observed,
            'masked_variants_removed': masked_variants if gene == 'CYP2D6' else [],
            'call_status': 'PASS' if 'UNRESOLVED' not in diplotype else 'INCOMPLETE',
            'source_tables': sorted({r.get('__source_file') for r in gene_alleles if r.get('__source_file')}),
            'rule_source_tables': sorted({r.get('__source_file') for r in rules.get(gene, []) if r.get('__source_file')}),
        }
        if explicit_guidance:
            gene_results[gene]['guidance'] = explicit_guidance

    overall = 'PASS'
    if any(g['call_status'] != 'PASS' for g in gene_results.values()):
        overall = 'INCOMPLETE'
    if any(g['therapeutic_risk_tier'] == 'HIGH' for g in gene_results.values()):
        overall = 'HIGH'
    elif any(g['therapeutic_risk_tier'] == 'MODERATE' for g in gene_results.values()):
        overall = 'MODERATE'

    return {
        'node': 'PGX_DIPLOTYPE_RESOLVER',
        'sample_id': sample_id,
        'run_id': meta.get('run_id') or meta.get('workflow_run_id') or meta.get('session_id') or sample_id,
        'workflow_version': meta.get('workflow_version'),
        'input_vcf': str(vcf_path),
        'input_tbi': meta['phased_vcf_tbi'],
        'observed_variants': observed,
        'genes': gene_results,
        'overall_call_status': overall,
        'reference_manifest': build_reference_manifest(reference_meta),
        'computed_utc': datetime.now(timezone.utc).isoformat(),
        'source': 'observed_phased_variants_and_reference_lookup_tables',
    }


def compute_rule_overrides(reference_meta: Dict[str, Any]) -> Dict[str, List[Dict[str, Any]]]:
    rule_records = load_reference_assets(str(reference_meta.get('gene_rule_set') or ''))
    return rule_sets_by_gene(rule_records)


def actionability_summary(gene: str, phenotype: str, risk_tier: str, gene_rule_entries: List[Dict[str, Any]]) -> Dict[str, Any]:
    explicit = None
    evidence = None
    for entry in gene_rule_entries:
        ph = str(entry.get('phenotype') or entry.get('metabolizer_status') or '').strip().lower()
        if ph and ph in phenotype.lower():
            explicit = entry.get('guidance') or entry.get('recommendation') or entry.get('therapy_guidance')
            evidence = str(entry.get('evidence_level') or entry.get('cpic_level') or '').strip() or evidence
            break
    guidance = explicit or f'{gene} {phenotype} implies {risk_tier.lower()} therapeutic risk; consult CPIC/PharmGKB guidance.'
    if gene == 'DPYD' and risk_tier in {'HIGH', 'MODERATE'}:
        guidance = explicit or 'DPYD decreased-function evidence suggests elevated fluoropyrimidine toxicity risk; reduce dose or avoid per CPIC guidance.'
    return {
        'guidance': guidance,
        'evidence_level': evidence,
        'therapeutic_risk_tier': risk_tier,
    }


def resolve_actionability(sample_id: str, diplotype: Dict[str, Any], reference_meta: Dict[str, Any]) -> Dict[str, Any]:
    rules = compute_rule_overrides(reference_meta)
    genes: Dict[str, Any] = {}
    for gene, gene_res in diplotype['genes'].items():
        rule_entries = rules.get(gene, [])
        summary = actionability_summary(gene, gene_res['phenotype'], gene_res['therapeutic_risk_tier'], rule_entries)
        source_evidence = [x for x in [gene_res.get('evidence_level'), summary.get('evidence_level')] if x]
        genes[gene] = {
            'gene': gene,
            'diplotype': gene_res['diplotype'],
            'phenotype': gene_res['phenotype'],
            'activity_score': gene_res['activity_score'],
            'therapeutic_risk_tier': gene_res['therapeutic_risk_tier'],
            'evidence_level': summary.get('evidence_level') or gene_res.get('evidence_level'),
            'guidance': summary['guidance'],
            'call_status': gene_res['call_status'],
            'source_rule_files': gene_res.get('rule_source_tables', []),
            'source_tables': gene_res.get('source_tables', []),
            'evidence_chain': source_evidence,
        }
    overall = 'LOW'
    if any(g['therapeutic_risk_tier'] == 'HIGH' for g in genes.values()):
        overall = 'HIGH'
    elif any(g['therapeutic_risk_tier'] == 'MODERATE' for g in genes.values()):
        overall = 'MODERATE'
    unresolved = [g for g, r in genes.items() if r['call_status'] != 'PASS']
    if unresolved and overall == 'LOW':
        overall = 'INDETERMINATE'
    return {
        'node': 'PGX_ACTIONABILITY_ENGINE',
        'sample_id': sample_id,
        'run_id': diplotype.get('run_id'),
        'workflow_version': diplotype.get('workflow_version'),
        'overall_risk_tier': overall,
        'genes': genes,
        'reference_manifest': diplotype.get('reference_manifest', {}),
        'computed_utc': datetime.now(timezone.utc).isoformat(),
        'source': 'diplotype_calls_and_cpic_pharmgkb_rule_sets',
    }


def provenance_payload(sample_id: str, run_meta: Dict[str, Any], reference_meta: Dict[str, Any], artifact_paths: List[Path]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    file_entries = []
    input_checksums: Dict[str, str] = {}
    for path in artifact_paths:
        digest = sha256_file(path)
        input_checksums[path.name] = digest
        file_entries.append({'name': path.name, 'path': str(path), 'sha256': digest, 'bytes': path.stat().st_size})
    reference_manifest = build_reference_manifest(reference_meta)
    provenance = {
        'sample_id': sample_id,
        'run_id': run_meta.get('run_id') or run_meta.get('session_id') or run_meta.get('workflow_run_id') or sample_id,
        'workflow_version': run_meta.get('workflow_version'),
        'workflow_name': run_meta.get('workflow_name'),
        'nextflow_version': run_meta.get('nextflow_version') or os.environ.get('NXF_VER'),
        'profile': run_meta.get('profile'),
        'session_id': run_meta.get('session_id') or os.environ.get('NXF_SESSION_ID'),
        'execution': {
            'hostname': os.environ.get('HOSTNAME'),
            'user': os.environ.get('USER'),
            'pwd': os.environ.get('PWD'),
            'task_id': os.environ.get('NXF_TASK_ID'),
            'process': os.environ.get('NXF_PROCESS_NAME'),
            'container': os.environ.get('NXF_CONTAINER_IMAGE'),
            'command_line': os.environ.get('NXF_ORIGINAL_COMMAND') or os.environ.get('NXF_CMDLINE'),
        },
        'artifacts': file_entries,
        'input_sha256': input_checksums,
        'reference_manifest_tokens': reference_manifest,
        'source': 'observed_files_and_runtime_metadata',
        'generated_utc': datetime.now(timezone.utc).isoformat(),
    }
    return provenance, input_checksums


def main() -> int:
    parser = argparse.ArgumentParser(description='PGx clinical triage helper')
    sub = parser.add_subparsers(dest='command', required=True)

    resolve_p = sub.add_parser('resolve')
    resolve_p.add_argument('--sample-id', required=True)
    resolve_p.add_argument('--vcf', required=True)
    resolve_p.add_argument('--tbi', required=False)
    resolve_p.add_argument('--reference-meta', required=True)
    resolve_p.add_argument('--out', required=True)

    action_p = sub.add_parser('actionability')
    action_p.add_argument('--sample-id', required=True)
    action_p.add_argument('--diplotype-json', required=True)
    action_p.add_argument('--reference-meta', required=True)
    action_p.add_argument('--out', required=True)

    prov_p = sub.add_parser('provenance')
    prov_p.add_argument('--sample-id', required=True)
    prov_p.add_argument('--diplotype-json', required=True)
    prov_p.add_argument('--actionability-json', required=True)
    prov_p.add_argument('--reference-meta', required=True)
    prov_p.add_argument('--run-meta', required=True)
    prov_p.add_argument('--bundle-out', required=True)
    prov_p.add_argument('--provenance-out', required=True)

    args = parser.parse_args()

    if args.command == 'resolve':
        reference_meta = json.loads(args.reference_meta)
        meta = resolve_stage4_payload({
            'sample_id': args.sample_id,
            'phased_vcf': args.vcf,
            'phased_vcf_tbi': args.tbi or '',
            'ancestry_metrics_json': reference_meta.get('ancestry_metrics_json', ''),
            'phasing_audit_json': reference_meta.get('phasing_audit_json', ''),
            'validation_token': reference_meta.get('validation_token', 'VALID_PASS|VARIANTS_HARMONIZED'),
        })
        payload = resolve_gene_calls(args.sample_id, meta, reference_meta)
        write_json(Path(args.out), payload)
        return 0

    if args.command == 'actionability':
        reference_meta = json.loads(args.reference_meta)
        diplotype = read_json(Path(args.diplotype_json))
        payload = resolve_actionability(args.sample_id, diplotype, reference_meta)
        write_json(Path(args.out), payload)
        return 0

    if args.command == 'provenance':
        reference_meta = json.loads(args.reference_meta)
        run_meta = json.loads(args.run_meta)
        diplotype_path = Path(args.diplotype_json)
        actionability_path = Path(args.actionability_json)
        bundle_path = Path(args.bundle_out)
        provenance_path = Path(args.provenance_out)

        provenance, _ = provenance_payload(args.sample_id, run_meta, reference_meta, [diplotype_path, actionability_path])

        staging = bundle_path.with_suffix('')
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True, exist_ok=True)
        shutil.copy2(diplotype_path, staging / diplotype_path.name)
        shutil.copy2(actionability_path, staging / actionability_path.name)
        # provenance JSON is included inside the archive as well.
        provisional_path = staging / provenance_path.name
        write_json(provisional_path, provenance)

        with tarfile.open(bundle_path, 'w:gz') as tar:
            for item in sorted(staging.iterdir()):
                tar.add(item, arcname=item.name)
        provenance['output_sha256'] = {
            'clinical_bundle_tar_gz': sha256_file(bundle_path),
        }
        provenance['bundle_contents'] = sorted([p.name for p in staging.iterdir()])
        write_json(provenance_path, provenance)
        # Rebuild the archive once provenance.json is final so the bundle includes the final provenance.
        with tarfile.open(bundle_path, 'w:gz') as tar:
            for item in sorted(staging.iterdir()):
                if item.name == provenance_path.name:
                    item.write_text(json.dumps(provenance, indent=2, sort_keys=True) + '\n', encoding='utf-8')
                tar.add(item, arcname=item.name)
        provenance['output_sha256']['clinical_bundle_tar_gz'] = sha256_file(bundle_path)
        write_json(provenance_path, provenance)
        return 0

    return 2


if __name__ == '__main__':
    raise SystemExit(main())
