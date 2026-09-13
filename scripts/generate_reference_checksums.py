#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import re
from pathlib import Path
from typing import Iterable


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_path(path: Path) -> str:
    if path.is_dir():
        digest = hashlib.sha256()
        for child in sorted(node for node in path.rglob('*') if node.is_file()):
            digest.update(str(child.relative_to(path)).replace('\\', '/').encode('utf-8'))
            digest.update(b'\0')
            digest.update(sha256_file(child).encode('ascii'))
            digest.update(b'\0')
        return digest.hexdigest()
    return sha256_file(path)


def strip_inline_comment(value: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    chars: list[str] = []
    for char in value:
        if escaped:
            chars.append(char)
            escaped = False
            continue
        if char == '\\':
            chars.append(char)
            escaped = True
            continue
        if char == "'" and not in_double:
            in_single = not in_single
            chars.append(char)
            continue
        if char == '"' and not in_single:
            in_double = not in_double
            chars.append(char)
            continue
        if char == '#' and not in_single and not in_double:
            break
        chars.append(char)
    return ''.join(chars).strip()


def unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def iter_manifest_scalar_values(text: str) -> Iterable[str]:
    key_value_pattern = re.compile(r'^\s*[^:#][^:]*:\s*(.+?)\s*$')
    for raw_line in text.splitlines():
        line = strip_inline_comment(raw_line)
        if not line:
            continue
        match = key_value_pattern.match(line)
        if not match:
            continue
        value = unquote(match.group(1).strip())
        if not value or value in {'|', '>', '{}', '[]'}:
            continue
        yield value


def collect_paths_from_yaml_text(text: str, paths: set[str]) -> None:
    for value in iter_manifest_scalar_values(text):
        if '/' not in value:
            continue
        if value.endswith(('.json', '.bed', '.fa', '.fai', '.dict', '.gz', '.gz.tbi', '.tsv', '.cnn', '.yaml', '.yml')) or value.startswith('/opt/reference'):
            paths.add(value)


def resolve_path(path_text: str, ref_root: Path, repo_root: Path) -> Path:
    if path_text.startswith('/opt/reference'):
        suffix = path_text.removeprefix('/opt/reference').lstrip('/')
        return ref_root / suffix
    candidate = Path(path_text)
    if candidate.is_absolute():
        return candidate
    return (repo_root / candidate).resolve()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo-root', default=Path(__file__).resolve().parents[1], type=Path)
    parser.add_argument('--ref-root', default=None, type=Path)
    parser.add_argument('--references-yaml', default=None, type=Path)
    parser.add_argument('--output', default=None, type=Path)
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    env_ref_root = os.environ.get('NXF_REF_DATA_ROOT')
    ref_root = (args.ref_root or (Path(env_ref_root) if env_ref_root else (repo_root / 'assets' / 'references'))).resolve()
    references_yaml = (args.references_yaml or (repo_root / 'conf' / 'references.yaml')).resolve()
    output = (args.output or (repo_root / 'assets' / 'reference_checksums.sha256')).resolve()

    paths: set[str] = set()
    collect_paths_from_yaml_text(references_yaml.read_text(encoding='utf-8'), paths)
    paths.add('../Stage_3_Variant_Discovery_Engine/tests/schemas/v4.2_Production_Schema.json')
    paths.add('../Stage_3_Variant_Discovery_Engine/tests/schemas/mane_priority_stub.bed')

    lines: list[str] = []
    for path_text in sorted(paths):
        resolved = resolve_path(path_text, ref_root, repo_root)
        if not resolved.exists():
            continue
        lines.append(f"{sha256_path(resolved)}  {path_text}")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
