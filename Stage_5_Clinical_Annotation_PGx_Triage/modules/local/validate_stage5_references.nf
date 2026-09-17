nextflow.enable.dsl = 2

String stage5DockerReferenceBind() {
    def root = stage5ReferenceRoot()
    root ? "-v \"${root}:${root}:ro\"" : ''
}

String stage5ReferenceRoot() {
    def direct = [params.reference_mount_root, params.ref_dir, params.ref_data_root, System.getenv('NXF_REF_DATA_ROOT')]
        .collect { value -> value?.toString()?.trim() }
        .find { value -> value }
    if (direct) {
        return direct
    }

    def referencesPath = params.references?.toString()?.trim()
    if (!referencesPath) {
        return ''
    }

    def refsFile = new File(referencesPath)
    if (!refsFile.isAbsolute()) {
        refsFile = new File(projectDir.toString(), referencesPath)
    }
    if (!refsFile.exists()) {
        return ''
    }

    def refsDoc = new groovy.yaml.YamlSlurper().parse(refsFile)
    return refsDoc?.ref_data_root?.toString()?.trim() ?: ''
}

process VALIDATE_STAGE5_REFERENCES {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    containerOptions { stage5DockerReferenceBind() }
    cache false
    stageInMode 'copy'
    tag 'references'

    input:
    path references_yaml
    path staged_reference_assets

    output:
    path 'references_validated.txt', emit: validated_signal

    script:
    """
    set -euo pipefail

    export STAGE5_REFERENCE_VALIDATOR_REV="dynamic-bind-v3"
    export STAGE5_REFERENCE_ROOT_HINT="${stage5ReferenceRoot()}"

    python3 - <<'PY'
from pathlib import Path
import os
import sys


def strip_comment(line: str) -> str:
    return line.split('#', 1)[0].rstrip()


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
        raise SystemExit(f'STAGE5_REFERENCE_FATAL: malformed YAML content: {text}')
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
            raise SystemExit(f'STAGE5_REFERENCE_FATAL: invalid YAML indentation near: {current_text}')
        if current_text.startswith('- '):
            raise SystemExit(f'STAGE5_REFERENCE_FATAL: unexpected YAML list item inside mapping near: {current_text}')

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
            raise SystemExit(f'STAGE5_REFERENCE_FATAL: invalid YAML indentation near: {current_text}')
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
                    raise SystemExit('STAGE5_REFERENCE_FATAL: unsupported nested list under inline mapping item')
            items.append(item)
        else:
            items.append(parse_scalar(item_text))
            if index < len(tokens) and tokens[index][0] > indent:
                raise SystemExit('STAGE5_REFERENCE_FATAL: scalar list item cannot have nested children')

    return items, index


def parse_yaml_document(yaml_text: str):
    tokens = tokenize_yaml(yaml_text)
    if not tokens:
        return {}
    doc, index = parse_yaml_node(tokens, 0, tokens[0][0])
    if index != len(tokens):
        raise SystemExit('STAGE5_REFERENCE_FATAL: trailing unparsed YAML content detected')
    if not isinstance(doc, dict):
        raise SystemExit('STAGE5_REFERENCE_FATAL: references YAML root must be a mapping')
    return doc


def require_path(node, path):
    current = node
    for key in path:
        if not isinstance(current, dict) or key not in current:
            dotted = '.'.join(path)
            raise SystemExit(f'STAGE5_REFERENCE_FATAL: missing required governance key {dotted}')
        current = current[key]
    return current


def require_string(node, path):
    current = require_path(node, path)
    if not isinstance(current, str) or not current.strip():
        dotted = '.'.join(path)
        raise SystemExit(f'STAGE5_REFERENCE_FATAL: governance key {dotted} must be a non-empty string')
    return current.strip()


def resolve_reference_path(raw_path: str, ref_data_root: str, reference_root_hint: str):
    if not raw_path:
        raise SystemExit('STAGE5_REFERENCE_FATAL: empty reference path')
    path = Path(raw_path)
    ref_root = Path(ref_data_root).resolve(strict=False) if ref_data_root else None
    hint_root = Path(reference_root_hint).resolve(strict=False) if reference_root_hint else None

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

    local_rel = Path(path.name)
    candidates.append(local_rel.resolve(strict=False) if local_rel.exists() else local_rel)

    seen = set()
    for candidate in candidates:
        candidate_key = str(candidate)
        if candidate_key in seen:
            continue
        seen.add(candidate_key)
        if candidate.exists():
            return candidate

    if path.is_absolute():
        return path
    if ref_root is not None:
        return (ref_root / path).resolve(strict=False)
    if hint_root is not None:
        return (hint_root / path).resolve(strict=False)
    return path


references_path = Path('${references_yaml}')
if not references_path.exists() or not references_path.is_file():
    raise SystemExit(f'STAGE5_REFERENCE_FATAL: missing references YAML: {references_path}')

references_doc = parse_yaml_document(references_path.read_text(encoding='utf-8', errors='replace'))
ref_data_root = str(references_doc.get('ref_data_root') or '').strip()
reference_root_hint = os.environ.get('STAGE5_REFERENCE_ROOT_HINT', '').strip()

required_refs = {
    'references.sf.acmg_registry_json': require_string(references_doc, ('references', 'sf', 'acmg_registry_json')),
    'references.somatic.hotspots_bed': require_string(references_doc, ('references', 'somatic', 'hotspots_bed')),
    'references.prs.marker_weights_tsv': require_string(references_doc, ('references', 'prs', 'marker_weights_tsv')),
    'references.stage3.stage3_vcf_schema': require_string(references_doc, ('references', 'stage3', 'stage3_vcf_schema')),
}

validated_lines = []
for label, raw_path in required_refs.items():
    resolved = resolve_reference_path(raw_path, ref_data_root, reference_root_hint)
    if not resolved.exists() or not resolved.is_file():
        raise SystemExit(f'STAGE5_REFERENCE_FATAL: missing required reference for {label}: {resolved}')
    if resolved.stat().st_size <= 0:
        raise SystemExit(f'STAGE5_REFERENCE_FATAL: zero-byte reference for {label}: {resolved}')
    validated_lines.append(f'{label}={resolved}')

Path('references_validated.txt').write_text('\\n'.join(validated_lines) + '\\n', encoding='utf-8')
PY
    """
}