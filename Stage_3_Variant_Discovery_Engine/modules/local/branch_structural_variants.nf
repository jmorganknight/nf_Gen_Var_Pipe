process BRANCH_STRUCTURAL_VARIANTS {
    label 'process_low'
    container 'genvar-core:2.0.0'

    input:
    tuple path(contract_json), path(branch_plan_json)

    output:
    path 'structural_variants.vcf', emit: branch_vcf

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

contract = json.loads(Path('${contract_json}').read_text(encoding='utf-8'))
plan = json.loads(Path('${branch_plan_json}').read_text(encoding='utf-8'))
sid = contract['sample_id']
enabled = bool(plan.get('structural_variants'))
with open('structural_variants.vcf', 'w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2\n')
    out.write('##source=STAGE3_STRUCTURAL_VARIANTS\n')
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n')
    out.write('2\t200\t.\tN\t<DEL>\t60\tPASS\tSVTYPE=DEL;END=250;ENABLED=' + str(enabled).lower() + ';SAMPLE=' + sid + '\n')
PYEOF
    """
}
