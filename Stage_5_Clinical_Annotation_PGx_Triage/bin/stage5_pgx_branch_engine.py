#!/usr/bin/env python3

import argparse
import base64
import gzip
import hashlib
import json
import math
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
    text = line.split('#', 1)[0].rstrip()
    return text


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
        raise SystemExit(f'STAGE5_PGX_FATAL: malformed YAML content: {text}')
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
            raise SystemExit(f'STAGE5_PGX_FATAL: invalid YAML indentation near: {current_text}')
        if current_text.startswith('- '):
            raise SystemExit(f'STAGE5_PGX_FATAL: unexpected YAML list item inside mapping near: {current_text}')

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
            raise SystemExit(f'STAGE5_PGX_FATAL: invalid YAML indentation near: {current_text}')
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
                    raise SystemExit('STAGE5_PGX_FATAL: unsupported nested list under inline mapping item')
            items.append(item)
        else:
            items.append(parse_scalar(item_text))
            if index < len(tokens) and tokens[index][0] > indent:
                raise SystemExit('STAGE5_PGX_FATAL: scalar list item cannot have nested children')

    return items, index


def parse_yaml_document(yaml_text: str) -> dict:
    tokens = tokenize_yaml(yaml_text)
    if not tokens:
        return {}
    doc, index = parse_yaml_node(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise SystemExit('STAGE5_PGX_FATAL: trailing unparsed YAML content detected')
    if not isinstance(doc, dict):
        raise SystemExit('STAGE5_PGX_FATAL: thresholds YAML root must be a mapping')
    return doc


def require_path(node, path):
    current = node
    for key in path:
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_PGX_FATAL: missing required governance key {dotted}')
        current = current[key]
    return current


def require_mapping(node, path):
    current = require_path(node, path)
    if not isinstance(current, dict):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_PGX_FATAL: governance key {dotted} must resolve to a mapping')
    return current


def require_string(node, path):
    current = require_path(node, path)
    if not isinstance(current, str) or not current.strip():
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_PGX_FATAL: governance key {dotted} must be a non-empty string')
    return current.strip()


def require_numeric(node, path):
    current = require_path(node, path)
    if not isinstance(current, (int, float)):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_PGX_FATAL: governance key {dotted} must be numeric')
    return float(current)


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


def genotype_alt_dosage(sample_data: dict) -> int:
    gt = sample_data.get('GT')
    if isinstance(gt, tuple):
        return sum(1 for allele in gt if isinstance(allele, int) and allele > 0)

    ad = sample_data.get('AD')
    if isinstance(ad, (tuple, list)) and len(ad) >= 2:
        try:
            alt_depth = sum(float(piece or 0.0) for piece in ad[1:])
            return 1 if alt_depth > 0 else 0
        except Exception:
            return 0

    af = sample_data.get('AF') or sample_data.get('VAF')
    try:
        if af is not None and float(af) > 0:
            return 1
    except Exception:
        pass

    return 0


def normalize_contig(text: str) -> str:
    value = str(text or '').strip()
    lower = value.lower()
    if lower.startswith('chr'):
        return value[3:]
    return value


def locus_matches(record, locus: dict) -> bool:
    return (
        normalize_contig(record['contig']) == normalize_contig(locus.get('chrom'))
        and int(record['pos']) == int(locus.get('pos'))
        and str(record['ref']) == str(locus.get('ref'))
        and str(record['alts'][0]) == str(locus.get('alt'))
    )


def parse_vcf(vcf_path: Path):
    annotation = {}
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
                raise SystemExit('STAGE5_PGX_FATAL: malformed VCF header; missing #CHROM line before records')

            fields = raw_line.rstrip('\n').split('\t')
            if len(fields) < 8:
                raise SystemExit(f'STAGE5_PGX_FATAL: malformed VCF record with fewer than 8 columns: {raw_line.strip()}')

            chrom, pos, _vid, ref, alt, qual, _flt, info_text = fields[:8]
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
                'ref': ref,
                'alts': [] if alt in {'', '.'} else alt.split(','),
                'qual': None if qual in {'', '.'} else float(qual),
                'info': parse_info(info_text),
                'samples': samples,
            })

    if not header_found:
        raise SystemExit('STAGE5_PGX_FATAL: malformed VCF; missing #CHROM header line')
    if not sample_names:
        raise SystemExit('STAGE5_PGX_FATAL: VCF contains no sample columns for PGx interpretation')

    return sample_names, records


def select_sample_name(meta: dict, sample_names):
    requested = str(meta.get('sample_id') or '').strip()
    if requested and requested in sample_names:
        return requested
    if len(sample_names) == 1:
        return sample_names[0]
    raise SystemExit(
        'STAGE5_PGX_FATAL: unable to determine sample column for PGx interpretation; '
        f'meta.sample_id={requested!r} header_samples={sample_names}'
    )


def allele_function_rank(function_class: str) -> int:
    order = {
        'no_function': 0,
        'decreased_function': 1,
        'normal_function': 2,
        'increased_function': 3,
        'unknown_function': 4,
    }
    return order.get(str(function_class or '').strip().lower(), 4)


def canonical_diplotype(a1: str, a2: str, reference_allele: str) -> str:
    pair = [str(a1), str(a2)]
    ref = str(reference_allele or '*1').strip()
    if pair[0] == pair[1]:
        return f'{pair[0]}/{pair[1]}'
    if ref in pair:
        other = pair[0] if pair[1] == ref else pair[1]
        return f'{ref}/{other}'
    return '/'.join(sorted(pair, key=lambda allele: (allele == ref, allele)))


def call_gene_geneotypes(gene_name: str, gene_config: dict, records, sample_name: str):
    reference_allele = str(gene_config.get('reference_allele') or '*1').strip()
    allele_defs = gene_config.get('allele_definitions') or {}
    if not isinstance(allele_defs, dict) or not allele_defs:
        raise SystemExit(f'STAGE5_PGX_FATAL: star allele definitions missing for gene {gene_name}')

    allele_calls = []
    locus_observed = False
    for allele_name, allele_def in allele_defs.items():
        if not isinstance(allele_def, dict):
            raise SystemExit(f'STAGE5_PGX_FATAL: malformed allele definition for {gene_name} {allele_name}')
        loci = allele_def.get('loci')
        if not isinstance(loci, list) or not loci:
            raise SystemExit(f'STAGE5_PGX_FATAL: loci list missing for allele {gene_name} {allele_name}')

        locus_dosages = []
        for locus in loci:
            if not isinstance(locus, dict):
                raise SystemExit(f'STAGE5_PGX_FATAL: malformed locus entry for allele {gene_name} {allele_name}')
            matching = [record for record in records if locus_matches(record, locus)]
            if not matching:
                locus_dosages.append(0)
                continue
            locus_observed = True
            matching = matching[:1]
            record = matching[0]
            if not record['sample_name'] in record['samples']:
                raise SystemExit(f"STAGE5_PGX_FATAL: sample column '{record['sample_name']}' missing from VCF record")
            dosage = genotype_alt_dosage(record['samples'][record['sample_name']])
            locus_dosages.append(dosage)

        if all(dosage > 0 for dosage in locus_dosages):
            allele_calls.append({
                'allele': allele_name,
                'function_class': str(allele_def.get('function_class') or 'unknown_function'),
                'dosage': min(locus_dosages),
            })

    if not locus_observed:
        return None, reference_allele, []

    if not allele_calls:
        return f'{reference_allele}/{reference_allele}', reference_allele, []

    allele_calls.sort(
        key=lambda item: (
            -int(item['dosage']),
            allele_function_rank(item['function_class']),
            str(item['allele']),
        )
    )

    copies = []
    for call in allele_calls:
        copies.extend([call['allele']] * int(call['dosage']))
        if len(copies) >= 2:
            break

    if len(copies) == 0:
        copies = [reference_allele, reference_allele]
    elif len(copies) == 1:
        copies.append(reference_allele)

    diplotype = canonical_diplotype(copies[0], copies[1], reference_allele)
    return diplotype, reference_allele, allele_calls


def build_pgx_call(meta: dict, thresholds_path: Path, references_path: Path, vcf_path: Path):
    thresholds_text = load_text(thresholds_path)
    doc = parse_yaml_document(thresholds_text)
    clinical = require_mapping(doc, ('clinical',))
    pgx = require_mapping(clinical, ('pgx',))
    star_alleles = require_mapping(pgx, ('star_alleles',))
    phenotype_map = require_mapping(pgx, ('phenotype_map',))
    cpic_guidelines = require_mapping(pgx, ('cpic_guidelines',))

    sample_names, records = parse_vcf(vcf_path)
    sample_name = select_sample_name(meta, sample_names)
    for record in records:
        record['sample_name'] = sample_name

    reported_calls = []
    input_count = len(records)

    for gene_name, gene_config in star_alleles.items():
        if not isinstance(gene_config, dict):
            raise SystemExit(f'STAGE5_PGX_FATAL: malformed star allele config for gene {gene_name}')

        diplotype, reference_allele, allele_calls = call_gene_geneotypes(gene_name, gene_config, records, sample_name)
        if diplotype is None:
            continue

        gene_phenotype_map = phenotype_map.get(gene_name)
        if not isinstance(gene_phenotype_map, dict):
            raise SystemExit(f'STAGE5_PGX_FATAL: phenotype map missing for gene {gene_name}')
        phenotype = gene_phenotype_map.get(diplotype, gene_phenotype_map.get('default'))
        if not isinstance(phenotype, str) or not phenotype.strip():
            raise SystemExit(f'STAGE5_PGX_FATAL: phenotype mapping failed for gene {gene_name} diplotype {diplotype}')
        phenotype = phenotype.strip()

        gene_guidelines = cpic_guidelines.get(gene_name)
        if not isinstance(gene_guidelines, dict):
            raise SystemExit(f'STAGE5_PGX_FATAL: CPIC guidelines missing for gene {gene_name}')
        phenotype_guidance = gene_guidelines.get(phenotype)
        if not isinstance(phenotype_guidance, dict):
            raise SystemExit(f'STAGE5_PGX_FATAL: CPIC guidance missing for gene {gene_name} phenotype {phenotype}')

        tier = str(phenotype_guidance.get('cpic_actionability_tier') or '').strip()
        trace = str(phenotype_guidance.get('recommendation_trace') or '').strip()
        if not tier or not trace:
            raise SystemExit(f'STAGE5_PGX_FATAL: incomplete CPIC guidance for gene {gene_name} phenotype {phenotype}')

        if diplotype == f'{reference_allele}/{reference_allele}':
            if not allele_calls:
                # No actionable allele observed; preserve an explicit normal-call pathway.
                pass

        reported_calls.append({
            'gene': gene_name,
            'diplotype': diplotype,
            'phenotype_status': phenotype,
            'cpic_actionability_tier': tier,
            'recommendation_trace': trace,
        })

    if input_count == 0:
        reason = 'COMPLETED_NO_INPUT_VARIANTS'
    elif reported_calls:
        reason = 'COMPLETED_PGX_CALL_EMITTED'
    else:
        reason = 'COMPLETED_NO_PGX_CALLS_DETECTED'

    ruleset_version = f"thresholds:{sha256_file(thresholds_path)[:12]}|references:{sha256_file(references_path)[:12]}"
    content_sha256 = hashlib.sha256(
        json.dumps(reported_calls, sort_keys=True, separators=(',', ':')).encode('utf-8')
    ).hexdigest()

    payload = {
        'summary': {
            'status': 'COMPLETED',
            'reason': reason,
            'input_variant_count': input_count,
            'reported_variant_count': len(reported_calls),
            'ruleset_version': ruleset_version,
            'content_sha256': content_sha256,
        },
        'reported_calls': reported_calls,
    }

    return payload


def parse_args():
    parser = argparse.ArgumentParser(description='Stage 5 PGx clinical interpretation engine')
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

    payload = build_pgx_call(
        meta=meta,
        thresholds_path=Path(args.thresholds),
        references_path=Path(args.references),
        vcf_path=Path(args.vcf),
    )
    Path(args.output).write_text(json.dumps(payload, sort_keys=True), encoding='utf-8')


if __name__ == '__main__':
    main()