process BRANCH_SNV_INDEL {
    label 'process_low'
    container 'genvar-core:2.1.0'

    input:
    tuple path(contract_json), path(branch_plan_json)

    output:
    path 'snv_indel.vcf', emit: branch_vcf

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

contract = json.loads(Path('${contract_json}').read_text(encoding='utf-8'))
plan = json.loads(Path('${branch_plan_json}').read_text(encoding='utf-8'))
faults = contract.get('stage3_faults', {})
sid = contract['sample_id']
enabled = bool(plan.get('snv_indel'))
header = '##fileformat=VCFv4.2'
if faults.get('corrupt_vcf_header'):
    header = '##fileformat=BADVCF'

with open('snv_indel.vcf', 'w', encoding='utf-8') as out:
    out.write(header + '\n')
    out.write('##source=STAGE3_SNV_INDEL\n')
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n')
    out.write('1\t100\t.\tA\tG,C\t60\tPASS\tBRANCH=snv_indel;ENABLED=' + str(enabled).lower() + ';SAMPLE=' + sid + '\n')
PYEOF
    """
}
