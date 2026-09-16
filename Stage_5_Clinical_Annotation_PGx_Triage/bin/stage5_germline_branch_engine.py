#!/usr/bin/env python3

import argparse
import base64
import gzip
import hashlib
import json
import math
import re
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def load_text(path: Path) -> str:
    return path.read_text(encoding='utf-8', errors='replace')


def scalar_threshold(yaml_text: str, key: str, cast, default):
    for raw_line in yaml_text.splitlines():
        content = raw_line.split('#', 1)[0].strip()
        if not content or not content.startswith(f'{key}:'):
            continue
        raw = content.split(':', 1)[1].strip().strip('"').strip("'")
        if raw == '':
            return default
        try:
            return cast(raw)
        except Exception:
            return default
    return default


def parse_yaml_scalar(raw: str):
    text = raw.strip()
    if text == '':
        return ''
    lowered = text.lower()
    if lowered == 'true':
        return True
    if lowered == 'false':
        return False
    if lowered in {'null', 'none', '~'}:
        return None
    if text.startswith('"') and text.endswith('"') and len(text) >= 2:
        return text[1:-1]
    if text.startswith("'") and text.endswith("'") and len(text) >= 2:
        return text[1:-1]
    try:
        if any(char in text for char in ('.', 'e', 'E')):
            return float(text)
        return int(text)
    except ValueError:
        return text


def strip_comment(line: str) -> str:
    return line.split('#', 1)[0].rstrip()


def tokenize_yaml(yaml_text: str):
    tokens = []
    for raw_line in yaml_text.splitlines():
        line = strip_comment(raw_line)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(' '))
        tokens.append((indent, line.strip()))
    return tokens


def split_key_value(text: str):
    if ':' not in text:
        raise SystemExit(f'STAGE5_GERMLINE_FATAL: malformed YAML line in thresholds file: {text}')
    key, remainder = text.split(':', 1)
    return key.strip(), remainder.strip()


def parse_yaml_node(tokens, index: int, indent: int):
    if index >= len(tokens):
        return {}, index
    current_indent, current_text = tokens[index]
    if current_indent < indent:
        return {}, index
    if current_text.startswith('- '):
        return parse_yaml_list(tokens, index, indent)
    return parse_yaml_map(tokens, index, indent)


def parse_yaml_map(tokens, index: int, indent: int):
    result = {}
    while index < len(tokens):
        current_indent, current_text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            raise SystemExit(f'STAGE5_GERMLINE_FATAL: invalid YAML indentation in thresholds file: {current_text}')
        if current_text.startswith('- '):
            raise SystemExit(f'STAGE5_GERMLINE_FATAL: unexpected YAML list item inside mapping: {current_text}')

        key, remainder = split_key_value(current_text)
        index += 1
        if remainder == '':
            if index < len(tokens) and tokens[index][0] > indent:
                child_indent = tokens[index][0]
                child, index = parse_yaml_node(tokens, index, child_indent)
                result[key] = child
            else:
                result[key] = {}
        else:
            result[key] = parse_yaml_scalar(remainder)
    return result, index


def parse_yaml_list(tokens, index: int, indent: int):
    items = []
    while index < len(tokens):
        current_indent, current_text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            raise SystemExit(f'STAGE5_GERMLINE_FATAL: invalid YAML indentation in thresholds file: {current_text}')
        if not current_text.startswith('- '):
            break

        item_text = current_text[2:].strip()
        index += 1

        if not item_text:
            if index < len(tokens) and tokens[index][0] > indent:
                child_indent = tokens[index][0]
                child, index = parse_yaml_node(tokens, index, child_indent)
                items.append(child)
            else:
                items.append(None)
            continue

        if ':' in item_text:
            item = {}
            first_key, first_remainder = split_key_value(item_text)
            item[first_key] = parse_yaml_scalar(first_remainder) if first_remainder != '' else {}
            if index < len(tokens) and tokens[index][0] > indent:
                child_indent = tokens[index][0]
                child, index = parse_yaml_node(tokens, index, child_indent)
                if isinstance(child, dict):
                    item.update(child)
                else:
                    raise SystemExit('STAGE5_GERMLINE_FATAL: unsupported nested list under inline mapping item')
            items.append(item)
        else:
            items.append(parse_yaml_scalar(item_text))
            if index < len(tokens) and tokens[index][0] > indent:
                raise SystemExit('STAGE5_GERMLINE_FATAL: scalar list item cannot have nested children')

    return items, index


def parse_yaml_mapping(yaml_text: str) -> dict:
    tokens = tokenize_yaml(yaml_text)
    if not tokens:
        return {}
    root, index = parse_yaml_node(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise SystemExit('STAGE5_GERMLINE_FATAL: trailing unparsed YAML content detected')
    if not isinstance(root, dict):
        raise SystemExit('STAGE5_GERMLINE_FATAL: thresholds YAML root must be a mapping')
    return root


def require_mapping_path(mapping: dict, path: tuple[str, ...]):
    current = mapping
    walked = []
    for key in path:
        walked.append(key)
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_GERMLINE_FATAL: missing required governance key {dotted}')
        current = current[key]
    if not isinstance(current, dict):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_GERMLINE_FATAL: governance key {dotted} must resolve to a mapping')
    return current


def require_numeric_path(mapping: dict, path: tuple[str, ...]) -> float:
    current = mapping
    for key in path:
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_GERMLINE_FATAL: missing required governance key {dotted}')
        current = current[key]
    if not isinstance(current, (int, float)):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_GERMLINE_FATAL: governance key {dotted} must be numeric')
    return float(current)


def open_text(path: Path):
    if path.suffix == '.gz':
        return gzip.open(path, 'rt', encoding='utf-8', errors='replace')
    return path.open('r', encoding='utf-8', errors='replace')


def to_float(value):
    if value is None:
        return None
    if isinstance(value, (tuple, list)):
        for piece in value:
            parsed = to_float(piece)
            if parsed is not None:
                return parsed
        return None
    try:
        text = str(value).strip()
        if text in {'', '.'}:
            return None
        return float(text)
    except Exception:
        return None


def normalize_key(text: str) -> str:
    return re.sub(r'[^a-z0-9]+', '', str(text or '').lower())


def first_present(mapping, *keys):
    normalized = {normalize_key(key): key for key in mapping.keys()}
    for key in keys:
        lookup = normalized.get(normalize_key(key))
        if lookup is not None:
            value = mapping.get(lookup)
            if value not in (None, '', '.', ('',), []):
                return value
    return None


def parse_annotation_format(description: str):
    if not description or 'Format:' not in description:
        return []
    return [field.strip() for field in description.split('Format:', 1)[1].strip().split('|')]


def parse_info_value(raw_value: str):
    if raw_value is None:
        return None
    text = str(raw_value).strip()
    if text in {'', '.'}:
        return None
    if ',' in text:
        return tuple(piece.strip() for piece in text.split(','))
    return text


def parse_info_map(info_text: str):
    info = {}
    for item in info_text.split(';'):
        token = item.strip()
        if not token:
            continue
        if '=' in token:
            key, value = token.split('=', 1)
            info[key] = parse_info_value(value)
        else:
            info[token] = True
    return info


def parse_gt(raw_value: str):
    if raw_value in {'', '.'}:
        return None
    tokens = re.split(r'[/|]', raw_value)
    alleles = []
    for token in tokens:
        if token == '.':
            alleles.append(None)
        else:
            try:
                alleles.append(int(token))
            except Exception:
                alleles.append(None)
    return tuple(alleles)


def parse_sample_value(key: str, raw_value: str):
    if raw_value in {'', '.'}:
        return None
    if key == 'GT':
        return parse_gt(raw_value)
    if ',' in raw_value:
        return tuple(piece.strip() if piece.strip() != '.' else None for piece in raw_value.split(','))
    return raw_value


def parse_info_header(line: str):
    prefix = '##INFO=<ID='
    if not line.startswith(prefix):
        return None, None
    remainder = line[len(prefix):]
    info_id = remainder.split(',', 1)[0].strip()
    description = ''
    marker = 'Description="'
    if marker in line:
        description = line.split(marker, 1)[1].rsplit('"', 1)[0]
    return info_id, description


def parse_annotation_entries(record, info_key: str, fields):
    raw_value = record['info'].get(info_key)
    if raw_value is None:
        return []
    values = raw_value if isinstance(raw_value, (tuple, list)) else [raw_value]
    parsed = []
    for raw_entry in values:
        parts = str(raw_entry).split('|')
        entry = {}
        for index, field in enumerate(fields):
            entry[field] = parts[index] if index < len(parts) else ''
        if len(parts) > len(fields):
            for index in range(len(fields), len(parts)):
                entry[f'field_{index}'] = parts[index]
        parsed.append(entry)
    return parsed


def truthy_annotation(value) -> bool:
    return str(value or '').strip().upper() in {'YES', 'Y', 'TRUE', '1'}


def annotation_value(entry, *keys) -> str:
    value = first_present(entry, *keys)
    return str(value or '').strip()


def consequence_terms(entry) -> tuple[str, ...]:
    raw = annotation_value(entry, 'Consequence', 'Annotation')
    if not raw:
        return ()
    terms = []
    for token in raw.replace('&', ',').split(','):
        text = token.strip()
        if text:
            terms.append(text)
    return tuple(terms)


def consequence_rank(entry) -> int:
    severity_order = [
        'transcript_ablation',
        'splice_acceptor_variant',
        'splice_donor_variant',
        'stop_gained',
        'frameshift_variant',
        'stop_lost',
        'start_lost',
        'transcript_amplification',
        'inframe_insertion',
        'inframe_deletion',
        'missense_variant',
        'protein_altering_variant',
        'splice_region_variant',
        'synonymous_variant',
    ]
    rank_map = {term: index for index, term in enumerate(severity_order)}
    default_rank = len(severity_order)
    return min((rank_map.get(term, default_rank) for term in consequence_terms(entry)), default=default_rank)


def select_transcript_annotation(record, annotation_context):
    info_key = annotation_context['info_key']
    fields = annotation_context['fields']
    if not info_key or not fields:
        return None

    entries = parse_annotation_entries(record, info_key, fields)
    if not entries:
        return None

    def score_entry(entry):
        hgvsc = annotation_value(entry, 'HGVSc', 'HGVS.c')
        hgvsp = annotation_value(entry, 'HGVSp', 'HGVS.p')
        return (
            1 if hgvsc and hgvsp else 0,
            1 if truthy_annotation(first_present(entry, 'CANONICAL')) else 0,
            1 if truthy_annotation(first_present(entry, 'PICK')) else 0,
            1 if annotation_value(entry, 'MANE_SELECT', 'MANE') not in {'', '.', 'None'} else 0,
            1 if 'protein_coding' in annotation_value(entry, 'BIOTYPE', 'Transcript_BioType').lower() else 0,
            1 if hgvsc else 0,
            1 if hgvsp else 0,
            1 if annotation_value(entry, 'Consequence', 'Annotation') else 0,
            -consequence_rank(entry),
            annotation_value(entry, 'Feature', 'Feature_ID', 'Transcript', 'Transcript_ID'),
        )

    return max(entries, key=score_entry)


def extract_transcript_fields(record, annotation_context):
    selected = select_transcript_annotation(record, annotation_context)
    if selected is not None:
        consequence = annotation_value(selected, 'Consequence', 'Annotation')
        hgvsc = annotation_value(selected, 'HGVSc', 'HGVS.c')
        hgvsp = annotation_value(selected, 'HGVSp', 'HGVS.p')
        transcript_id = annotation_value(selected, 'Feature', 'Feature_ID', 'Transcript', 'Transcript_ID')
        source = annotation_context['info_key']
        if hgvsc and hgvsp:
            return {
                'consequence': consequence,
                'hgvsc': hgvsc,
                'hgvsp': hgvsp,
                'transcript_id': transcript_id,
                'source': source,
            }

    direct_hgvsc = first_present(record['info'], 'HGVSc', 'HGVS_C', 'TRANSCRIPT_HGVSC')
    direct_hgvsp = first_present(record['info'], 'HGVSp', 'HGVS_P', 'TRANSCRIPT_HGVSP')
    if direct_hgvsc and direct_hgvsp:
        return {
            'consequence': str(first_present(record['info'], 'Consequence', 'VEP_CONSEQUENCE', 'ANN') or '').strip(),
            'hgvsc': str(direct_hgvsc).strip(),
            'hgvsp': str(direct_hgvsp).strip(),
            'transcript_id': str(first_present(record['info'], 'Feature', 'Transcript', 'TRANSCRIPT_ID') or '').strip(),
            'source': 'INFO',
        }

    return None


def clinvar_stars(record) -> int:
    text = str(first_present(record['info'], 'CLNREVSTAT', 'CLINVAR_REVIEW_STATUS') or '').lower()
    if 'practice_guideline' in text:
        return 4
    if 'expert_panel' in text:
        return 3
    if 'multiple_submitters' in text:
        return 2
    if 'single_submitter' in text:
        return 1
    return 0


def genotype_category(gt):
    if not gt:
        return None
    alleles = [allele for allele in gt if allele is not None and allele >= 0]
    if not alleles:
        return None
    alt_alleles = [allele for allele in alleles if allele > 0]
    if not alt_alleles:
        return None
    if len(alt_alleles) == len(alleles):
        return 'hom_alt'
    return 'het'


def sample_field(sample_data, key: str):
    try:
        value = sample_data.get(key)
    except Exception:
        try:
            value = sample_data[key]
        except Exception:
            return None
    return value


def observed_alt_fraction(record, sample_data):
    ad = sample_field(sample_data, 'AD')
    if isinstance(ad, (tuple, list)) and len(ad) >= 2:
        ref_count = to_float(ad[0]) or 0.0
        alt_count = sum((to_float(piece) or 0.0) for piece in ad[1:])
        depth = ref_count + alt_count
        if depth > 0:
            return alt_count / depth

    for key in ('AF', 'VAF'):
        sample_value = to_float(sample_field(sample_data, key))
        if sample_value is not None:
            return sample_value

    for key in ('AF', 'VAF'):
        info_value = to_float(record['info'].get(key))
        if info_value is not None:
            return info_value

    ao = to_float(record['info'].get('AO'))
    ro = to_float(record['info'].get('RO'))
    if ao is not None and ro is not None and (ao + ro) > 0:
        return ao / (ao + ro)

    dp4 = record['info'].get('DP4')
    if isinstance(dp4, (tuple, list)) and len(dp4) == 4:
        ref_forward = to_float(dp4[0]) or 0.0
        ref_reverse = to_float(dp4[1]) or 0.0
        alt_forward = to_float(dp4[2]) or 0.0
        alt_reverse = to_float(dp4[3]) or 0.0
        depth = ref_forward + ref_reverse + alt_forward + alt_reverse
        if depth > 0:
            return (alt_forward + alt_reverse) / depth

    return None


def population_frequency(record):
    for key in ('POPMAX_AF', 'GNOMAD_AF', 'GNOMAD_GENOMES_AF', 'GNOMAD_EXOMES_AF'):
        value = to_float(record['info'].get(key))
        if value is not None:
            return value
    return None


def germline_gate(record, sample_data, gate_thresholds):
    gt = sample_field(sample_data, 'GT')
    category = genotype_category(gt)
    if category is None:
        return False, None, ['NON_GERMLINE_GENOTYPE']

    allele_fraction = observed_alt_fraction(record, sample_data)
    if allele_fraction is None:
        return False, category, ['AF_NOT_AVAILABLE']

    if allele_fraction < 0.0 or allele_fraction > 1.0:
        return False, category, [f'AF_OUT_OF_RANGE:{allele_fraction:.4f}']

    if category == 'het':
        if not (gate_thresholds['allele_fraction_het_low'] <= allele_fraction <= gate_thresholds['allele_fraction_het_high']):
            return False, category, [f'HET_AF_OUTSIDE_RANGE:{allele_fraction:.4f}']
    elif category == 'hom_alt':
        if allele_fraction < gate_thresholds['allele_fraction_hom_alt_low']:
            return False, category, [f'HOM_ALT_AF_BELOW_RANGE:{allele_fraction:.4f}']

    return True, category, []


def predictor_rules(record, thresholds):
    cadd = to_float(first_present(record['info'], 'CADD', 'CADD_PHRED'))
    revel = to_float(first_present(record['info'], 'REVEL'))
    alpha = to_float(first_present(record['info'], 'AlphaMissense', 'ALPHAMISSENSE'))
    spliceai = to_float(first_present(record['info'], 'SpliceAI', 'SPLICEAI'))

    deleterious_votes = 0
    benign_votes = 0

    if cadd is not None:
        if cadd >= thresholds['cadd_pathogenic_floor']:
            deleterious_votes += 1
        elif cadd <= thresholds['cadd_benign_ceiling']:
            benign_votes += 1
    if revel is not None:
        if revel >= thresholds['revel_pathogenic_floor']:
            deleterious_votes += 1
        elif revel <= thresholds['revel_benign_ceiling']:
            benign_votes += 1
    if alpha is not None:
        if alpha >= thresholds['alphamissense_pathogenic_floor']:
            deleterious_votes += 1
        elif alpha <= thresholds['alphamissense_benign_ceiling']:
            benign_votes += 1
    if spliceai is not None:
        if spliceai >= thresholds['spliceai_pathogenic_floor']:
            deleterious_votes += 1
        elif spliceai <= thresholds['spliceai_benign_ceiling']:
            benign_votes += 1

    rules = []
    if deleterious_votes >= 2:
        rules.append('PP3')
    if benign_votes >= 2 and deleterious_votes == 0:
        rules.append('BP4')

    return rules, {
        'cadd': cadd,
        'revel': revel,
        'alphamissense': alpha,
        'spliceai': spliceai,
        'deleterious_votes': deleterious_votes,
        'benign_votes': benign_votes,
    }


def loss_of_function_rules(consequence: str):
    text = (consequence or '').lower()
    rules = []
    if any(term in text for term in ('frameshift_variant', 'stop_gained', 'splice_acceptor_variant', 'splice_donor_variant')):
        rules.append('PVS1_STRONG')
    elif 'start_lost' in text:
        rules.append('PVS1_MODERATE')
    return rules


def frequency_rules(record, thresholds):
    af = population_frequency(record)
    rules = []
    if af is None:
        return rules, None
    if af >= thresholds['gnomad_ba1_cutoff']:
        rules.append('BA1')
    elif af >= thresholds['gnomad_bs1_cutoff']:
        rules.append('BS1')
    elif af <= 0.0001:
        rules.append('PM2')
    return rules, af


def clinvar_rules(record, thresholds):
    assertion = str(first_present(record['info'], 'CLNSIG', 'CLINVAR_SIG') or '').strip()
    stars = clinvar_stars(record)
    rules = []
    weight = 0.0
    if stars >= thresholds['clinvar_star_floor']:
        lowered = assertion.lower()
        if 'pathogenic' in lowered and 'likely' not in lowered:
            rules.append('CLINVAR_PATHOGENIC')
            weight = 1.10
        elif 'likely_pathogenic' in lowered or 'likely pathogenic' in lowered:
            rules.append('CLINVAR_LIKELY_PATHOGENIC')
            weight = 0.70
        elif 'benign' in lowered and 'likely' not in lowered:
            rules.append('CLINVAR_BENIGN')
            weight = -1.30
        elif 'likely_benign' in lowered or 'likely benign' in lowered:
            rules.append('CLINVAR_LIKELY_BENIGN')
            weight = -0.80
    return rules, weight, assertion, stars


def is_strong_pathogenic_code(code: str) -> bool:
    return code in {'PVS1_STRONG', 'CLINVAR_PATHOGENIC'}


def is_strong_benign_code(code: str) -> bool:
    return code in {'BS1', 'CLINVAR_BENIGN'}


def apply_conflict_policy(raw_score: float, pathogenic_codes, benign_codes, conflict_dampening_factor: float):
    pathogenic = set(pathogenic_codes)
    benign = set(benign_codes)
    if 'BA1' in benign and pathogenic:
        return 0.0, 'CONFLICT_BA1_SUPPRESSES_PATHOGENIC'
    if any(is_strong_pathogenic_code(code) for code in pathogenic) and any(is_strong_benign_code(code) for code in benign):
        return 0.0, 'CONFLICT_STRONG_BENIGN_PATHOGENIC_FORCES_VUS'
    if benign and pathogenic:
        return raw_score * conflict_dampening_factor, 'CONFLICT_MIXED_EVIDENCE_DAMPENED'
    return raw_score, None


def posterior_from_score(score: float) -> float:
    bounded = max(-8.0, min(8.0, score))
    return 1.0 / (1.0 + math.exp(-bounded))


def acmg_class_from_posterior(posterior: float) -> int:
    if posterior >= 0.99:
        return 5
    if posterior >= 0.90:
        return 4
    if posterior <= 0.01:
        return 1
    if posterior <= 0.10:
        return 2
    return 3


def load_records(vcf_path: Path):
    annotation_descriptions = {}
    sample_names = []
    header_found = False
    records = []

    with open_text(vcf_path) as handle:
        for raw_line in handle:
            if raw_line.startswith('##INFO=<ID='):
                info_id, description = parse_info_header(raw_line.strip())
                if info_id:
                    annotation_descriptions[info_id] = description
                continue
            if raw_line.startswith('#CHROM'):
                header_found = True
                columns = raw_line.rstrip('\n').split('\t')
                sample_names = columns[9:]
                continue
            if raw_line.startswith('#'):
                continue
            if not header_found:
                raise SystemExit('STAGE5_GERMLINE_FATAL: malformed VCF header; missing #CHROM line before records')

            fields = raw_line.rstrip('\n').split('\t')
            if len(fields) < 8:
                raise SystemExit(f'STAGE5_GERMLINE_FATAL: malformed VCF record with fewer than 8 columns: {raw_line.strip()}')

            chrom, pos, _vid, ref, alt, qual, _flt, info_text = fields[:8]
            format_keys = fields[8].split(':') if len(fields) > 8 and fields[8] else []
            samples = {}
            for index, sample_name_value in enumerate(sample_names):
                sample_column = fields[9 + index] if 9 + index < len(fields) else ''
                values = sample_column.split(':') if sample_column else []
                sample_payload = {}
                for format_index, format_key in enumerate(format_keys):
                    raw_value = values[format_index] if format_index < len(values) else '.'
                    sample_payload[format_key] = parse_sample_value(format_key, raw_value)
                samples[sample_name_value] = sample_payload

            records.append({
                'contig': chrom,
                'pos': int(pos),
                'ref': ref,
                'alts': [] if alt in {'', '.'} else alt.split(','),
                'qual': None if qual in {'', '.'} else float(qual),
                'info': parse_info_map(info_text),
                'samples': samples,
            })

    if not header_found:
        raise SystemExit('STAGE5_GERMLINE_FATAL: malformed VCF; missing #CHROM header line')
    if not sample_names:
        raise SystemExit('STAGE5_GERMLINE_FATAL: VCF contains no sample columns for germline interpretation')

    return annotation_descriptions, sample_names, records


def determine_sample_name(meta, sample_names):
    requested_sample = str(meta.get('sample_id') or '').strip()
    if requested_sample and requested_sample in sample_names:
        return requested_sample
    if len(sample_names) == 1:
        return sample_names[0]
    raise SystemExit(
        'STAGE5_GERMLINE_FATAL: unable to determine sample column for germline interpretation; '
        f'meta.sample_id={requested_sample!r} header_samples={sample_names}'
    )


def run_engine(meta, vcf_path: Path, thresholds_path: Path, references_path: Path):
    for required in (vcf_path, thresholds_path, references_path):
        if not required.exists() or not required.is_file():
            raise SystemExit(f'STAGE5_GERMLINE_FATAL: missing required input {required}')

    thresholds_text = load_text(thresholds_path)
    thresholds_doc = parse_yaml_mapping(thresholds_text)
    clinical_germline = require_mapping_path(thresholds_doc, ('clinical', 'germline'))
    acmg_weights = require_mapping_path(clinical_germline, ('acmg_weights',))
    conflict_dampening_factor = require_numeric_path(clinical_germline, ('conflict_dampening_factor',))

    rule_weights = {
        'PVS1_STRONG': require_numeric_path(acmg_weights, ('PVS1_STRONG',)),
        'PVS1_MODERATE': require_numeric_path(acmg_weights, ('PVS1_MODERATE',)),
        'PP3': require_numeric_path(acmg_weights, ('PP3',)),
        'BP4': require_numeric_path(acmg_weights, ('BP4',)),
        'PM2': require_numeric_path(acmg_weights, ('PM2',)),
        'BS1': require_numeric_path(acmg_weights, ('BS1',)),
        'BA1': require_numeric_path(acmg_weights, ('BA1',)),
    }

    gate_thresholds = {
        'qual_floor': scalar_threshold(thresholds_text, 'germline_qual_floor', float, 10.0),
        'cadd_pathogenic_floor': scalar_threshold(thresholds_text, 'cadd_phred_floor', float, 20.0),
        'revel_pathogenic_floor': scalar_threshold(thresholds_text, 'revel_cutoff', float, 0.75),
        'spliceai_pathogenic_floor': scalar_threshold(thresholds_text, 'spliceai_ds_cutoff', float, 0.20),
        'clinvar_star_floor': scalar_threshold(thresholds_text, 'clinvar_star_floor', int, 2),
        'gnomad_ba1_cutoff': scalar_threshold(thresholds_text, 'gnomad_ba1_cutoff', float, 0.05),
        'gnomad_bs1_cutoff': scalar_threshold(thresholds_text, 'gnomad_bs1_cutoff', float, 0.01),
        'allele_fraction_het_low': 0.20,
        'allele_fraction_het_high': 0.80,
        'allele_fraction_hom_alt_low': 0.85,
        'cadd_benign_ceiling': 15.0,
        'revel_benign_ceiling': 0.30,
        'alphamissense_pathogenic_floor': 0.56,
        'alphamissense_benign_ceiling': 0.34,
        'spliceai_benign_ceiling': 0.10,
    }

    annotation_descriptions, sample_names, records = load_records(vcf_path)
    sample_name = determine_sample_name(meta, sample_names)

    annotation_context = {'info_key': None, 'fields': []}
    for info_key in ('CSQ', 'ANN'):
        if info_key in annotation_descriptions:
            annotation_context = {
                'info_key': info_key,
                'fields': parse_annotation_format(annotation_descriptions[info_key]),
            }
            break

    input_count = 0
    reported_variants = []

    for record in records:
        input_count += 1

        if not record['alts'] or len(record['alts']) != 1:
            raise SystemExit(
                'STAGE5_GERMLINE_FATAL: multiallelic or ALT-missing record reached germline engine despite atomization policy; '
                f"variant={record['contig']}:{record['pos']}:{record['ref']}:{record['alts']}"
            )

        qual_value = 0.0 if record['qual'] is None else float(record['qual'])
        if qual_value < gate_thresholds['qual_floor']:
            continue

        sample_data = record['samples'].get(sample_name)
        if sample_data is None:
            raise SystemExit(f"STAGE5_GERMLINE_FATAL: sample column '{sample_name}' missing from parsed VCF record")

        gate_pass, genotype_label, gate_codes = germline_gate(record, sample_data, gate_thresholds)
        if not gate_pass:
            continue

        transcript = extract_transcript_fields(record, annotation_context)
        if transcript is None:
            continue

        predictor_evidence, predictor_metrics = predictor_rules(record, gate_thresholds)
        lof_evidence = loss_of_function_rules(transcript['consequence'])
        freq_evidence, population_af = frequency_rules(record, gate_thresholds)
        clinvar_evidence, clinvar_weight, clinvar_assertion, clinvar_stars_value = clinvar_rules(record, gate_thresholds)

        evidence_codes = []
        evidence_codes.extend(lof_evidence)
        evidence_codes.extend(predictor_evidence)
        evidence_codes.extend(freq_evidence)
        evidence_codes.extend(clinvar_evidence)

        if not evidence_codes:
            evidence_codes.append('CLINICAL_REVIEW_REQUIRED')

        score = sum(rule_weights.get(code, 0.0) for code in evidence_codes) + clinvar_weight
        pathogenic_codes = [code for code in evidence_codes if rule_weights.get(code, 0.0) > 0 or code.startswith('CLINVAR_PATHOGENIC')]
        benign_codes = [code for code in evidence_codes if rule_weights.get(code, 0.0) < 0 or 'BENIGN' in code]
        adjusted_score, conflict_policy = apply_conflict_policy(score, pathogenic_codes, benign_codes, conflict_dampening_factor)
        if conflict_policy:
            evidence_codes.append(conflict_policy)

        posterior = round(posterior_from_score(adjusted_score), 6)
        acmg_class = acmg_class_from_posterior(posterior)
        if acmg_class < 3:
            continue

        genotype_tuple = sample_field(sample_data, 'GT') or ()
        reported_variants.append({
            'variant': f"{record['contig']}:{record['pos']}:{record['ref']}:{record['alts'][0]}",
            'acmg_class': acmg_class,
            'bayesian_posterior_probability': posterior,
            'evidence_codes': sorted(set(evidence_codes)),
            'transcript_hgvsc': transcript['hgvsc'],
            'transcript_hgvsp': transcript['hgvsp'],
            'transcript_id': transcript['transcript_id'],
            'transcript_source': transcript['source'],
            'consequence': transcript['consequence'],
            'genotype': '/'.join('.' if allele is None else str(allele) for allele in genotype_tuple),
            'germline_genotype_class': genotype_label,
            'observed_alt_fraction': observed_alt_fraction(record, sample_data),
            'population_af': population_af,
            'qual': qual_value,
            'clinvar_assertion': clinvar_assertion,
            'clinvar_stars': clinvar_stars_value,
            'predictor_metrics': predictor_metrics,
            'conflict_policy': conflict_policy or 'NONE',
            'gate_observations': gate_codes,
        })

    reported_variants.sort(
        key=lambda row: (
            -int(row['acmg_class']),
            -float(row['bayesian_posterior_probability']),
            row['variant'],
        )
    )

    if input_count == 0:
        reason = 'COMPLETED_NO_INPUT_VARIANTS'
    elif reported_variants:
        reason = 'COMPLETED_GERMLINE_INTERPRETATION_EMITTED'
    else:
        reason = 'COMPLETED_NO_REPORTABLE_GERMLINE_VARIANTS_DETECTED'

    ruleset_version = f"thresholds:{sha256_file(thresholds_path)[:12]}|references:{sha256_file(references_path)[:12]}"
    content_sha256 = hashlib.sha256(
        json.dumps(reported_variants, sort_keys=True, separators=(',', ':')).encode('utf-8')
    ).hexdigest()

    return {
        'summary': {
            'status': 'COMPLETED',
            'reason': reason,
            'input_variant_count': input_count,
            'reported_variant_count': len(reported_variants),
            'ruleset_version': ruleset_version,
            'content_sha256': content_sha256,
        },
        'reported_variants': reported_variants,
    }


def parse_args():
    parser = argparse.ArgumentParser(description='Stage 5 germline clinical interpretation engine')
    meta_group = parser.add_mutually_exclusive_group(required=True)
    meta_group.add_argument('--meta-json')
    meta_group.add_argument('--meta-json-b64')
    parser.add_argument('--vcf', required=True)
    parser.add_argument('--thresholds', required=True)
    parser.add_argument('--references', required=True)
    parser.add_argument('--output', required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    meta_json = args.meta_json
    if args.meta_json_b64 is not None:
        meta_json = base64.b64decode(args.meta_json_b64).decode('utf-8')
    meta = json.loads(meta_json)
    payload = run_engine(
        meta=meta,
        vcf_path=Path(args.vcf),
        thresholds_path=Path(args.thresholds),
        references_path=Path(args.references),
    )
    Path(args.output).write_text(json.dumps(payload, sort_keys=True), encoding='utf-8')


if __name__ == '__main__':
    main()