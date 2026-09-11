process BRANCH_COPY_NUMBER_CNV {
    label 'process_low'
    container 'wes-onco-core:1.0.0'

    input:
    tuple path(contract_json), path(branch_plan_json)

    output:
    path 'copy_number_cnv.vcf', emit: branch_vcf

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

contract = json.loads(Path('${contract_json}').read_text(encoding='utf-8'))
plan = json.loads(Path('${branch_plan_json}').read_text(encoding='utf-8'))
sid = contract['sample_id']
enabled = bool(plan.get('copy_number_cnv'))
with open('copy_number_cnv.vcf', 'w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2\n')
    out.write('##source=STAGE3_COPY_NUMBER_CNV\n')
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n')
    out.write('3\t300\t.\tN\t<CNV>\t60\tPASS\tCN=3;ENABLED=' + str(enabled).lower() + ';SAMPLE=' + sid + '\n')
PYEOF
    """
}
