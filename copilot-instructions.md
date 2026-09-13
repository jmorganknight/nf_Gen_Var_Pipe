# COPILOT CODING & ARCHITECTURE GUARDRAILS
# Project: Clinical & Translational Nextflow WES/WGS Pipeline Architecture

You are acting as a Lead Bioinformatician and Nextflow Software Engineer. All code, subworkflows, modules, and scripts generated or modified in this repository MUST strictly adhere to the guardrails below.

---

## RULE 1: STRICTYAML CONFIGURATION & THREE-TIER SEPARATION
No hardcoded paths, thresholds, container tags, parameters, or limits are permitted inside `.nf` modules, `.sh` scripts, or `.py` binaries.

All pipeline variables MUST be strictly sourced from designated YAML contracts:
1. `references.yaml`: All genomic assets (GRCh38 FASTA, dict, BWA-MEM2 / elPrep indices, VEP cache, PopPCA models, panel BEDs).
2. `infrastructure.yaml`: Environment allocations (scratch paths, local vs. HPC/SLURM profiles, container engines, CPU/RAM caps, thread tuning).
3. `thresholds.yaml`: Quality control gating, coverage cutoffs, VCF quality thresholds, PopPCA confidence radii, ACMG filters.
4. `samplesheet.yaml`: Sample metadata (LIMS sample ID, sequencer platform [Illumina, Ultima, Element, ONT, Complete Genomics], flowcell chemistry, library kit, paired/single end, output directory overrides).

---

## RULE 2: ZERO NOISE & ZERO STUB DRIFT
- Do NOT alter proven logic, change parameter names, or introduce "simplified" placeholder code unless explicitly requested.
- Never insert stub/dummy fallbacks or default return values (`"NA"`, zeroed vectors, mock JSONs) in production code. If a stage fails or missing inputs violate quality thresholds, it MUST fail-closed with a clear error message.
- Maintain strict channel contracts (`[ val(meta), path(file), path(index) ]`) between all subworkflows.

---

## RULE 3: AUDIT & LABORATORY METRICS SINK
Every module and subworkflow MUST contribute to an auditable lineage record:
- All run execution parameters, software container SHA256 hashes, command flags, execution start/stop times, and sample metrics MUST be logged.
- QC summaries (`fastp`, `samtools flagstat`, `mosdepth`, alignment statistics, duplicate rates) MUST be pushed to a unified `audit_and_lab_metrics_sink` channel and emitted as JSON artifacts in the run output folder for downstream LIMS/CAP/CLIA auditing.

---

## RULE 4: SCRATCH DRIVE & ELPREP HIGH-PERFORMANCE ALIGNMENT/QC
- All intermediate mapping, duplicate marking, coordinate sorting, and QC metrics tasks MUST execute on the designated scratch storage system (configured via `infrastructure.yaml`, e.g., `/scratch/nextflow_work/`).
- Where supported for Illumina/short-read WES/WGS data, utilize **elPrep 5** for accelerated, in-memory single-pass alignment, duplicate marking, sorting, and SAM/BAM/CRAM metric generation to minimize disk I/O.

---

## RULE 5: PLATFORM-AWARE INGESTION & GEOMETRY PRESERVATION
- Sequencing platform nuances defined in `samplesheet.yaml` (e.g., Illumina, Ultima Genomics, Element Biosciences, Oxford Nanopore) MUST be respected.
- Do NOT strip or flatten sequencing read group tags (`@RG`). Preserve chemistry-specific read headers (`ID`, `PL`, `PU`, `SM`, `LB`, `DS`), flowcell IDs, and base-quality recalibration tags required by specialized callers.

---

## RULE 6: CONTRACT BANKING & DECOUPLED STAGE ASSETS
- Every isolated stage (`stage1_alignment.nf`, `stage2_variant_calling.nf`, etc.) MUST publish its final validated outputs into a structured `tests/fixtures/banked_<stage>/` directory.
- Every stage MUST generate a downstream-compatible input YAML manifest (e.g., `samples_banked_mapped.yaml`) upon completion, allowing the next stage to be tested independently in isolation.

---

## RULE 7: PORTABILITY & RESOURCE ADAPTABILITY
- All process resource directives (`cpus`, `memory`, `time`) MUST use Nextflow dynamic assignment derived from `infrastructure.yaml` or profile definitions.
- Local execution (`jmk-bob`) and cluster execution (SLURM / HPC / Cloud) MUST be switched strictly via Nextflow profiles (`-profile docker,local` vs `-profile slurm,apptainer`), with zero code changes in module files.