process BRANCH_STR_EXPANSIONS {
    label 'process_low'
    container 'genvar-core:2.0.0'

    input:
    tuple path(contract_json), path(branch_plan_json)

    output:
    path 'str_expansions.vcf', emit: branch_vcf

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

contract = json.loads(Path('${contract_json}').read_text(encoding='utf-8'))
plan = json.loads(Path('${branch_plan_json}').read_text(encoding='utf-8'))
sid = contract['sample_id']
enabled = bool(plan.get('str_expansions'))
with open('str_expansions.vcf', 'w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2\n')
    out.write('##source=STAGE3_STR_EXPANSIONS\n')
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n')
    out.write('4\t400\t.\tA\tA[STR]\t60\tPASS\tSTRLEN=12;ENABLED=' + str(enabled).lower() + ';SAMPLE=' + sid + '\n')
PYEOF
    """
}
