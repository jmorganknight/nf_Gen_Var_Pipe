process BRANCH_HOMOLOGOUS_PSEUDOGENES {
    label 'process_low'
    container 'genvar-core:2.0.0'

    input:
    tuple path(contract_json), path(branch_plan_json)

    output:
    path 'homologous_pseudogenes.vcf', emit: branch_vcf

    script:
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
from pathlib import Path

contract = json.loads(Path('${contract_json}').read_text(encoding='utf-8'))
plan = json.loads(Path('${branch_plan_json}').read_text(encoding='utf-8'))
sid = contract['sample_id']
enabled = bool(plan.get('homologous_pseudogenes'))
with open('homologous_pseudogenes.vcf', 'w', encoding='utf-8') as out:
    out.write('##fileformat=VCFv4.2\n')
    out.write('##source=STAGE3_HOMOLOGOUS_PSEUDOGENES\n')
    out.write('#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n')
    out.write('9\t900\t.\tG\tA\t60\tPASS\tPSEUDOGENE=1;ENABLED=' + str(enabled).lower() + ';SAMPLE=' + sid + '\n')
PYEOF
    """
}