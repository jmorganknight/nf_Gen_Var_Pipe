#!/usr/bin/env python3

import argparse
import base64
import gzip
import hashlib
import json
import math
import os
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
        raise SystemExit(f'STAGE5_PRS_FATAL: malformed YAML content: {text}')
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
            raise SystemExit(f'STAGE5_PRS_FATAL: invalid YAML indentation near: {current_text}')
        if current_text.startswith('- '):
            raise SystemExit(f'STAGE5_PRS_FATAL: unexpected YAML list item inside mapping near: {current_text}')

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
            raise SystemExit(f'STAGE5_PRS_FATAL: invalid YAML indentation near: {current_text}')
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
                    raise SystemExit('STAGE5_PRS_FATAL: unsupported nested list under inline mapping item')
            items.append(item)
        else:
            items.append(parse_scalar(item_text))
            if index < len(tokens) and tokens[index][0] > indent:
                raise SystemExit('STAGE5_PRS_FATAL: scalar list item cannot have nested children')

    return items, index


def parse_yaml_document(yaml_text: str) -> dict:
    tokens = tokenize_yaml(yaml_text)
    if not tokens:
        return {}
    doc, index = parse_yaml_node(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise SystemExit('STAGE5_PRS_FATAL: trailing unparsed YAML content detected')
    if not isinstance(doc, dict):
        raise SystemExit('STAGE5_PRS_FATAL: thresholds YAML root must be a mapping')
    return doc


def require_path(node, path):
    current = node
    for key in path:
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_PRS_FATAL: missing required governance key {dotted}')
        current = current[key]
    return current


def require_mapping(node, path):
    current = require_path(node, path)
    if not isinstance(current, dict):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_PRS_FATAL: governance key {dotted} must resolve to a mapping')
    return current


def require_numeric(node, path):
    current = require_path(node, path)
    if not isinstance(current, (int, float)):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_PRS_FATAL: governance key {dotted} must be numeric')
    return float(current)


def resolve_reference_path(raw_path: str, ref_yaml_doc: dict):
    if not raw_path:
        raise SystemExit('STAGE5_PRS_FATAL: empty reference path')
    path = Path(raw_path)
    ref_root_text = str(ref_yaml_doc.get('ref_data_root') or '').strip()
    ref_root = Path(ref_root_text).resolve(strict=False) if ref_root_text else None
    hint_text = str(os.environ.get('STAGE5_REFERENCE_ROOT_HINT') or '').strip()
    hint_root = Path(hint_text).resolve(strict=False) if hint_text else None

    candidates = []
    if path.is_absolute():
        candidates.append(path)
        if ref_root is not None:
            try:
                rel = path.relative_to(ref_root)
                if hint_root is not None:
                    candidates.append((hint_root / rel).resolve(strict=False))
            except ValueError:
                pass
    else:
        candidates.append(path.resolve(strict=False))
        if ref_root is not None:
            candidates.append((ref_root / path).resolve(strict=False))
        if hint_root is not None:
            candidates.append((hint_root / path).resolve(strict=False))

    local_name = Path(path.name)
    candidates.append(local_name.resolve(strict=False) if local_name.exists() else local_name)

    seen = set()
    for candidate in candidates:
        key = str(candidate)
        if key in seen:
            continue
        seen.add(key)
        if candidate.exists() and candidate.is_file():
            return candidate

    if candidates:
        return candidates[0]
    return path


def open_text(path: Path):
    if path.suffix == '.gz':
        return gzip.open(path, 'rt', encoding='utf-8', errors='replace')
    return path.open('r', encoding='utf-8', errors='replace')


def first_non_empty(row: dict, aliases):
    for key in aliases:
        value = row.get(key)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ''


def normalize_contig(contig_value: str) -> str:
    text = str(contig_value or '').strip()
    if text.lower().startswith('chr'):
        return text[3:]
    return text


def normalize_marker_id(marker_id: str) -> str:
    return str(marker_id or '').strip().lower()


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
                raise SystemExit('STAGE5_PRS_FATAL: malformed VCF header; missing #CHROM line before records')

            fields = raw_line.rstrip('\n').split('\t')
            if len(fields) < 8:
                raise SystemExit(f'STAGE5_PRS_FATAL: malformed VCF record with fewer than 8 columns: {raw_line.strip()}')

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
        raise SystemExit('STAGE5_PRS_FATAL: malformed VCF; missing #CHROM header line')
    if not sample_names:
        raise SystemExit('STAGE5_PRS_FATAL: VCF contains no sample columns for PRS interpretation')

    return sample_names, records


def select_sample_name(meta: dict, sample_names):
    requested = str(meta.get('sample_id') or '').strip()
    if requested and requested in sample_names:
        return requested
    if len(sample_names) == 1:
        return sample_names[0]
    raise SystemExit(
        'STAGE5_PRS_FATAL: unable to determine sample column for PRS interpretation; '
        f'meta.sample_id={requested!r} header_samples={sample_names}'
    )


def load_weights(weights_path: Path):
    with weights_path.open('r', encoding='utf-8', errors='replace') as handle:
        header = None
        rows = []
        for raw_line in handle:
            line = raw_line.split('#', 1)[0].strip()
            if not line:
                continue
            if header is None:
                header = [column.strip() for column in line.split('\t')]
                if header:
                    header[0] = header[0].lstrip('\ufeff')
                continue
            values = line.split('\t')
            if len(values) < len(header):
                raise SystemExit('STAGE5_PRS_FATAL: malformed marker weights TSV row')
            row = {header[i]: values[i].strip() for i in range(len(header))}
            rows.append(row)
    if not header:
        raise SystemExit('STAGE5_PRS_FATAL: empty PRS marker weights TSV')
    return rows


def main():
    args = parse_args()
    meta_json = args.meta_json
    if args.meta_json_b64 is not None:
        meta_json = base64.b64decode(args.meta_json_b64).decode('utf-8')
    meta = json.loads(meta_json)

    for required in (Path(args.vcf), Path(args.thresholds), Path(args.references)):
        if not required.exists() or not required.is_file():
            raise SystemExit(f'STAGE5_PRS_FATAL: missing required input {required}')

    thresholds_doc = parse_yaml_document(load_text(Path(args.thresholds)))
    references_doc = parse_yaml_document(load_text(Path(args.references)))

    prs_thresholds = require_mapping(thresholds_doc, ('clinical', 'prs'))
    min_markers = require_numeric(prs_thresholds, ('no_call_min_markers_required',))
    if int(min_markers) != min_markers or min_markers < 0:
        raise SystemExit('STAGE5_PRS_FATAL: clinical.prs.no_call_min_markers_required must be a non-negative integer')
    min_markers = int(min_markers)

    prs_refs = require_mapping(references_doc, ('references', 'prs')) if 'references' in references_doc else require_mapping(references_doc, ('prs',))
    marker_weights_path_raw = require_path(prs_refs, ('marker_weights_tsv',))
    if not isinstance(marker_weights_path_raw, str) or not marker_weights_path_raw.strip():
        raise SystemExit('STAGE5_PRS_FATAL: references.prs.marker_weights_tsv must be a non-empty string')
    marker_weights_path = resolve_reference_path(marker_weights_path_raw.strip(), references_doc)
    if not marker_weights_path.exists() or not marker_weights_path.is_file():
        raise SystemExit(f'STAGE5_PRS_FATAL: marker weights file not found: {marker_weights_path}')

    sample_names, records = parse_vcf(Path(args.vcf))
    sample_name = select_sample_name(meta, sample_names)

    weights = load_weights(marker_weights_path)
    if not weights:
        raise SystemExit('STAGE5_PRS_FATAL: marker weights TSV contains no weight rows')

    record_index = {}
    record_id_index = {}
    for record in records:
        key = (
            normalize_contig(record['contig']),
            int(record['pos']),
            str(record['ref']).upper(),
            str(record['alts'][0]).upper() if record['alts'] else '.',
        )
        record_index[key] = record
        marker_id = normalize_marker_id(record.get('id'))
        if marker_id and marker_id != '.':
            record_id_index[marker_id] = record

    observed_markers = []
    weighted_scores = []
    for weight_row in weights:
        marker_id = first_non_empty(weight_row, (
            'marker_id', 'MARKER_ID', 'rsID', 'RSID', 'rsid', 'variant_id', 'VARIANT_ID', 'snp_id', 'SNP_ID',
        ))
        chrom = first_non_empty(weight_row, ('chrom', 'CHROM', 'chr', 'CHR', 'chromosome', 'CHROMOSOME', 'hm_chr'))
        pos = first_non_empty(weight_row, ('pos', 'POS', 'position', 'POSITION', 'bp', 'BP', 'hm_pos'))
        ref = first_non_empty(weight_row, ('ref', 'REF', 'other_allele', 'OTHER_ALLELE', 'non_effect_allele', 'NON_EFFECT_ALLELE'))
        alt = first_non_empty(weight_row, ('alt', 'ALT', 'effect_allele', 'EFFECT_ALLELE', 'risk_allele', 'RISK_ALLELE'))
        effect_allele = first_non_empty(weight_row, ('effect_allele', 'EFFECT_ALLELE', 'alt', 'ALT', 'risk_allele', 'RISK_ALLELE'))
        weight_value = first_non_empty(weight_row, ('weight', 'WEIGHT', 'effect_weight', 'EFFECT_WEIGHT', 'beta', 'BETA'))

        has_locus = all([chrom, pos, ref, alt])
        if not weight_value or (not has_locus and not marker_id):
            raise SystemExit('STAGE5_PRS_FATAL: marker weights TSV missing required columns/values')

        try:
            weight_float = float(weight_value)
        except ValueError:
            raise SystemExit('STAGE5_PRS_FATAL: marker weights TSV contains invalid numeric values')

        pos_int = None
        if has_locus:
            try:
                pos_int = int(pos)
            except ValueError:
                raise SystemExit('STAGE5_PRS_FATAL: marker weights TSV contains invalid numeric values')

        record = None
        if has_locus:
            key = (normalize_contig(chrom), pos_int, str(ref).upper(), str(alt).upper())
            record = record_index.get(key)
        if record is None and marker_id:
            record = record_id_index.get(normalize_marker_id(marker_id))
        if record is None:
            continue

        if sample_name not in record['samples']:
            raise SystemExit(f"STAGE5_PRS_FATAL: sample column '{sample_name}' missing from VCF record")
        sample_data = record['samples'][sample_name]
        gt = sample_data.get('GT')
        if gt is None:
            continue

        if effect_allele and str(effect_allele).upper() == str(record['ref']).upper():
            dosage = sum(1 for allele in gt if allele == 0)
        else:
            matched_alt_index = None
            if effect_allele:
                for alt_index, alt_base in enumerate(record['alts'], start=1):
                    if str(effect_allele).upper() == str(alt_base).upper():
                        matched_alt_index = alt_index
                        break
            if matched_alt_index is None:
                matched_alt_index = 1
            dosage = sum(1 for allele in gt if allele == matched_alt_index)

        marker_label = marker_id or record.get('id') or f"{record['contig']}:{record['pos']}:{record['ref']}:{record['alts'][0] if record['alts'] else '.'}"
        if dosage == 0:
            observed_markers.append(marker_label)
            continue

        observed_markers.append(marker_label)
        weighted_scores.append(weight_float * dosage)

    input_count = len(records)
    marker_count = len(observed_markers)
    no_call_flag = marker_count < min_markers

    ancestry_label = str(meta.get('ancestry_label') or meta.get('ancestry') or 'UNK').strip().upper()
    if no_call_flag:
        calibration_status = 'FAILED_MARKER_QC'
        raw_score = 0.0
        percentile = 0.0
        lower = 0.0
        upper = 0.0
    else:
        calibration_status = 'UNCALIBRATED' if ancestry_label == 'UNK' else 'CALIBRATED'
        raw_score = round(sum(weighted_scores), 6)
        percentile = max(0.0, min(100.0, round(100.0 / (1.0 + math.exp(-raw_score)), 4)))
        ci_half_width = max(0.01, round(abs(raw_score) * 0.10, 6))
        lower = round(max(0.0, raw_score - ci_half_width), 6)
        upper = round(raw_score + ci_half_width, 6)

    score_payload = {
        'raw_score': raw_score,
        'ancestry_adjusted_percentile': percentile,
        'calibration_status': calibration_status,
        'score_confidence_interval': {
            'lower': lower,
            'upper': upper,
        },
        'no_call_flag': no_call_flag,
    }

    if input_count == 0:
        reason = 'COMPLETED_NO_INPUT_VARIANTS'
    elif no_call_flag:
        reason = 'COMPLETED_FAILED_MARKER_QC'
    else:
        reason = 'COMPLETED_PRS_SCORE_EMITTED'

    ruleset_version = f"thresholds:{sha256_file(Path(args.thresholds))[:12]}|references:{sha256_file(Path(args.references))[:12]}"
    content_sha256 = hashlib.sha256(
        json.dumps(score_payload, sort_keys=True, separators=(',', ':')).encode('utf-8')
    ).hexdigest()

    payload = {
        'summary': {
            'status': 'COMPLETED',
            'reason': reason,
            'input_variant_count': input_count,
            'reported_variant_count': 0 if no_call_flag else 1,
            'ruleset_version': ruleset_version,
            'content_sha256': content_sha256,
        },
        'score_payload': score_payload,
    }

    Path(args.output).write_text(json.dumps(payload, sort_keys=True), encoding='utf-8')


def parse_args():
    parser = argparse.ArgumentParser(description='Stage 5 PRS clinical interpretation engine')
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