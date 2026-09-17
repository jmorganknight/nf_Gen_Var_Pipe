process FHIR_REPORT_BUILDER {

    label 'process_medium'
    container 'genvar-reporting:2.1.0'
    stageInMode 'symlink'

    tag "${meta.sample_id}"

    publishDir "${params.outdir}/reporting", mode: 'copy', overwrite: true, pattern: '*.*'

    input:
    tuple val(meta), path(stage5_manifest), path(clinical_bundle_tar_gz), path(stage5_provenance_json), path(acmg_tiered_variants_json), path(candidate_vus_json), path(vus_queue_json), path(sf_artifact), path(prs_artifact), path(pgx_artifact), val(reference_meta)

    output:
    path "${meta.sample_id}.fhir_genomics_v3.json", emit: fhir_json
    path "${meta.sample_id}.clinical_report.html", emit: html_report
    path "${meta.sample_id}.clinical_report.pdf", emit: pdf_report
    tuple val(meta), path("${meta.sample_id}.provenance_audit.json"), emit: provenance_audit
    tuple val(meta), path("${meta.sample_id}.stage6_report.fragment.json"), emit: fragment

    script:
    def sid = meta.sample_id
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import gzip
import json
import hashlib
from pathlib import Path

sid = '${sid}'
fhir_name = f'{sid}.fhir_genomics_v3.json'
html_name = f'{sid}.clinical_report.html'
pdf_name = f'{sid}.clinical_report.pdf'
provenance_name = f'{sid}.provenance_audit.json'
sink_name = f'{sid}.downgraded_variants_sink.json.gz'
wetlab_name = f'{sid}.wetlab_confirmation_pending_queue.json'
ledger_name = f'{sid}.stage6_variant_ledger.json'
acmg = json.loads(Path('${acmg_tiered_variants_json}').read_text(encoding='utf-8'))
candidate_payload = json.loads(Path('${candidate_vus_json}').read_text(encoding='utf-8'))
queue = json.loads(Path('${vus_queue_json}').read_text(encoding='utf-8'))
sf_payload = json.loads(Path('${sf_artifact}').read_text(encoding='utf-8')) if Path('${sf_artifact}').exists() else {}
prs_payload = json.loads(Path('${prs_artifact}').read_text(encoding='utf-8')) if Path('${prs_artifact}').exists() else {}
pgx_payload = json.loads(Path('${pgx_artifact}').read_text(encoding='utf-8')) if Path('${pgx_artifact}').exists() else {}
stage5_provenance = json.loads(Path('${stage5_provenance_json}').read_text(encoding='utf-8')) if Path('${stage5_provenance_json}').exists() else {}
stage5_signature = stage5_provenance.get('digital_signature', {}) if isinstance(stage5_provenance, dict) else {}

reported = []
for tier_name, tier_rows in (acmg.get('tiers', {}) if isinstance(acmg, dict) else {}).items():
    if isinstance(tier_rows, list):
        reported.extend(tier_rows)

candidate_vus = candidate_payload.get('candidate_vus', []) if isinstance(candidate_payload, dict) else []
section_primary = []
section_vus = []
section_pgx = []
section_sf = []
section_prs = []
section_wetlab = []

pending_variants = []
for tier_name, tier_rows in (acmg.get('tiers', {}) if isinstance(acmg, dict) else {}).items():
    if not isinstance(tier_rows, list):
        continue
    for row in tier_rows:
        if not isinstance(row, dict):
            continue
        if tier_name in ('Tier I', 'Tier II'):
            section_primary.append(row)
        elif tier_name == 'Tier III':
            section_vus.append(row)
        vaf = float(row.get('vaf', 1.0) or 1.0)
        dp = float(row.get('dp', 999.0) or 999.0)
        indel_size = abs(int(row.get('indel_size_bp', row.get('indel_size', 0)) or 0))
        homopolymer = bool(row.get('homopolymer', False))
        phased = row.get('phasing_state', row.get('phase_state', 'PHASED'))
        compound_het = bool(row.get('compound_het', False))
        gene = (row.get('gene') or row.get('symbol') or '').upper()
        pseudogene_region = gene in {'CYP2D6', 'PMS2'} or bool(row.get('pseudogene_region', False))
        reasons = []
        if vaf < 0.20:
            reasons.append('VAF_BELOW_0.20')
        if dp < 30:
            reasons.append('DEPTH_BELOW_30X')
        if indel_size > 15:
            reasons.append('INDEL_EXCEEDS_15_BP')
        if homopolymer:
            reasons.append('HOMOPOLYMER_CONTEXT')
        if compound_het and str(phased).upper() != 'PHASED':
            reasons.append('UNPHASED_COMPOUND_HET')
        if pseudogene_region:
            reasons.append('PSEUDOGENE_REGION')
        if reasons:
            pending_variants.append({'variant': row.get('variant', f"{row.get('chrom','?')}:{row.get('pos','?')}"), 'gene': row.get('gene'), 'reasons': reasons})

if isinstance(pgx_payload, dict):
    for gene, data in (pgx_payload.get('star_alleles', {}) or {}).items():
        if isinstance(data, dict):
            section_pgx.append({'gene': gene, 'diplotype': data.get('diplotype'), 'phenotype': data.get('phenotype')})

if isinstance(sf_payload, dict):
    section_sf = sf_payload.get('findings', []) or []
if isinstance(prs_payload, dict) and prs_payload:
    section_prs = [prs_payload]
section_wetlab = pending_variants

archive = []
for idx, variant in enumerate(candidate_vus):
    if not isinstance(variant, dict):
        archive.append({'variant': str(variant), 'suppression_reason_code': 'UNKNOWN_TRIAGE_RECORD', 'archived_index': idx})
        continue
    maf = float(variant.get('maf', variant.get('population_af', 0.0)) or 0.0)
    if variant.get('off_target', False):
        reason = 'OFF_TARGET_VARIANT'
    elif maf >= 0.01:
        reason = 'HIGH_MAF_BENIGN'
    elif variant.get('suppressed', False):
        reason = variant.get('suppression_reason_code', 'SUPPRESSED_VARIANT')
    elif variant.get('status') == 'DOWNGRADED':
        reason = variant.get('suppression_reason_code', 'DOWNGRADED_VARIANT')
    else:
        reason = 'TRIAGE_ARCHIVE_ONLY'
    archive.append({'variant': variant.get('variant', f'candidate_{idx}'), 'suppression_reason_code': reason, 'maf': maf})

sink_count = len(archive)
pending_payload = {'pending_variants': pending_variants}
signoff_payload = {
    'signoff_status': 'PENDING_DIRECTOR_REVIEW',
    'manual_variant_overrides': [],
    'sanger_confirmation_inputs': [],
    'digital_signatures': [{
        'signature_algorithm': stage5_signature.get('signature_algorithm', 'RS256'),
        'signature_value': stage5_signature.get('signature_value', ''),
        'signer_id': stage5_signature.get('signer_id', ''),
        'public_key_fingerprint': stage5_signature.get('public_key_fingerprint', ''),
    }] if stage5_signature.get('signature_value') else [],
    'approval_digest': stage5_signature.get('signed_digest_sha256', ''),
}

def sha256sum(path_text):
    path = Path(path_text)
    if not path.exists():
        return ''
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

reference_meta_json = json.loads('''${groovy.json.JsonOutput.toJson(reference_meta)}''')
provenance_payload = {
    'node': 'FHIR_REPORT_BUILDER',
    'sample_id': sid,
    'sample_metadata': {
        'validation_token': '${meta.validation_token}',
        'stage6_validation_token': '${meta.validation_token}',
        'save_dir': '${meta.save_dir}',
        'stage5_manifest': '${stage5_manifest}',
        'stage5_bundle': '${clinical_bundle_tar_gz}',
        'stage5_provenance_json': '${stage5_provenance_json}',
    },
    'reference_assets': reference_meta_json,
    'reference_asset_paths': reference_meta_json,
    'target_masks': {
        'sf_bed': {'path': reference_meta_json.get('sf_bed', ''), 'sha256': sha256sum(reference_meta_json.get('sf_bed', ''))},
        'prs_weights': {'path': reference_meta_json.get('prs_weights', ''), 'sha256': sha256sum(reference_meta_json.get('prs_weights', ''))},
        'hotspot_registry': {'path': reference_meta_json.get('hotspot_registry', ''), 'sha256': sha256sum(reference_meta_json.get('hotspot_registry', ''))},
    },
    'pipeline_sinks': {
        'downgraded_variants_sink_json_gz': {'path': sink_name, 'exists': Path(sink_name).exists()},
        'wetlab_confirmation_pending_queue_json': {'path': wetlab_name, 'exists': Path(wetlab_name).exists()},
        'zero_loss_ledger': {'path': ledger_name, 'exists': Path(ledger_name).exists()},
        'consent_bypass_secondary_findings': {'path': '${sf_artifact}', 'exists': Path('${sf_artifact}').exists()},
        'consent_bypass_prs': {'path': '${prs_artifact}', 'exists': Path('${prs_artifact}').exists()},
    },
    'reference_lineage': {
        'clinvar_release': reference_meta_json.get('clinvar_db', ''),
        'gnomad_release': reference_meta_json.get('gnomad_db', ''),
        'vep_cache_dir': reference_meta_json.get('vep_cache_dir', ''),
        'poppca_models': reference_meta_json.get('stage4', {}).get('poppca_refgen_dir', reference_meta_json.get('stage4', {}).get('poppca_models', '')),
        'caller_models': reference_meta_json.get('models', {}),
    },
    'digital_signatures': signoff_payload.get('digital_signatures', []),
}
Path(provenance_name).write_text(json.dumps(provenance_payload, indent=2) + "\\n", encoding='utf-8')

bundle = {
    'resourceType': 'Bundle',
    'type': 'collection',
    'entry': [
        {
            'resource': {
                'resourceType': 'Patient',
                'id': sid,
                'identifier': [{'system': 'urn:stage6:sample-id', 'value': sid}],
            }
        },
        {
            'resource': {
                'resourceType': 'DiagnosticReport',
                'status': 'final' if signoff_payload.get('signoff_status') == 'APPROVED' else 'preliminary',
                'code': {'text': 'Stage 6 Clinical Reporting Workbench Gateway'},
                'subject': {'reference': f'Patient/{sid}'},
                'conclusion': f"Reported={len(reported)} Pending={len(pending_payload.get('pending_variants', []))} Sink={sink_count}",
            }
        },
        {
            'resource': {
                'resourceType': 'Observation',
                'id': f'{sid}-stage6-integrity',
                'status': 'final',
                'code': {'text': 'Variant ledger integrity'},
                'valueString': f"candidate={len(candidate_vus)}; reported={len(reported)}; sink={sink_count}",
            }
        },
        {
            'resource': {
                'resourceType': 'Observation',
                'id': f'{sid}-stage6-wetlab',
                'status': 'final',
                'code': {'text': 'Wetlab confirmation queue'},
                'valueInteger': len(pending_payload.get('pending_variants', [])),
            }
        },
    ],
    'extension': [
        {'url': 'urn:stage6:signoff_status', 'valueString': signoff_payload.get('signoff_status', 'PENDING_DIRECTOR_REVIEW')},
        {'url': 'urn:stage6:manual_variant_overrides', 'valueString': json.dumps(signoff_payload.get('manual_variant_overrides', []))},
        {'url': 'urn:stage6:sanger_inputs', 'valueString': json.dumps(signoff_payload.get('sanger_confirmation_inputs', []))},
        {'url': 'urn:stage6:digital_signatures', 'valueString': json.dumps(signoff_payload.get('digital_signatures', []))},
    ],
}
Path(fhir_name).write_text(json.dumps(bundle, indent=2) + "\\n", encoding='utf-8')

section_cards = []
for title, items, css in [
        ('Section 1: Primary Diagnostic Findings (ACMG Tiers I & II)', section_primary, 'primary_diagnostic'),
        ('Section 2: Candidate VUS & Literature Triage (Tier III + HGMD PMIDs)', section_vus, 'candidate_vus'),
        ('Section 3: Actionable Pharmacogenomics (PGx Diplotypes & Phenotypes)', section_pgx, 'pgx'),
        ('Section 4: Gated Secondary Findings (ACMG v3.2 59 Genes)', section_sf, 'secondary_findings'),
        ('Section 5: Gated Polygenic Risk Scores (PRS Percentiles)', section_prs, 'prs'),
        ('Section 6: Pending Wet-Lab Confirmation Queue (Sanger/MLPA pending list)', section_wetlab, 'wetlab'),
]:
        section_cards.append(f'''
    <section class='card section-{css}'>
        <h2>{title}</h2>
        <pre>{json.dumps(items, indent=2)}</pre>
    </section>
    ''')

html = f'''<!doctype html>
<html lang='en'>
<head>
  <meta charset='utf-8'/>
  <title>Stage 6 Clinical Reporting Workbench Gateway</title>
  <style>
    body {{ font-family: Arial, sans-serif; margin: 2rem; color: #1f2937; }}
    h1, h2 {{ color: #0f172a; }}
    .card {{ border: 1px solid #cbd5e1; border-radius: 12px; padding: 1rem 1.25rem; margin-bottom: 1rem; box-shadow: 0 4px 12px rgba(15, 23, 42, 0.05); }}
    .section-primary_diagnostic {{ border-left: 6px solid #1d4ed8; }}
    .section-candidate_vus {{ border-left: 6px solid #7c3aed; }}
    .section-pgx {{ border-left: 6px solid #0f766e; }}
    .section-secondary_findings {{ border-left: 6px solid #b45309; }}
    .section-prs {{ border-left: 6px solid #be123c; }}
    .section-wetlab {{ border-left: 6px solid #dc2626; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ text-align: left; padding: 0.5rem; border-bottom: 1px solid #e2e8f0; }}
    .pill {{ display: inline-block; padding: 0.2rem 0.6rem; border-radius: 999px; background: #e0f2fe; color: #075985; font-size: 0.85rem; }}
    pre {{ white-space: pre-wrap; background: #f8fafc; border: 1px solid #e2e8f0; padding: 1rem; border-radius: 12px; }}
  </style>
</head>
<body>
  <h1>Stage 6 Clinical Reporting Workbench Gateway</h1>
  <div class='card'>
    <div class='pill'>{signoff_payload.get('signoff_status', 'PENDING_DIRECTOR_REVIEW')}</div>
    <p>Sample: <strong>{sid}</strong></p>
    <p>Reported variants: <strong>{len(reported)}</strong></p>
    <p>Wetlab pending queue: <strong>{len(pending_payload.get('pending_variants', []))}</strong></p>
    <p>Downgraded sink entries: <strong>{sink_count}</strong></p>
  </div>
  <div class='card'>
    <h2>Medical Director Workbench</h2>
    <table>
      <tr><th>Manual overrides</th><td>{json.dumps(signoff_payload.get('manual_variant_overrides', []))}</td></tr>
      <tr><th>Sanger inputs</th><td>{json.dumps(signoff_payload.get('sanger_confirmation_inputs', []))}</td></tr>
      <tr><th>Digital signatures</th><td>{json.dumps(signoff_payload.get('digital_signatures', []))}</td></tr>
      <tr><th>Approval digest</th><td>{signoff_payload.get('approval_digest', '')}</td></tr>
    </table>
  </div>
  <div class='card'>
    <h2>Pending Wet-Lab Queue</h2>
    <pre>{json.dumps(pending_payload, indent=2)}</pre>
  </div>
  <div class='card'>
    <h2>FHIR Bundle</h2>
    <pre>{json.dumps(bundle, indent=2)}</pre>
  </div>
    {''.join(section_cards)}
</body>
</html>
'''
Path(html_name).write_text(html, encoding='utf-8')

# Minimal valid PDF generation without external dependencies.
lines = [
    'Stage 6 Clinical Reporting Workbench Gateway',
    f'Sample: {sid}',
    f'Signoff: {signoff_payload.get("signoff_status", "PENDING_DIRECTOR_REVIEW")}',
    f'Reported variants: {len(reported)}',
    f'Wetlab pending queue: {len(pending_payload.get("pending_variants", []))}',
    f'Downgraded sink entries: {sink_count}',
    'Section 1: Primary Diagnostic Findings (ACMG Tiers I & II)',
    f'  items={len(section_primary)}',
    'Section 2: Candidate VUS & Literature Triage (Tier III + HGMD PMIDs)',
    f'  items={len(section_vus)}',
    'Section 3: Actionable Pharmacogenomics (PGx Diplotypes & Phenotypes)',
    f'  items={len(section_pgx)}',
    'Section 4: Gated Secondary Findings (ACMG v3.2 59 Genes)',
    f'  items={len(section_sf)}',
    'Section 5: Gated Polygenic Risk Scores (PRS Percentiles)',
    f'  items={len(section_prs)}',
    'Section 6: Pending Wet-Lab Confirmation Queue (Sanger/MLPA pending list)',
    f'  items={len(section_wetlab)}',
]
content = ['BT', '/F1 12 Tf', '72 750 Td']
first = True
for line in lines:
    escaped = line
    if first:
        content.append(f'({escaped}) Tj')
        first = False
    else:
        content.append('T*')
        content.append(f'({escaped}) Tj')
content.append('ET')
stream = '\\n'.join(content).encode('utf-8')
objs = []
objs.append(b'1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\\n')
objs.append(b'2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\\n')
objs.append(b'3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >> endobj\\n')
objs.append(b'4 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\\n')
objs.append(b'5 0 obj << /Length ' + str(len(stream)).encode('utf-8') + b' >> stream\\n' + stream + b'\\nendstream endobj\\n')
parts = [b'%PDF-1.4\\n']
offsets = [0]
for obj in objs:
    offsets.append(sum(len(p) for p in parts))
    parts.append(obj)
xref_offset = sum(len(p) for p in parts)
parts.append(f'xref\\n0 {len(objs)+1}\\n'.encode('utf-8'))
parts.append(b'0000000000 65535 f \\n')
for off in offsets[1:]:
    parts.append(f'{off:010d} 00000 n \\n'.encode('utf-8'))
parts.append(b'trailer << /Size 6 /Root 1 0 R >>\\nstartxref\\n')
parts.append(f'{xref_offset}\\n'.encode('utf-8'))
parts.append(b'%%EOF\\n')
Path(pdf_name).write_bytes(b''.join(parts))

fragment = {
    'sample_id': sid,
    'component': 'fhir_report',
    'fhir_json': str(Path(fhir_name).resolve()),
    'html_report': str(Path(html_name).resolve()),
    'pdf_report': str(Path(pdf_name).resolve()),
    'provenance_audit_json': str(Path(provenance_name).resolve()),
    'report_status': 'PRELIMINARY',
    'status': 'PASS',
}
Path(f'{sid}.stage6_report.fragment.json').write_text(json.dumps(fragment, indent=2) + "\\n", encoding='utf-8')
PYEOF
    """

    stub:
    def stubReferenceMetaJson = groovy.json.JsonOutput.toJson(reference_meta).replace('\n', ' ').replace('\r', '')
    """
    python3 - <<'PYEOF'
import json
from pathlib import Path

sid = '${meta.sample_id}'
reference_meta = json.loads('''${stubReferenceMetaJson}''')
fhir_name = f'{sid}.fhir_genomics_v3.json'
html_name = f'{sid}.clinical_report.html'
pdf_name = f'{sid}.clinical_report.pdf'
provenance_name = f'{sid}.provenance_audit.json'
Path(fhir_name).write_text(json.dumps({'resourceType': 'Bundle', 'type': 'collection', 'entry': []}, indent=2) + '\\n', encoding='utf-8')
Path(html_name).write_text('<html><body><h1>Stage 6 Clinical Reporting Workbench Gateway</h1></body></html>\\n', encoding='utf-8')
Path(pdf_name).write_bytes(b'%PDF-1.4\\n%%EOF\\n')
Path(provenance_name).write_text(json.dumps({'sample_id': sid, 'component': 'provenance', 'reference_assets': reference_meta, 'preflight_lock': reference_meta.get('preflight_lock', ''), 'preflight_lock_status': reference_meta.get('preflight_lock_status', ''), 'digital_signatures': [{'signature_algorithm': 'RS256', 'signature_value': 'STUB', 'signer_id': 'clinical_signer', 'public_key_fingerprint': 'STUB'}], 'status': 'PASS'}, indent=2) + '\\n', encoding='utf-8')
Path(f'{sid}.stage6_report.fragment.json').write_text(json.dumps({'sample_id': sid, 'component': 'fhir_report', 'fhir_json': str(Path(fhir_name).resolve()), 'html_report': str(Path(html_name).resolve()), 'pdf_report': str(Path(pdf_name).resolve()), 'provenance_audit_json': str(Path(provenance_name).resolve()), 'report_status': 'PRELIMINARY', 'status': 'PASS'}, indent=2) + '\\n', encoding='utf-8')
PYEOF
    """
}
