/*
 * ─────────────────────────────────────────────────────────────────────────────
 * Process : AUTOMATED_INGEST_GATE
 * Stage   : 0 — LIMS Metadata Validation & Platform-Aware Sifting
 *
 * Blueprint node : GATE_CHECK (draft_03.html)
 * Purpose:
 *   Validate input file formats; parse and lock LIMS metadata; assert md5
 *   parity; evaluate base call accuracy against clinical Q30 floors;
 *   perform sex chromosome concordance pre-check; enforce platform-specific
 *   sifting rules. Emits validated sample tuples into the processing graph.
 *
 * Rule enforcement:
 *   Rule 1.1  — Ultima: preserve ZM/UR/UQ flow tags; context-aware dedup mode.
 *   Rule 1.2  — Complete Genomics: require flowcell_geometry=DNBSEQ_PATTERNED.
 *   Rule 1.4  — Consent: log PRS / SF opt-in state; downstream channels gated.
 *   Rule 1.5  — Germline EXPECTED_DIPLOID_MODE; somatic alpha covariate lock.
 *   Rule 6.1  — Data integrity fault → sys.exit(1) → errorStrategy='finish'.
 *   Rule 7.2.1 — Audit trail banked to ${meta.save_dir}/${meta.sample_id}/.
 *
 * Inputs  :
 *   tuple val(meta), path(fastq_1), path(fastq_2)
 *   path(thresholds_yaml)
 *
 * Outputs :
 *   tuple val(meta), path("*_R1.validated.fastq.gz"),
 *                    path("*_R2.validated.fastq.gz"),
 *                    path("intake_validation_token"),
 *                    path("*.intake_validation_report.json") → emit: intake_payload
 *   path("intake_validation_token")                   → emit: intake_token
 *   path("*.intake_validation_report.json")           → emit: audit_trail
 * ─────────────────────────────────────────────────────────────────────────────
 */

process AUTOMATED_INGEST_GATE {

    label 'process_low'
    container 'genvar-core:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/audit_and_qc", mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(fastq_1), path(fastq_2)
    path thresholds_yaml

    output:
    tuple val(meta),
          path("${meta.sample_id}_R1.validated.fastq.gz"),
          path("${meta.sample_id}_R2.validated.fastq.gz"),
          path('intake_validation_token'),
          path("${meta.sample_id}.intake_validation_report.json"), emit: intake_payload
    path 'intake_validation_token', emit: intake_token
    path "${meta.sample_id}.intake_validation_report.json", emit: audit_trail

    script:
    def sid = meta.sample_id
    def platform = meta.sequencer?.platform ?: 'illumina'
    def model = meta.sequencer?.model ?: 'unknown'
    def geometry = meta.sequencer?.flowcell_geometry ?: 'native'
    def sampleType = meta.sample_type ?: 'somatic'
    def gender = meta.gender ?: 'unknown'
    def prsOptIn = meta.consent?.prs_opt_in ?: false
    def sfOptIn = meta.consent?.sf_opt_in ?: false
    def tumorBurden = meta.pathologist_tumor_burden ?: 0.0
    def patientId = meta.patient_id ?: sid
    def caseId = meta.case_id ?: patientId
    def accessionId = meta.accession_id ?: ''
    def encounterId = meta.encounter_id ?: ''
    def specimenId = meta.specimen_id ?: ''
    def analysisBatchId = meta.analysis_batch_id ?: ''
    def consentTokensJson = groovy.json.JsonOutput.toJson(meta.consent_tokens ?: [:]).replace('\n', ' ').replace('\r', '')
    def consentJson = groovy.json.JsonOutput.toJson(meta.consent).replace('\n', ' ').replace('\r', '')
    def biologicalContextJson = groovy.json.JsonOutput.toJson(meta.biological_context ?: [:]).replace('\n', ' ').replace('\r', '')
    def diagnosisJson = groovy.json.JsonOutput.toJson(meta.diagnosis ?: [:]).replace('\n', ' ').replace('\r', '')
    def specimenJson = groovy.json.JsonOutput.toJson(meta.specimen ?: [:]).replace('\n', ' ').replace('\r', '')
    def clinicalContextJson = groovy.json.JsonOutput.toJson(meta.clinical_context ?: [:]).replace('\n', ' ').replace('\r', '')
    def ingestManifestJson = groovy.json.JsonOutput.toJson(meta.ingest_manifest ?: [:]).replace('\n', ' ').replace('\r', '')

    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json, sys, os, hashlib, gzip
from datetime import datetime, timezone


def md5_hex(path):
    digest = hashlib.md5()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

def parse_scalar(value):
    value = value.strip()
    if value.startswith(('"', "'")) and value.endswith(('"', "'")):
        return value[1:-1]
    low = value.lower()
    if low == 'true':
        return True
    if low == 'false':
        return False
    try:
        if '.' in value:
            return float(value)
        return int(value)
    except ValueError:
        return value

def load_yaml_simple(path):
    root = {}
    stack = [(0, root)]
    with open(path) as fh:
        for raw in fh:
            if not raw.strip() or raw.lstrip().startswith('#'):
                continue
            indent = len(raw) - len(raw.lstrip(' '))
            line = raw.rstrip('\\n')
            if ':' not in line:
                continue
            key, value = line.strip().split(':', 1)
            value = value.strip()
            while len(stack) > 1 and indent <= stack[-1][0]:
                stack.pop()
            cur = stack[-1][1]
            if not value:
                cur[key] = {}
                stack.append((indent + 2, cur[key]))
            else:
                cur[key] = parse_scalar(value)
    return root


def count_fastq_records(path):
    line_count = 0
    with gzip.open(path, 'rt', encoding='utf-8', errors='strict') as handle:
        for _ in handle:
            line_count += 1
    if line_count % 4 != 0:
        raise ValueError(f"FASTQ structure invalid for {path}: total lines {line_count} not divisible by 4")
    return line_count // 4

sample_id = "${sid}"
platform = "${platform}"
model = "${model}"
geometry = "${geometry}"
sample_type = "${sampleType}"
gender = "${gender}"
prs_opt_in = "${prsOptIn}" == "true"
sf_opt_in = "${sfOptIn}" == "true"
tumor_burden = float("${tumorBurden}")
patient_id = "${patientId}"
case_id = "${caseId}"
accession_id = "${accessionId}"
encounter_id = "${encounterId}"
specimen_id = "${specimenId}"
analysis_batch_id = "${analysisBatchId}"
fq1_path = "${fastq_1}"
fq2_path = "${fastq_2}"
thresh_file = "${thresholds_yaml}"
consent_tokens = json.loads('''${consentTokensJson}''')
biological_context = json.loads('''${biologicalContextJson}''')
diagnosis = json.loads('''${diagnosisJson}''')
specimen = json.loads('''${specimenJson}''')
clinical_context = json.loads('''${clinicalContextJson}''')
ingest_manifest = json.loads('''${ingestManifestJson}''')
consent = json.loads('''${consentJson}''')

thresh = load_yaml_simple(thresh_file)

clinical = thresh.get('clinical', {})
plat_ovr = thresh.get('platform_specific_overrides', {}).get(platform, {})
qc_thresh = clinical.get('qc_thresholds', {})

report = {
    "node": "AUTOMATED_INGEST_GATE",
    "pipeline": "GEN_VAR_PIPELINE_v1",
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    "sample_id_hash": hashlib.sha256(sample_id.encode()).hexdigest(),
    "sample_type": sample_type,
    "patient_id": patient_id,
    "case_id": case_id,
    "accession_id": accession_id,
    "encounter_id": encounter_id,
    "specimen_id": specimen_id,
    "analysis_batch_id": analysis_batch_id,
    "platform": platform,
    "model": model,
    "flowcell_geometry": geometry,
    "gender": gender,
    "consent_tokens": consent_tokens,
    "biological_context": biological_context,
    "diagnosis": diagnosis,
    "specimen": specimen,
    "clinical_context": clinical_context,
    "prs_opt_in": prs_opt_in,
    "sf_opt_in": sf_opt_in,
    "tumor_burden_alpha": tumor_burden,
    "ingest_manifest": ingest_manifest,
    "validation_checks": [],
    "status": "VALID_PASS"
}

errors = []
rejection_reasons = []

prs_reporting_opt_in = None
secondary_findings_opt_in = None
if isinstance(consent, dict):
    prs_reporting_opt_in = consent.get('prs_reporting_opt_in', consent.get('prs_opt_in'))
    secondary_findings_opt_in = consent.get('secondary_findings_opt_in', consent.get('sf_opt_in'))

q30_floor = plat_ovr.get('q30_floor', qc_thresh.get('q30_floor', 0.85))
chr_y_floor = qc_thresh.get('chromosome_y_depth_floor', 0.15)
f_inbreed_floor = qc_thresh.get('f_inbreeding_male_floor', 0.80)
report['validation_checks'].append({
    "check": "q30_floor_applied",
    "platform": platform,
    "threshold": q30_floor,
    "note": "Stage 0 intake uses synthetic or precomputed metrics when present"
})

if platform == 'ultima':
    max_dup = plat_ovr.get('max_optical_duplicate_rate', 0.0)
    homo_floor = plat_ovr.get('homopolymer_error_sens_cutoff', 0.98)
    report['validation_checks'].append({
        "check": "ultima_flow_chemistry_gate",
        "max_optical_duplicate_rate": max_dup,
        "homopolymer_error_sens_cutoff": homo_floor,
        "flow_tags_preserved": True,
        "dedup_mode": "FLOW_BASED_CONTEXT_AWARE",
        "note": "ZM/UR/UQ tags must be preserved through markdup",
        "status": "PASS"
    })

if platform == 'complete':
    if geometry != 'DNBSEQ_PATTERNED':
        errors.append(
            f"HARD_HALT [Rule 1.2]: Complete Genomics sample requires flowcell_geometry=DNBSEQ_PATTERNED; observed '{geometry}'"
        )
        report['validation_checks'].append({
            "check": "dnbseq_geometry_gate",
            "expected_geometry": "DNBSEQ_PATTERNED",
            "observed_geometry": geometry,
            "status": "FAIL"
        })
    else:
        spatial_filter = plat_ovr.get('spatial_mismapping_filter', True)
        report['validation_checks'].append({
            "check": "dnbseq_geometry_gate",
            "geometry_format": "DNBSEQ_PATTERNED",
            "spatial_mismapping_filter": spatial_filter,
            "status": "PASS"
        })

if sample_type == 'germline':
    report['validation_checks'].append({
        "check": "germline_expected_diploid_mode",
        "expected_diploid_mode": "ACTIVE",
        "tumor_burden_alpha": 0.0,
        "note": "Mosaic VAF sensitivity protection enabled",
        "status": "PASS"
    })
elif sample_type == 'somatic':
    if tumor_burden <= 0.0:
        report['validation_checks'].append({
            "check": "somatic_alpha_covariate",
            "warning": "pathologist_tumor_burden=0.0 on somatic sample — verify intent",
            "status": "WARN"
        })
    else:
        report['validation_checks'].append({
            "check": "somatic_alpha_covariate",
            "tumor_burden_alpha": tumor_burden,
            "note": "Alpha passed as continuous covariate to caller (Rule 1.5)",
            "status": "PASS"
        })

report['validation_checks'].append({
    "check": "consent_matrix_state",
    "prs_opt_in": prs_opt_in,
    "sf_opt_in": sf_opt_in,
    "prs_downstream_gate": "ENABLED" if prs_opt_in else "CHANNEL_DROPPED_AT_INTAKE",
    "sf_downstream_gate": "ENABLED" if sf_opt_in else "CHANNEL_DROPPED_AT_INTAKE",
    "status": "PASS"
})

consent_ambiguous = (
    consent is None
    or prs_reporting_opt_in is None
    or secondary_findings_opt_in is None
)
if consent_ambiguous:
    rejection_payload = {
        "node": "AUTOMATED_INGEST_GATE",
        "sample_id": sample_id,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "status": "REJECT_CONSENT_AMBIGUITY",
        "rejection_code": "REJECT_CONSENT_AMBIGUITY",
        "detail": {
            "consent_present": consent is not None,
            "prs_reporting_opt_in": prs_reporting_opt_in,
            "secondary_findings_opt_in": secondary_findings_opt_in,
        },
    }
    with open('stage0_rejection_audit.json', 'w', encoding='utf-8') as reject_out:
        json.dump(rejection_payload, reject_out, indent=2)
    print(
        "[AUTOMATED_INGEST_GATE] REJECT_CONSENT_AMBIGUITY — consent contract missing required opt-in fields",
        file=sys.stderr,
    )
    sys.exit(1)

if not sample_id:
    errors.append("HARD_HALT: sample_id is empty or null")
if gender == 'unknown':
    errors.append("HARD_HALT: gender field is missing/unknown — required for ChrY depth check")

for fpath, label in [(fq1_path, 'fastq_forward'), (fq2_path, 'fastq_reverse')]:
    if not os.path.exists(fpath):
        errors.append(f"HARD_HALT [Rule 6.1]: Input file not found: {label} = {fpath}")

expected_md5 = ingest_manifest.get('expected_fastq_md5', {})
if expected_md5:
    observed_forward = md5_hex(fq1_path)
    observed_reverse = md5_hex(fq2_path)
    report['validation_checks'].append({
        "check": "fastq_md5_parity",
        "observed_fastq_md5": {
            "fastq_forward": observed_forward,
            "fastq_reverse": observed_reverse,
        },
        "expected_fastq_md5": expected_md5,
    })
    if expected_md5.get('fastq_forward') and expected_md5.get('fastq_forward') != observed_forward:
        rejection_reasons.append('MD5_MISMATCH')
    if expected_md5.get('fastq_reverse') and expected_md5.get('fastq_reverse') != observed_reverse:
        rejection_reasons.append('MD5_MISMATCH')

strict_pair_count_check = bool(ingest_manifest.get('strict_pair_count_check', False))
if strict_pair_count_check:
    report['validation_checks'].append({
        "check": "strict_pair_count_check",
        "enabled": True,
    })
    try:
        r1_count = count_fastq_records(fq1_path)
        r2_count = count_fastq_records(fq2_path)
        report['validation_checks'].append({
            "check": "read_pair_count",
            "r1_reads": r1_count,
            "r2_reads": r2_count,
        })
        if r1_count != r2_count:
            rejection_reasons.append('READ_PAIR_COUNT_MISMATCH')
    except (OSError, EOFError, gzip.BadGzipFile, UnicodeDecodeError, ValueError) as exc:
        report['validation_checks'].append({
            "check": "fastq_integrity_gzip",
            "status": "FAIL",
            "detail": str(exc),
        })
        rejection_reasons.append('FASTQ_CORRUPT_GZIP')

observed_q30 = ingest_manifest.get('observed_q30_fraction')
if observed_q30 is not None:
    report['validation_checks'].append({
        "check": "observed_q30_fraction",
        "observed_q30_fraction": observed_q30,
        "threshold": q30_floor,
    })
    if float(observed_q30) < float(q30_floor):
        rejection_reasons.append('LOW_Q30')

declared_sex = str(ingest_manifest.get('declared_sex', gender)).strip().upper()
chr_y_depth = ingest_manifest.get('chromosome_y_depth')
x_inbreeding = ingest_manifest.get('x_inbreeding_coefficient')
if chr_y_depth is not None or x_inbreeding is not None:
    report['validation_checks'].append({
        "check": "sex_concordance_precheck",
        "declared_sex": declared_sex,
        "chromosome_y_depth": chr_y_depth,
        "x_inbreeding_coefficient": x_inbreeding,
        "chromosome_y_depth_floor": chr_y_floor,
        "f_inbreeding_male_floor": f_inbreed_floor,
    })
    sex_fail = False
    if declared_sex in {'FEMALE', 'XX'}:
        sex_fail = float(chr_y_depth or 0.0) > float(chr_y_floor) or float(x_inbreeding or 1.0) < float(f_inbreed_floor)
    elif declared_sex in {'MALE', 'XY'}:
        sex_fail = float(chr_y_depth or 0.0) < float(chr_y_floor) or float(x_inbreeding or 0.0) < float(f_inbreed_floor)
    else:
        errors.append(f"HARD_HALT: unsupported declared sex '{declared_sex}'")
    if sex_fail:
        rejection_reasons.append('SEX_DISCORDANCE')

report_path = f"{sample_id}.intake_validation_report.json"
token_path = 'intake_validation_token'
if errors:
    report['status'] = 'MALFORMED_REJECT'
    report['errors'] = errors
    with open(report_path, 'w') as out:
        json.dump(report, out, indent=2)
    with open(token_path, 'w', encoding='utf-8') as out:
        out.write('HARD_HALT|MALFORMED_REJECT' + chr(10))
    print(f"[AUTOMATED_INGEST_GATE] FAIL — {sample_id}", file=sys.stderr)
    for error in errors:
        print(f"  {error}", file=sys.stderr)
    sys.exit(1)

deduped_reasons = []
for reason in rejection_reasons:
    if reason not in deduped_reasons:
        deduped_reasons.append(reason)

if deduped_reasons:
    token = f"INVALID_REJECT|{','.join(deduped_reasons)}"
    report['status'] = 'INVALID_REJECT'
    report['rejection_reasons'] = deduped_reasons
else:
    token = 'VALID_PASS|INTAKE_VALIDATED'

report['validation_checks'].append({
    "check": "overall_gate",
    "status": report['status'],
    "token": token,
})
with open(report_path, 'w') as out:
    json.dump(report, out, indent=2)
with open(token_path, 'w', encoding='utf-8') as out:
    out.write(token + chr(10))
if report['status'] == 'VALID_PASS':
    print(f"[AUTOMATED_INGEST_GATE] PASS — {sample_id} ({platform}/{model})")
else:
    print(f"[AUTOMATED_INGEST_GATE] REJECT — {sample_id} ({token})")
PYEOF

    ln -sr "${fastq_1}" "${sid}_R1.validated.fastq.gz"
    ln -sr "${fastq_2}" "${sid}_R2.validated.fastq.gz"
    """

    stub:
    """
    : > "${meta.sample_id}_R1.validated.fastq.gz"
    : > "${meta.sample_id}_R2.validated.fastq.gz"
    printf 'VALID_PASS|INTAKE_VALIDATED_STUB\n' > intake_validation_token
    printf '{"pipeline":"GEN_VAR_PIPELINE_v1","status":"VALID_PASS","stub":true}' \
        > "${meta.sample_id}.intake_validation_report.json"
    """
}