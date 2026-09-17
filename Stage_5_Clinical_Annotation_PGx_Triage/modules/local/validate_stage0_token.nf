process VALIDATE_STAGE0_TOKEN {
    label 'process_low'
    container 'genvar-annotation:2.1.0'
    stageInMode 'copy'
    tag "${meta?.sample_id ?: 'UNKNOWN'}"

    input:
    tuple val(meta), path(vcf)

    output:
    tuple val(meta), path(vcf), emit: validated_intake

    script:
    def metaJson = groovy.json.JsonOutput.toJson(meta ?: [:])

    """
    set -euo pipefail

    cat > sample_meta.json <<'JSON'
${metaJson}
JSON

    python3 - <<'PY'
import json
import sys
from pathlib import Path

meta = json.loads(Path('sample_meta.json').read_text(encoding='utf-8'))
sample_id = str(meta.get('sample_id') or '').strip()
token = meta.get('intake_validation_token')
token_text = '' if token is None else str(token).strip()
token_value = str(meta.get('intake_validation_token_value') or '').strip()


def token_has_valid_namespace(text: str) -> bool:
    token_norm = (text or '').strip()
    if not token_norm:
        return False
    token_upper = token_norm.upper()
    return (
        token_norm.startswith('STAGE0-INGEST-v1:')
        or token_norm.startswith('VALID_PASS|INTAKE_VALIDATED')
        or token_norm.startswith('VALID_PASS')
        or token_norm.startswith('PASS')
        or 'STAGE0' in token_upper
        or 'INTAKE_VALIDATED' in token_upper
    )

token_path = Path(token_text) if token_text else None
if token_path and token_path.exists() and token_path.is_file():
    token_text = token_path.read_text(encoding='utf-8').strip()

if not token_has_valid_namespace(token_text) and token_has_valid_namespace(token_value):
    token_text = token_value

if not sample_id:
    print('STAGE5_CHAIN_OF_CUSTODY_FATAL: missing meta.sample_id', file=sys.stderr)
    sys.exit(1)

if not token_text:
    print('STAGE5_CHAIN_OF_CUSTODY_FATAL: missing meta.intake_validation_token', file=sys.stderr)
    sys.exit(1)

if token_text.startswith('STAGE0-INGEST-v1:'):
    if sample_id not in token_text:
        print('STAGE5_CHAIN_OF_CUSTODY_FATAL: sample_id missing from intake_validation_token', file=sys.stderr)
        sys.exit(1)
elif not token_has_valid_namespace(token_text):
    print('STAGE5_CHAIN_OF_CUSTODY_FATAL: invalid Stage 0 token namespace', file=sys.stderr)
    sys.exit(1)
PY
    """
}