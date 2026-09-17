process STAGE6_RELEASE_FINALIZER {

    label 'process_low'
    container 'genvar-reporting:2.1.0'
    stageInMode 'copy'

    publishDir "${params.outdir}", mode: 'copy', overwrite: true, pattern: 'Stage6_SHA256SUMS.txt'

    input:
    path release_artifacts

    output:
    path 'Stage6_SHA256SUMS.txt', emit: sha256_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import hashlib
import json
from pathlib import Path


def fail(message: str):
    raise SystemExit(f"STAGE6_RELEASE_FINALIZER_FATAL: {message}")


artifact_json = '''${groovy.json.JsonOutput.toJson(release_artifacts.collect { item -> item.toString() }).replace('\\n', ' ').replace('\\r', '')}'''
artifact_paths = [Path(p) for p in json.loads(artifact_json)]

if not artifact_paths:
    fail('no release artifacts were provided for integrity packaging')

resolved = {}
for artifact in artifact_paths:
    target = artifact.resolve()
    if not target.exists():
        fail(f'missing release artifact: {target}')
    resolved[str(target)] = target

lines = []
for path_text in sorted(resolved.keys()):
    digest = hashlib.sha256()
    with resolved[path_text].open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    lines.append(f"{digest.hexdigest()}  {path_text}")

Path('Stage6_SHA256SUMS.txt').write_text('\\n'.join(lines) + '\\n', encoding='utf-8')
PYEOF
    """
}
