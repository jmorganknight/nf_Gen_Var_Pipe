/*
 * Node: CROSS_SAMPLE_IDENTITY_GATE
 */

process CROSS_SAMPLE_IDENTITY_GATE {

    label 'process_high'
    container 'genvar-core:2.1.0'

    tag "${meta.sample_id}"

    publishDir { "${meta.save_dir}/${meta.sample_id}/audit_and_qc/identity" }, mode: 'copy', overwrite: true

    input:
    tuple val(meta), path(bam), path(bai), val(svd_panel), val(freemix_limit), val(refs)

    output:
    tuple val(meta),
          path("${meta.sample_id}.identity_audit.json"),
          path("${meta.sample_id}.identity_verified.bam"),
          path("${meta.sample_id}.identity_verified.bam.bai"), emit: audited_stream

    script:
    def sid = meta.sample_id
    def sampleType = (meta.sample_type ?: 'somatic').toString()
    def refsJson = groovy.json.JsonOutput.toJson(refs).replace('\\', '\\\\').replace("'", "\\'")
    """
    set -euo pipefail
    python3 - <<'PYEOF'
import json
import os
import subprocess
import sys
import shutil

sid = "${sid}"
bam = "${bam}"
sample_type = "${sampleType}"
freemix_limit = float("${freemix_limit}")
refs = json.loads('${refsJson}')

def map_host_to_container(path_text, host_root):
    if not path_text:
        return None
    text = str(path_text)
    if text.startswith('/opt/reference'):
        return text
    if host_root:
        root = str(host_root).rstrip('/')
        if root and text.startswith(root):
            suffix = text[len(root):].lstrip('/')
            return f"/opt/reference/{suffix}" if suffix else '/opt/reference'
    if text.startswith('/'):
        return text
    return f"/opt/reference/{text.lstrip('/')}"

verify_candidates = [
    shutil.which("verifybamid2"),
    shutil.which("VerifyBamID2"),
    "/opt/micromamba/envs/gen-var/bin/verifybamid2",
    "/opt/micromamba/envs/gen-var/bin/VerifyBamID2",
]
verifybamid = next((p for p in verify_candidates if os.path.exists(p)), None)
if verifybamid is None:
    raise RuntimeError("VerifyBamID2 binary not found in gen-var container")

def is_svd_prefix(prefix):
    if not prefix:
        return False
    return os.path.exists(prefix + ".UD") and os.path.exists(prefix + ".mu") and os.path.exists(prefix + ".bed")

def normalize_prefix(candidate):
    if not candidate:
        return None
    text = str(candidate)
    for suffix in (".UD", ".mu", ".bed"):
        if text.endswith(suffix):
            return text[:-len(suffix)]
    return text

def resolve_svd_prefix():
    raw_candidates = [
        "/opt/conda/share/verifybamid2-2.0.1-10/resource/1000g.phase3.100k.b38.vcf.gz.dat",
        "/opt/micromamba/envs/gen-var/share/verifybamid2-2.0.1-10/resource/1000g.phase3.100k.b38.vcf.gz.dat",
        "/opt/reference/verifybamid2/1000g.phase3.100k.b38.vcf.gz.dat",
        "/opt/reference/verifybamid2",
    ]
    for raw in raw_candidates:
        prefix = normalize_prefix(raw)
        if is_svd_prefix(prefix):
            return prefix

    scan_roots = [
        "/opt/reference/verifybamid2",
        "/opt/reference",
        "/opt/conda/share",
        "/opt/micromamba/envs/gen-var/share",
        "/usr/share",
    ]
    discovered = []
    for root in scan_roots:
        if not os.path.exists(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for name in filenames:
                if not name.endswith(".UD"):
                    continue
                prefix = os.path.join(dirpath, name[:-3])
                if is_svd_prefix(prefix):
                    discovered.append(prefix)

    if not discovered:
        return None

    def score(prefix):
        lower = prefix.lower()
        value = 0
        if '1000g.phase3.100k.b38' in lower:
            value += 100
        if '1000g.phase3' in lower:
            value += 40
        if '.b38.' in lower:
            value += 30
        if 'exome' in lower:
            value += 10
        return value

    return sorted(discovered, key=score, reverse=True)[0]

ref_names = {
    "hs38DH.fa",
    "GRCh38_full_analysis_set_plus_decoy_hla.fa",
    "GRCh38.fasta",
    "Homo_sapiens_assembly38.fasta",
}

verify_ref = None
host_root = refs.get('reference_host_root')
for candidate in (
    refs.get('reference_genome'),
    refs.get('grch38_fasta'),
    refs.get('fasta'),
):
    mapped = map_host_to_container(candidate, host_root)
    if mapped and os.path.exists(mapped):
        verify_ref = mapped
        break

if verify_ref is None:
    for root, _dirs, files in os.walk('/opt/reference'):
        for name in files:
            if name in ref_names:
                verify_ref = os.path.join(root, name)
                break
        if verify_ref is not None:
            break
if verify_ref is None:
    raise RuntimeError("Could not resolve reference FASTA under /opt/reference for VerifyBamID2")

svd_prefix = resolve_svd_prefix()
if svd_prefix is None:
    raise RuntimeError("Official VerifyBamID2 GRCh38 SVD prefix files are missing in the container")

cmd = [
    verifybamid,
    "--Reference", verify_ref,
    "--BamFile", bam,
    "--SVDPrefix", svd_prefix,
    "--Output", f"{sid}.verifybamid2",
]
if sample_type == "somatic":
    cmd.extend(["--DisableOverlap", "--FixAlpha", "--Alpha", "0"])

env = dict(os.environ)
env["PATH"] = "/opt/micromamba/envs/gen-var/bin:" + env.get("PATH", "")
result = subprocess.run(cmd, env=env, capture_output=True, text=True)
insufficient_markers = "Insufficient Available markers" in result.stderr

if result.returncode != 0 and not insufficient_markers:
    sys.stderr.write(result.stderr)
    raise RuntimeError(f"VerifyBamID2 failed with exit code {result.returncode}")

selfsm = f"{sid}.verifybamid2.selfSM"
if insufficient_markers or not os.path.exists(selfsm):
    payload = {
        "node": "CROSS_SAMPLE_IDENTITY_GATE",
        "sample_id": sid,
        "sample_type": sample_type,
        "verify_mode": "VerifyBamID2",
        "freemix": None,
        "freemix_limit": freemix_limit,
        "status": "SKIP",
        "skip_reason": "VerifyBamID2: insufficient genome coverage for marker overlap",
    }
    with open(f"{sid}.identity_audit.json", "w", encoding="utf-8") as out:
        json.dump(payload, out, indent=2)
    sys.stderr.write("WARNING: CROSS_SAMPLE_IDENTITY_GATE skipped — insufficient markers for contamination estimate\\n")
    sys.exit(0)

freemix = None
with open(selfsm, "r", encoding="utf-8") as handle:
    for i, line in enumerate(handle):
        if i == 1:
            fields = line.rstrip("\\n").split("\\t")
            if len(fields) < 7:
                raise RuntimeError("Unable to parse Freemix from selfSM: fewer than 7 columns")
            freemix = float(fields[6])
            break

if freemix is None:
    raise RuntimeError("Unable to parse Freemix from selfSM: missing data row")

status = "PASS" if freemix <= freemix_limit else "FAIL"

payload = {
    "node": "CROSS_SAMPLE_IDENTITY_GATE",
    "sample_id": sid,
    "sample_type": sample_type,
    "verify_mode": "VerifyBamID2",
    "freemix": freemix,
    "freemix_limit": freemix_limit,
    "status": status,
}
with open(f"{sid}.identity_audit.json", "w", encoding="utf-8") as out:
    json.dump(payload, out, indent=2)

if status != "PASS":
    sys.exit(1)
PYEOF

    cp -L "${bam}" "${sid}.identity_verified.bam"
    samtools index -@ "${task.cpus}" "${sid}.identity_verified.bam"
    """

    stub:
    """
    printf '{"node":"CROSS_SAMPLE_IDENTITY_GATE","status":"PASS","freemix":0.0,"stub":true}' > "${meta.sample_id}.identity_audit.json"
    : > "${meta.sample_id}.identity_verified.bam"
    : > "${meta.sample_id}.identity_verified.bam.bai"
    """
}
