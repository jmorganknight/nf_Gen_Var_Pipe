#!/usr/bin/env python3

import argparse
import base64
import gzip
import hashlib
import json
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


def parse_scalar(text: str):
    value = text.strip()
    if value == '':
        return ''
    lowered = value.lower()
    if lowered == 'true':
        return True
    if lowered == 'false':
        return False
    if lowered in {'null', 'none', '~'}:
        return None
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    try:
        if any(char in value for char in ('.', 'e', 'E')):
            return float(value)
        return int(value)
    except ValueError:
        return value


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


def unquote_key(text: str) -> str:
    key = text.strip()
    if (key.startswith('"') and key.endswith('"')) or (key.startswith("'") and key.endswith("'")):
        return key[1:-1]
    return key


def split_key_value(text: str):
    if ':' not in text:
        raise SystemExit(f'STAGE5_SF_FATAL: malformed YAML content: {text}')
    key, remainder = text.split(':', 1)
    return unquote_key(key.strip()), remainder.strip()


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
            raise SystemExit(f'STAGE5_SF_FATAL: invalid YAML indentation near: {current_text}')
        if current_text.startswith('- '):
            raise SystemExit(f'STAGE5_SF_FATAL: unexpected YAML list item inside mapping near: {current_text}')

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
            result[key] = parse_scalar(remainder)
    return result, index


def parse_yaml_list(tokens, index: int, indent: int):
    items = []
    while index < len(tokens):
        current_indent, current_text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            raise SystemExit(f'STAGE5_SF_FATAL: invalid YAML indentation near: {current_text}')
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
            item[first_key] = parse_scalar(first_remainder) if first_remainder != '' else {}
            if index < len(tokens) and tokens[index][0] > indent:
                child_indent = tokens[index][0]
                child, index = parse_yaml_node(tokens, index, child_indent)
                if isinstance(child, dict):
                    item.update(child)
                else:
                    raise SystemExit('STAGE5_SF_FATAL: unsupported nested list under inline mapping item')
            items.append(item)
        else:
            items.append(parse_scalar(item_text))
            if index < len(tokens) and tokens[index][0] > indent:
                raise SystemExit('STAGE5_SF_FATAL: scalar list item cannot have nested children')

    return items, index


def parse_yaml_document(yaml_text: str) -> dict:
    tokens = tokenize_yaml(yaml_text)
    if not tokens:
        return {}
    doc, index = parse_yaml_node(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise SystemExit('STAGE5_SF_FATAL: trailing unparsed YAML content detected')
    if not isinstance(doc, dict):
        raise SystemExit('STAGE5_SF_FATAL: YAML root must be a mapping')
    return doc


def require_path(node, path):
    current = node
    for key in path:
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_SF_FATAL: missing required governance key {dotted}')
        current = current[key]
    return current


def require_mapping(node, path):
    current = require_path(node, path)
    if not isinstance(current, dict):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SF_FATAL: governance key {dotted} must resolve to a mapping')
    return current


def require_string(node, path):
    current = require_path(node, path)
    if not isinstance(current, str) or not current.strip():
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SF_FATAL: governance key {dotted} must be a non-empty string')
    return current.strip()


def require_numeric(node, path):
    current = require_path(node, path)
    if not isinstance(current, (int, float)):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SF_FATAL: governance key {dotted} must be numeric')
    return float(current)


def require_list(node, path):
    current = require_path(node, path)
    if not isinstance(current, list):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SF_FATAL: governance key {dotted} must be a list')
    return current


def resolve_reference_path(raw_path: str, ref_data_root: str):
    if not raw_path:
        raise SystemExit('STAGE5_SF_FATAL: empty reference path')
    path = Path(raw_path)
    if path.is_absolute():
        return path
    if not ref_data_root:
        raise SystemExit('STAGE5_SF_FATAL: ref_data_root is required for relative registry paths')
    root = Path(ref_data_root).resolve()
    candidate = (root / raw_path).resolve(strict=False)
    if not candidate.is_relative_to(root):
        raise SystemExit(f'STAGE5_SF_FATAL: unsafe registry path escapes ref_data_root: {raw_path}')
    if not candidate.exists() or not candidate.is_file():
        raise SystemExit(f'STAGE5_SF_FATAL: registry file not found: {candidate}')
    return candidate


def open_text(path: Path):
    if path.suffix == '.gz':
        return gzip.open(path, 'rt', encoding='utf-8', errors='replace')
    return path.open('r', encoding='utf-8', errors='replace')


def parse_info(text: str) -> dict:
    info = {}
    for token in text.split(';'):
        if not token:
            continue
        if '=' in token:
            key, value = token.split('=', 1)
            info[key] = value
        else:
            info[token] = True
    return info


def parse_gt(raw_value: str):
    if raw_value in {'', '.'}:
        return None
    parts = raw_value.replace('|', '/').split('/')
    alleles = []
    for part in parts:
        token = part.strip()
        if token == '.':
            alleles.append(None)
        else:
            try:
                alleles.append(int(token))
            except ValueError:
                alleles.append(None)
    return tuple(alleles)


def parse_sample_value(format_key: str, raw_value: str):
    if raw_value in {'', '.'}:
        return None
    if format_key == 'GT':
        return parse_gt(raw_value)
    if ',' in raw_value:
        return tuple(piece.strip() if piece.strip() != '.' else None for piece in raw_value.split(','))
    return raw_value


def parse_vcf(vcf_path: Path):
    sample_names = []
    header_found = False
    records = []

    with open_text(vcf_path) as handle:
        for raw_line in handle:
            if raw_line.startswith('##'):
                continue
            if raw_line.startswith('#CHROM'):
                header_found = True
                sample_names = raw_line.rstrip('\n').split('\t')[9:]
                continue
            if raw_line.startswith('#'):
                continue
            if not header_found:
                raise SystemExit('STAGE5_SF_FATAL: malformed VCF header; missing #CHROM line before records')

            fields = raw_line.rstrip('\n').split('\t')
            if len(fields) < 8:
                raise SystemExit(f'STAGE5_SF_FATAL: malformed VCF record with fewer than 8 columns: {raw_line.strip()}')

            chrom, pos, marker_id, ref, alt, qual, _flt, info_text = fields[:8]
            format_keys = fields[8].split(':') if len(fields) > 8 and fields[8] else []
            samples = {}
            for index, sample_name_value in enumerate(sample_names):
                sample_column = fields[9 + index] if 9 + index < len(fields) else ''
                values = sample_column.split(':') if sample_column else []
                sample_payload = {}
                for fmt_index, fmt_key in enumerate(format_keys):
                    raw_value = values[fmt_index] if fmt_index < len(values) else '.'
                    sample_payload[fmt_key] = parse_sample_value(fmt_key, raw_value)
                samples[sample_name_value] = sample_payload

            records.append({
                'contig': chrom,
                'pos': int(pos),
                'id': marker_id,
                'ref': ref,
                'alts': [] if alt in {'', '.'} else alt.split(','),
                'qual': None if qual in {'', '.'} else float(qual),
                'info': parse_info(info_text),
                'samples': samples,
            })

    if not header_found:
        raise SystemExit('STAGE5_SF_FATAL: malformed VCF; missing #CHROM header line')
    if not sample_names:
        raise SystemExit('STAGE5_SF_FATAL: VCF contains no sample columns for SF interpretation')

    return sample_names, records


def select_sample_name(meta: dict, sample_names):
    requested = str(meta.get('sample_id') or '').strip()
    if requested and requested in sample_names:
        return requested
    if len(sample_names) == 1:
        return sample_names[0]
    raise SystemExit(
        'STAGE5_SF_FATAL: unable to determine sample column for SF interpretation; '
        f'meta.sample_id={requested!r} header_samples={sample_names}'
    )


def normalize_variant_tokens(raw_tokens):
    if raw_tokens is None:
        return []
    if isinstance(raw_tokens, (list, tuple, set)):
        items = raw_tokens
    else:
        items = re.split(r'[;,|\s]+', str(raw_tokens))
    normalized = []
    for token in items:
        cleaned = str(token).strip()
        if cleaned:
            normalized.append(cleaned)
    return normalized


def load_acmg_registry(registry_path: Path):
    if not registry_path.exists() or not registry_path.is_file():
        raise SystemExit(f'STAGE5_SF_FATAL: ACMG registry JSON file not found: {registry_path}')

    with registry_path.open('r', encoding='utf-8', errors='replace') as handle:
        data = json.load(handle)

    entries = []
    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict):
        for key in ('genes', 'entries', 'records', 'items', 'registry'):
            value = data.get(key)
            if isinstance(value, list):
                entries.extend(value)
        if not entries and isinstance(data.get('genes'), list):
            entries.extend({'gene': str(gene).strip()} for gene in data['genes'] if str(gene).strip())
        if not entries:
            for key, value in data.items():
                if key in {'schema_name', 'schema', 'version', 'name', 'description', 'metadata'}:
                    continue
                if isinstance(value, dict):
                    entry = dict(value)
                    entry.setdefault('gene', key)
                    entries.append(entry)
    else:
        raise SystemExit('STAGE5_SF_FATAL: ACMG registry JSON must be an object or array')

    gene_rows = {}
    token_index = {}
    for entry in entries:
        if isinstance(entry, str):
            entry = {'gene': entry.strip()}
        if not isinstance(entry, dict):
            raise SystemExit('STAGE5_SF_FATAL: malformed ACMG registry entry')

        gene = str(entry.get('gene') or entry.get('GENE') or entry.get('symbol') or entry.get('SYMBOL') or '').strip()
        if not gene:
            continue

        gene_rows[gene] = entry
        for token in normalize_variant_tokens(entry.get('variant_tokens') or entry.get('variantToken') or entry.get('tokens')):
            token_index[token] = entry
            if token.startswith('chr'):
                token_index[token[3:]] = entry
            else:
                token_index[f'chr{token}'] = entry

    return gene_rows, token_index


def normalize_significance(value: str):
    text = str(value or '').strip().lower()
    if not text:
        return None
    if 'likely pathogenic' in text:
        return 4, 'Likely pathogenic'
    if 'pathogenic' in text:
        return 5, 'Pathogenic'
    if 'likely benign' in text:
        return 2, 'Likely benign'
    if 'benign' in text:
        return 1, 'Benign'
    if 'vus' in text or 'uncertain' in text:
        return 3, 'Uncertain significance'
    return None


def extract_gene_from_info(info: dict):
    for key in ('GENE', 'SYMBOL', 'GENE_SYMBOL', 'GENE_NAME'):
        value = str(info.get(key) or '').strip()
        if value:
            return value
    return ''


def make_variant_token(record: dict):
    alt = record['alts'][0] if record['alts'] else '.'
    chrom = str(record['contig'])
    pos = int(record['pos'])
    ref = record['ref']
    return f'{chrom}:{pos}:{ref}:{alt}'


def infer_classification(record: dict, registry_row: dict | None):
    info = record['info']
    significant = None
    trace = []

    if registry_row:
        registry_significance = registry_row.get('clinical_significance') or registry_row.get('CLINICAL_SIGNIFICANCE') or ''
        significant = normalize_significance(registry_significance)
        if significant:
            trace.append(f'registry={registry_significance}')

    if significant is None:
        for key in ('CLNSIG', 'CLINVAR_SIG', 'SIGNIFICANCE'):
            significant = normalize_significance(str(info.get(key) or ''))
            if significant:
                trace.append(f'{key}={info.get(key)}')
                break

    if significant is not None:
        acmg_class, label = significant
        return acmg_class, label, ';'.join(trace) or 'registry_or_clinvar_significance'

    def read_float(key: str):
        value = info.get(key)
        if value in {None, '', '.'}:
            return None
        try:
            return float(value)
        except ValueError:
            return None

    revel = read_float('REVEL')
    cadd = read_float('CADD')
    spliceai = read_float('SpliceAI')
    alphamissense = read_float('AlphaMissense')

    if any(score is not None and score >= 0.98 for score in (revel, alphamissense)) and (cadd is not None and cadd >= 30.0):
        return 5, 'Pathogenic', f'computational_support=high;REVEL={revel};CADD={cadd};AlphaMissense={alphamissense};SpliceAI={spliceai}'
    if any(score is not None and score >= 0.90 for score in (revel, alphamissense)) or (cadd is not None and cadd >= 25.0) or (spliceai is not None and spliceai >= 0.20):
        return 4, 'Likely pathogenic', f'computational_support=moderate;REVEL={revel};CADD={cadd};AlphaMissense={alphamissense};SpliceAI={spliceai}'
    if any(score is not None and score >= 0.70 for score in (revel, alphamissense)) or (cadd is not None and cadd >= 20.0):
        return 3, 'Uncertain significance', f'computational_support=limited;REVEL={revel};CADD={cadd};AlphaMissense={alphamissense};SpliceAI={spliceai}'
    return 2, 'Likely benign', f'computational_support=weak;REVEL={revel};CADD={cadd};AlphaMissense={alphamissense};SpliceAI={spliceai}'


def main():
    args = parse_args()
    meta_json = args.meta_json
    if args.meta_json_b64 is not None:
        meta_json = base64.b64decode(args.meta_json_b64).decode('utf-8')
    meta = json.loads(meta_json)

    for required in (Path(args.vcf), Path(args.thresholds), Path(args.references)):
        if not required.exists() or not required.is_file():
            raise SystemExit(f'STAGE5_SF_FATAL: missing required input {required}')

    thresholds_doc = parse_yaml_document(load_text(Path(args.thresholds)))
    references_doc = parse_yaml_document(load_text(Path(args.references)))

    sf_thresholds = require_mapping(thresholds_doc, ('clinical', 'sf'))

    minimum_pathogenicity_class = require_numeric(sf_thresholds, ('minimum_pathogenicity_class',))
    if int(minimum_pathogenicity_class) != minimum_pathogenicity_class or not (1 <= int(minimum_pathogenicity_class) <= 5):
        raise SystemExit('STAGE5_SF_FATAL: clinical.sf.minimum_pathogenicity_class must be an integer between 1 and 5')
    minimum_pathogenicity_class = int(minimum_pathogenicity_class)

    protocol_prefix = require_string(sf_thresholds, ('clinical_protocol_link_base',))

    ref_root = str(references_doc.get('ref_data_root') or '').strip()
    registry_raw_path = None
    if 'references' in references_doc and isinstance(references_doc['references'], dict):
        nested = references_doc['references']
        sf_refs = nested.get('sf')
        if isinstance(sf_refs, dict):
            registry_raw_path = str(sf_refs.get('acmg_registry_json') or '').strip()
    if not registry_raw_path and 'sf' in references_doc and isinstance(references_doc['sf'], dict):
        registry_raw_path = str(references_doc['sf'].get('acmg_registry_json') or '').strip()
    if not registry_raw_path:
        raise SystemExit('STAGE5_SF_FATAL: references.sf.acmg_registry_json is required')
    registry_path = resolve_reference_path(registry_raw_path, ref_root)
    gene_rows, token_index = load_acmg_registry(registry_path)
    approved_genes = sorted(gene_rows.keys())
    if not approved_genes:
        raise SystemExit('STAGE5_SF_FATAL: ACMG registry JSON contains no genes')

    sample_names, records = parse_vcf(Path(args.vcf))
    sample_name = select_sample_name(meta, sample_names)

    observed = []
    for record in records:
        if sample_name not in record['samples']:
            raise SystemExit(f"STAGE5_SF_FATAL: sample column '{sample_name}' missing from VCF record")

        sample_data = record['samples'][sample_name]
        gt = sample_data.get('GT')
        if gt is None:
            continue
        dosage = sum(1 for allele in gt if isinstance(allele, int) and allele > 0)
        if dosage == 0:
            continue

        gene = extract_gene_from_info(record['info'])
        registry_row = None
        if gene and gene in gene_rows:
            registry_row = gene_rows[gene]
        token = make_variant_token(record)
        if registry_row is None:
            registry_row = token_index.get(token) or token_index.get(str(record['id']).strip())
            if registry_row and not gene:
                gene = str(registry_row.get('gene') or '').strip()

        if not gene or gene not in approved_genes:
            continue

        acmg_class, label, trace = infer_classification(record, registry_row)
        if acmg_class < minimum_pathogenicity_class:
            continue

        observed.append({
            'gene': gene,
            'variant_id': str(record['id']).strip(),
            'variant_token': token,
            'acmg_class': acmg_class,
            'variant_pathogenicity': label,
            'clinical_protocol_link': f'{protocol_prefix}{gene}',
            'evidence_trace': trace,
        })

    input_count = len(records)
    if input_count == 0:
        reason = 'COMPLETED_NO_INPUT_VARIANTS'
    elif observed:
        reason = 'COMPLETED_SF_ACTIONABLE_RECORD_EMITTED'
    else:
        reason = 'COMPLETED_NO_SF_ELIGIBLE_RECORDS_DETECTED'

    ruleset_version = f"thresholds:{sha256_file(Path(args.thresholds))[:12]}|references:{sha256_file(Path(args.references))[:12]}"
    content_sha256 = hashlib.sha256(
        json.dumps(observed, sort_keys=True, separators=(',', ':')).encode('utf-8')
    ).hexdigest()

    payload = {
        'summary': {
            'status': 'COMPLETED',
            'reason': reason,
            'input_variant_count': input_count,
            'reported_variant_count': len(observed),
            'ruleset_version': ruleset_version,
            'content_sha256': content_sha256,
        },
        'reported_variants': observed,
    }

    Path(args.output).write_text(json.dumps(payload, sort_keys=True), encoding='utf-8')


def parse_args():
    parser = argparse.ArgumentParser(description='Stage 5 ACMG secondary findings clinical interpretation engine')
    meta_group = parser.add_mutually_exclusive_group(required=True)
    meta_group.add_argument('--meta-json')
    meta_group.add_argument('--meta-json-b64')
    parser.add_argument('--vcf', required=True)
    parser.add_argument('--thresholds', required=True)
    parser.add_argument('--references', required=True)
    parser.add_argument('--output', required=True)
    return parser.parse_args()


if __name__ == '__main__':
    main()
