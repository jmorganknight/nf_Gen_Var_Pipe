#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE5_DIR="${REPO_ROOT}"
STUB_MANIFEST="${STAGE5_DIR}/tests/inputs/hg002_stub/stub_input/samples_hg002_banked_stage4_stub.yaml"
THRESHOLDS="${STAGE5_DIR}/../control_plane/thresholds.yaml"
REFERENCES="${STAGE5_DIR}/../control_plane/references.yaml"
CONTAINER_DIGEST='sha256:1234abcd'
ARTIFACT_ROOT="${STAGE5_DIR}/tests/fmea_artifacts"
FMEA_DIR=''
FMEA_RUN_UTC=''
FMEA_RUN_ID=''
FMEA_SCRIPT_SHA256=''

cleanup_fmea_dir() {
    if [[ "${FMEA_CLEANUP_ON_EXIT:-0}" != '1' ]]; then
        return 0
    fi
    if [[ -n "${FMEA_DIR:-}" && -d "${FMEA_DIR}" ]]; then
        rm -rf "${FMEA_DIR}"
    fi
}

slugify() {
    local raw="$1"
    local slug
    slug="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
    if [[ -z "${slug}" ]]; then
        slug='fmea_test'
    fi
    printf '%s' "${slug}"
}

extract_primary_fatal() {
    local src_file="$1"
    if [[ ! -f "${src_file}" ]]; then
        return 0
    fi
    grep -Eo 'STAGE5_[A-Z_]+_FATAL:[^[:cntrl:]]*' "${src_file}" | head -n 1 || true
}

write_artifact_manifest() {
    local root_dir="$1"
    local manifest_file="${root_dir}/SHA256SUMS.txt"
    local meta_file="${root_dir}/RUN_METADATA.txt"

    {
        echo "run_id=${FMEA_RUN_ID}"
        echo "run_timestamp_utc=${FMEA_RUN_UTC}"
        echo "artifact_root=${root_dir}"
        echo "script_path=${SCRIPT_DIR}/run_fmea_validation.sh"
        echo "script_sha256=${FMEA_SCRIPT_SHA256}"
        echo "container_digest=${CONTAINER_DIGEST}"
        echo "thresholds_path=${THRESHOLDS}"
        echo "references_path=${REFERENCES}"
    } >"${meta_file}"

    (
        cd "${root_dir}"
        find . -type f \
            ! -name 'SHA256SUMS.txt' \
            -print0 | sort -z | xargs -0 sha256sum
    ) >"${manifest_file}"

    chmod a-w "${meta_file}" "${manifest_file}" || true
}

run_fmea_test() {
    local test_name="$1"
    local nf_command="$2"
    local expected_error="$3"
    local test_slug
    test_slug="$(slugify "${test_name}")"
    local work_dir
    work_dir="$(mktemp -d -p "${FMEA_DIR}" "${test_slug}.XXXX")"
    local stdout_log="${work_dir}/stdout.log"
    local nf_log="${work_dir}/nextflow.log"
    local report_file="${work_dir}/report.txt"

    # Ensure each test run gets a fresh workflow log, then persist a per-test copy.
    rm -f "${STAGE5_DIR}/.nextflow.log" "${STAGE5_DIR}/.nextflow.log."*

    echo "[INFO] ${test_name}"

    set +e
    (
        cd "${STAGE5_DIR}"
        bash -lc "${nf_command}"
    ) >"${stdout_log}" 2>&1
    local exit_code=$?
    set -e

    if [[ -f "${STAGE5_DIR}/.nextflow.log" ]]; then
        cp "${STAGE5_DIR}/.nextflow.log" "${nf_log}"
    fi

    local expected_found='false'
    if grep -qF "${expected_error}" "${stdout_log}" || [[ -f "${nf_log}" && $(grep -cF "${expected_error}" "${nf_log}" || true) -gt 0 ]]; then
        expected_found='true'
    fi

    local primary_fatal=''
    primary_fatal="$(extract_primary_fatal "${stdout_log}")"
    if [[ -z "${primary_fatal}" ]]; then
        primary_fatal="$(extract_primary_fatal "${nf_log}")"
    fi

    {
        echo "test_name=${test_name}"
        echo "expected_error=${expected_error}"
        echo "exit_code=${exit_code}"
        echo "expected_found=${expected_found}"
        echo "primary_fatal=${primary_fatal}"
        echo "stdout_log=${stdout_log}"
        echo "nextflow_log=${nf_log}"
        echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"${report_file}"

    if [[ ${exit_code} -eq 0 ]]; then
        echo "[FAIL] ${test_name}: pipeline unexpectedly succeeded"
        echo "Artifact report: ${report_file}"
        cat "${stdout_log}"
        return 1
    fi

    if [[ "${expected_found}" == 'true' ]]; then
        echo "[PASS] ${test_name}"
        echo "Artifact report: ${report_file}"
        return 0
    fi

    echo "[FAIL] ${test_name}: failed, but not for the expected reason"
    echo "Expected error: ${expected_error}"
    if [[ -n "${primary_fatal}" ]]; then
        echo "Observed primary fatal: ${primary_fatal}"
    else
        echo "Observed primary fatal: <none detected>"
    fi
    echo "Artifact report: ${report_file}"
    echo "--- stdout/stderr ---"
    cat "${stdout_log}"
    if [[ -f "${nf_log}" ]]; then
        echo "--- nextflow.log tail ---"
        tail -n 80 "${nf_log}"
    fi
    return 1
}

make_missing_prs_references() {
    local out_path="$1"
    cat >"${out_path}" <<EOF
ref_data_root: "/media/jmk/Extreme Pro/pipeline_references"
references:
  sf:
    acmg_registry_json: "clinical/acmg/schema.json"
  somatic:
    hotspots_bed: "beds/somatic_hotspots_v2.1.bed_hs38DH"
EOF
}

make_missing_germline_thresholds() {
    local out_path="$1"
    cat >"${out_path}" <<EOF
clinical:
  germline:
    conflict_dampening_factor: 0.35
EOF
}

make_germline_only_manifest() {
    local out_path="$1"
    cat >"${out_path}" <<EOF
samples:
  - sample_id: "HG002_STUB"
    validation_token: "VALID_PASS|VARIANTS_HARMONIZED"
    intake_validation_token: "tests/inputs/hg002_stub/stub_assets/intake.token"
    phased_vcf: "tests/inputs/hg002_stub/stub_assets/stub.vcf"
    phased_vcf_tbi: "tests/inputs/hg002_stub/stub_assets/stub.vcf.tbi"
    ancestry_metrics_json: "tests/inputs/hg002_stub/stub_assets/stub.ancestry_metrics.json"
    phasing_audit_json: "tests/inputs/hg002_stub/stub_assets/stub.phasing_audit.json"
    requested_branches: ["germline"]
EOF
}

make_invalid_intake_manifest() {
    local out_path="$1"
    cat >"${out_path}" <<EOF
samples:
  - sample_id: "HG002_STUB"
    validation_token: "VALID_PASS|VARIANTS_HARMONIZED"
    intake_validation_token: "BROKEN_STAGE0_TOKEN_NAMESPACE"
    phased_vcf: "tests/inputs/hg002_stub/stub_assets/stub.vcf"
    phased_vcf_tbi: "tests/inputs/hg002_stub/stub_assets/stub.vcf.tbi"
    ancestry_metrics_json: "tests/inputs/hg002_stub/stub_assets/stub.ancestry_metrics.json"
    phasing_audit_json: "tests/inputs/hg002_stub/stub_assets/stub.phasing_audit.json"
    requested_branches: ["germline", "pgx", "prs", "sf", "somatic"]
EOF
}

main() {
    mkdir -p "${ARTIFACT_ROOT}"
    FMEA_RUN_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    FMEA_RUN_ID="run_$(date -u +%Y%m%dT%H%M%SZ)_$$"
    FMEA_SCRIPT_SHA256="$(sha256sum "${SCRIPT_DIR}/run_fmea_validation.sh" | awk '{print $1}')"
    FMEA_DIR="$(mktemp -d -p "${ARTIFACT_ROOT}" "${FMEA_RUN_ID}_XXXX")"
    trap cleanup_fmea_dir EXIT

    local missing_refs_yaml="${FMEA_DIR}/missing_prs_references.yaml"
    local missing_thresholds_yaml="${FMEA_DIR}/missing_germline_thresholds.yaml"
    local germline_only_manifest_yaml="${FMEA_DIR}/germline_only_manifest.yaml"
    local invalid_intake_yaml="${FMEA_DIR}/invalid_intake_manifest.yaml"

    local failures=0

    make_missing_prs_references "${missing_refs_yaml}"
    make_missing_germline_thresholds "${missing_thresholds_yaml}"
    make_germline_only_manifest "${germline_only_manifest_yaml}"
    make_invalid_intake_manifest "${invalid_intake_yaml}"

    run_fmea_test \
        "Missing Reference Gate" \
        "nextflow -q run main.nf -stub-run --input '${STUB_MANIFEST}' --references '${missing_refs_yaml}' --thresholds '${THRESHOLDS}' --container_digest '${CONTAINER_DIGEST}'" \
        "STAGE5_REFERENCE_FATAL" || failures=$((failures + 1))

    run_fmea_test \
        "Missing Governance Thresholds" \
        "nextflow -q run main.nf -stub-run --input '${germline_only_manifest_yaml}' --references '${REFERENCES}' --thresholds '${missing_thresholds_yaml}' --container_digest '${CONTAINER_DIGEST}'" \
        "STAGE5_GERMLINE_FATAL" || failures=$((failures + 1))

    run_fmea_test \
        "Invalid Intake Token Namespace" \
        "nextflow -q run main.nf -stub-run --input '${invalid_intake_yaml}' --references '${REFERENCES}' --thresholds '${THRESHOLDS}' --container_digest '${CONTAINER_DIGEST}'" \
        "STAGE5_CHAIN_OF_CUSTODY_FATAL" || failures=$((failures + 1))

    write_artifact_manifest "${FMEA_DIR}"

    echo "[INFO] FMEA artifact root: ${FMEA_DIR}"
    echo "[INFO] FMEA checksum manifest: ${FMEA_DIR}/SHA256SUMS.txt"
    echo "[INFO] FMEA run metadata: ${FMEA_DIR}/RUN_METADATA.txt"
    if [[ ${failures} -gt 0 ]]; then
        echo "[FAIL] FMEA suite completed with ${failures} failing test(s)"
        return 1
    fi
    echo "[PASS] FMEA suite completed: all tests met expected fatal conditions"
}

main "$@"
