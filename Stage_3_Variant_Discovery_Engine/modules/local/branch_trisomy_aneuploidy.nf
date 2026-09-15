process BRANCH_TRISOMY_ANEUPLOIDY {
    label 'process_low'
    container 'genvar-core:2.1.0'

    input:
    tuple path(contract_json), path(branch_plan_json)

    output:
    path 'trisomy_aneuploidy.vcf', emit: branch_vcf

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

contract = json.loads(Path('${contract_json}').read_text(encoding='utf-8'))
plan = json.loads(Path('${branch_plan_json}').read_text(encoding='utf-8'))
sid = contract['sample_id']
enabled = bool(plan.get('trisomy_aneuploidy'))
with open('trisomy_aneuploidy.vcf', 'w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2\n')
    out.write('##source=STAGE3_TRISOMY_ANEUPLOIDY\n')
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n')
    out.write('7\t700\t.\tC\tT\t60\tPASS\tANEUPLOIDY=1;ENABLED=' + str(enabled).lower() + ';SAMPLE=' + sid + '\n')
PYEOF
    """
}
