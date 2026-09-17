# HG002 Mini Control Dataset

This directory contains a governed mini-control dataset used to exercise branch routing and core clinical logic with a compact HG002 read subset.

It now pairs with the unified samples_mini_control.yaml manifest, which uses the canonical schema standard and supports stage-skipping lookahead blocks for manual debugging.

Current state:

- The mini-control dataset is used for local stage smoke tests and branch-routing validation across the full pipeline.
- It remains a compact, governed fixture for reproducing the documented Stage 0-6 execution flow.
- The files here are intentionally small and stable so they can support documentation, testing, and audit examples.

## Files

- `samples_mini_control.yaml`: Unified canonical mini-control manifest for Stage 0-6 debugging.
- `build_mini_control.sh`: Generates the mini-control FASTQ pair from a BAM/CRAM source.
- `mini_control_R1.fastq.gz`: Mini-control R1 FASTQ fixture.
- `mini_control_R2.fastq.gz`: Mini-control R2 FASTQ fixture.

## Source Provenance

Default source (if no local source path is provided) is the public GIAB HG002 aligned BAM:

- `https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x150bps/bwa-mem-0.7.8-illumina-ref_GRCh38-20161213/HG002.GRCh38.2x150.bam`

Expected reference frame:

- Sample: HG002 / NA24385
- Build: GRCh38
- Platform: Illumina 2x150

## Region-to-Branch Mapping

| Interval (GRCh38) | Why Included | Primary Coverage in Pipeline |
|---|---|---|
| `chr20:10,000,000-11,000,000` | Broad SNV/INDEL signal window | Stage 3 SNV/INDEL, Stage 5 VEP path |
| `chr22:42,120,000-42,150,000` | CYP2D6 and paralog-homology stress locus | Stage 3 pseudogene/paralog handling, Stage 5 PGx star-alleles |
| `chr1:97,000,000-98,000,000` | DPYD pharmacogenomic locus | Stage 5 PGx star-allele and gene-rule interpretation |
| `chr13:32,300,000-32,400,000` | BRCA2 ACMG SF locus | Stage 5 ACMG SF73 path and VEP annotation |
| `chr17:43,000,000-44,000,000` | BRCA1 event-rich locus | Stage 3 CNV/SV branches, Stage 5 interpretation carryover |
| `chr4:3,070,000-3,080,000` | HTT ExpansionHunter target | Stage 3 STR expansion branch |

## Build Usage

### Option 1: Default remote GIAB source

```bash
cd assets/mini_control
./build_mini_control.sh
```

### Option 2: Local BAM/CRAM via positional argument

```bash
cd assets/mini_control
./build_mini_control.sh /path/to/HG002.GRCh38.2x150.bam
```

### Option 3: Local BAM/CRAM via environment variable

```bash
cd assets/mini_control
HG002_SOURCE_BAM=/path/to/HG002.GRCh38.2x150.bam ./build_mini_control.sh
```

### Optional CRAM reference hint

If the source is CRAM and your environment requires an explicit reference for decoding:

```bash
HG002_SOURCE_BAM=/path/to/HG002.cram \
HG002_CRAM_REFERENCE=/path/to/GRCh38.fa \
./build_mini_control.sh
```

## Implementation Notes

- The script slices six governed loci using `samtools view`.
- Slices are merged, collated (`samtools collate -u -O`), and converted to paired FASTQ.
- Temporary slice artifacts are cleaned automatically.
- If `samtools` is not on host PATH, the script falls back to Docker (`genvar-core:2.1.0`).
