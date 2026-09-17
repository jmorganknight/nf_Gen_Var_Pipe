#!/usr/bin/env python3

import argparse
import base64
import gzip
import hashlib
import json
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
        raise SystemExit(f'STAGE5_SOMATIC_FATAL: malformed YAML content: {text}')
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
            raise SystemExit(f'STAGE5_SOMATIC_FATAL: invalid YAML indentation near: {current_text}')
        if current_text.startswith('- '):
            raise SystemExit(f'STAGE5_SOMATIC_FATAL: unexpected YAML list item inside mapping near: {current_text}')

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
            raise SystemExit(f'STAGE5_SOMATIC_FATAL: invalid YAML indentation near: {current_text}')
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
                    raise SystemExit('STAGE5_SOMATIC_FATAL: unsupported nested list under inline mapping item')
            items.append(item)
        else:
            items.append(parse_scalar(item_text))
            if index < len(tokens) and tokens[index][0] > indent:
                raise SystemExit('STAGE5_SOMATIC_FATAL: scalar list item cannot have nested children')

    return items, index


def parse_yaml_document(yaml_text: str) -> dict:
    tokens = tokenize_yaml(yaml_text)
    if not tokens:
        return {}
    doc, index = parse_yaml_node(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise SystemExit('STAGE5_SOMATIC_FATAL: trailing unparsed YAML content detected')
    if not isinstance(doc, dict):
        raise SystemExit('STAGE5_SOMATIC_FATAL: YAML root must be a mapping')
    return doc


def require_path(node, path):
    current = node
    for key in path:
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_SOMATIC_FATAL: missing required governance key {dotted}')
        current = current[key]
    return current


def require_mapping(node, path):
    current = require_path(node, path)
    if not isinstance(current, dict):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SOMATIC_FATAL: governance key {dotted} must resolve to a mapping')
    return current


def require_numeric(node, path):
    current = require_path(node, path)
    if not isinstance(current, (int, float)):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SOMATIC_FATAL: governance key {dotted} must be numeric')
    return float(current)


def require_list(node, path):
    current = require_path(node, path)
    if not isinstance(current, list):
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_SOMATIC_FATAL: governance key {dotted} must be a list')
    return current


def resolve_reference_path(raw_path: str, ref_yaml_doc: dict):
    if not raw_path:
        raise SystemExit('STAGE5_SOMATIC_FATAL: empty reference path')
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

    unresolved = candidates[0] if candidates else path
    raise SystemExit(f'STAGE5_SOMATIC_FATAL: hotspot BED not found: {unresolved}')


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
                raise SystemExit('STAGE5_SOMATIC_FATAL: malformed VCF header; missing #CHROM line before records')

            fields = raw_line.rstrip('\n').split('\t')
            if len(fields) < 8:
                raise SystemExit(f'STAGE5_SOMATIC_FATAL: malformed VCF record with fewer than 8 columns: {raw_line.strip()}')

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
        raise SystemExit('STAGE5_SOMATIC_FATAL: malformed VCF; missing #CHROM header line')
    if not sample_names:
        raise SystemExit('STAGE5_SOMATIC_FATAL: VCF contains no sample columns for somatic interpretation')

    return sample_names, records


def select_sample_name(meta: dict, sample_names):
    requested = str(meta.get('sample_id') or '').strip()
    if requested and requested in sample_names:
        return requested
    if len(sample_names) == 1:
        return sample_names[0]
    raise SystemExit(
        'STAGE5_SOMATIC_FATAL: unable to determine sample column for somatic interpretation; '
        f'meta.sample_id={requested!r} header_samples={sample_names}'
    )


def first_float(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).split(',')[0].strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def load_hotspots(bed_path: Path):
    intervals = {}
    with bed_path.open('r', encoding='utf-8', errors='replace') as handle:
        for raw_line in handle:
            line = raw_line.split('#', 1)[0].strip()
            if not line or line.startswith('track') or line.startswith('browser'):
                continue
            fields = line.split('\t')
            if len(fields) < 3:
                continue
            chrom = fields[0].strip()
            try:
                start = int(fields[1])
                end = int(fields[2])
            except ValueError:
                continue
            intervals.setdefault(chrom, []).append((start, end))
            if chrom.startswith('chr'):
                intervals.setdefault(chrom[3:], []).append((start, end))
            else:
                intervals.setdefault(f'chr{chrom}', []).append((start, end))
    return intervals


def overlaps_hotspot(record: dict, hotspot_intervals: dict):
    chrom = str(record['contig']).strip()
    pos0 = int(record['pos']) - 1
    keys = [chrom]
    if chrom.startswith('chr'):
        keys.append(chrom[3:])
    else:
        keys.append(f'chr{chrom}')
    for key in keys:
        for start, end in hotspot_intervals.get(key, []):
            if start <= pos0 < end:
                return True
    return False


def read_vaf(record: dict, sample_data: dict):
    info = record['info']
    vaf = first_float(info.get('VAF'))
    if vaf is not None:
        return max(0.0, min(1.0, vaf)), 'INFO.VAF'
    vaf = first_float(info.get('AF'))
    if vaf is not None:
        return max(0.0, min(1.0, vaf)), 'INFO.AF'

    ad = sample_data.get('AD')
    if isinstance(ad, tuple) and len(ad) >= 2:
        try:
            ref_depth = float(ad[0] or 0.0)
            alt_depth = float(ad[1] or 0.0)
            total = ref_depth + alt_depth
            if total > 0:
                return max(0.0, min(1.0, alt_depth / total)), 'FORMAT.AD'
        except (TypeError, ValueError):
            pass
    return None, ''


def read_origin_status(record: dict, sample_data: dict):
    info = record['info']
    for key in ('ORIGIN_STATUS', 'SOMATIC_STATUS', 'VARIANT_ORIGIN', 'SOURCE_STATUS'):
        value = str(info.get(key) or '').strip().upper()
        if value in {'SOMATIC', 'GERMLINE', 'UNDETERMINED'}:
            return value

    ad = sample_data.get('AD')
    af = sample_data.get('AF')
    if isinstance(ad, tuple) and len(ad) >= 2:
        try:
            total = float(ad[0] or 0.0) + float(ad[1] or 0.0)
            if total > 0 and (float(ad[1] or 0.0) / total) >= 0.20:
                return 'SOMATIC'
        except (TypeError, ValueError, ZeroDivisionError):
            pass
    af_val = first_float(af)
    if af_val is not None and af_val >= 0.20:
        return 'SOMATIC'
    return 'UNDETERMINED'


def tier_rank(tier: str) -> int:
    return {'IV': 1, 'III': 2, 'II': 3, 'I': 4}.get(tier, 0)


def rank_to_tier(rank: int) -> str:
    return {4: 'I', 3: 'II', 2: 'III', 1: 'IV'}.get(rank, 'IV')


def main():
    args = parse_args()
    meta_json = args.meta_json
    if args.meta_json_b64 is not None:
        meta_json = base64.b64decode(args.meta_json_b64).decode('utf-8')
    meta = json.loads(meta_json)

    vcf_path = Path(args.vcf)
    thresholds_path = Path(args.thresholds)
    references_path = Path(args.references)
    output_path = Path(args.output)

    for required in (vcf_path, thresholds_path, references_path):
        if not required.exists() or not required.is_file():
            raise SystemExit(f'STAGE5_SOMATIC_FATAL: missing required input {required}')

    thresholds_doc = parse_yaml_document(load_text(thresholds_path))
    references_doc = parse_yaml_document(load_text(references_path))

    somatic_thresholds = require_mapping(thresholds_doc, ('clinical', 'somatic'))
    minimum_vaf = require_numeric(somatic_thresholds, ('minimum_vaf',))
    reportable_tiers = [str(item).strip() for item in require_list(somatic_thresholds, ('reportable_tiers',)) if str(item).strip()]
    if not reportable_tiers:
        raise SystemExit('STAGE5_SOMATIC_FATAL: clinical.somatic.reportable_tiers must contain at least one tier')
    hotspot_tier_bump = int(require_numeric(somatic_thresholds, ('hotspot_tier_bump',)))
    if hotspot_tier_bump < 0:
        raise SystemExit('STAGE5_SOMATIC_FATAL: clinical.somatic.hotspot_tier_bump must be non-negative')

    hotspot_raw_path = None
    if isinstance(references_doc.get('references'), dict):
        nested = references_doc['references']
        if isinstance(nested.get('somatic'), dict):
            hotspot_raw_path = str(nested['somatic'].get('hotspots_bed') or '').strip()
    if not hotspot_raw_path and isinstance(references_doc.get('somatic'), dict):
        hotspot_raw_path = str(references_doc['somatic'].get('hotspots_bed') or '').strip()
    if not hotspot_raw_path:
        raise SystemExit('STAGE5_SOMATIC_FATAL: references.somatic.hotspots_bed is required')
    hotspot_bed = resolve_reference_path(hotspot_raw_path, references_doc)
    hotspot_intervals = load_hotspots(hotspot_bed)

    sample_names, records = parse_vcf(vcf_path)
    sample_name = select_sample_name(meta, sample_names)

    reported_variants = []
    for record in records:
        if sample_name not in record['samples']:
            raise SystemExit(f"STAGE5_SOMATIC_FATAL: sample column '{sample_name}' missing from VCF record")

        sample_data = record['samples'][sample_name]
        vaf, vaf_source = read_vaf(record, sample_data)
        if vaf is None or vaf < minimum_vaf:
            continue

        origin_status = read_origin_status(record, sample_data)
        hotspot_hit = overlaps_hotspot(record, hotspot_intervals)

        if vaf >= 0.40:
            tier = 'I'
        elif vaf >= 0.20:
            tier = 'II'
        elif vaf >= minimum_vaf:
            tier = 'III'
        else:
            tier = 'IV'

        if hotspot_hit:
            tier = rank_to_tier(min(4, tier_rank(tier) + hotspot_tier_bump))

        if tier not in reportable_tiers:
            continue

        reported_variants.append({
            'amp_asco_cap_tier': tier,
            'vaf': max(0.0, min(1.0, vaf)),
            'origin_status': origin_status,
            'hotspot_flag': bool(hotspot_hit),
            'vaf_source': vaf_source,
            'variant_id': str(record['id']).strip(),
            'chrom': str(record['contig']).strip(),
            'pos': int(record['pos'])
        })

    input_count = len(records)
    if input_count == 0:
        reason = 'COMPLETED_NO_INPUT_VARIANTS'
    elif reported_variants:
        reason = 'COMPLETED_SOMATIC_RECORD_EMITTED'
    else:
        reason = 'COMPLETED_NO_SOMATIC_VAF_QUALIFIED_RECORDS_DETECTED'

    ruleset_version = f"thresholds:{sha256_file(thresholds_path)[:12]}|references:{sha256_file(references_path)[:12]}|hotspots:{sha256_file(hotspot_bed)[:12]}"
    content_sha256 = hashlib.sha256(
        json.dumps(reported_variants, sort_keys=True, separators=(',', ':')).encode('utf-8')
    ).hexdigest()

    payload = {
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

    output_path.write_text(json.dumps(payload, sort_keys=True), encoding='utf-8')


def parse_args():
    parser = argparse.ArgumentParser(description='Stage 5 somatic clinical interpretation engine')
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
