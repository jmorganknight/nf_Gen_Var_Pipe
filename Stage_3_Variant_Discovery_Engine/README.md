# Stage 3: Variant Discovery Engine

`Stage_3_Variant_Discovery_Engine` consumes the Stage 2 banked manifest and executes only the variant branches explicitly enabled in the contract.

## Branch toggles

- `snv_indel`
- `structural_variants`
- `copy_number_cnv`
- `str_expansions`
- `trisomy_aneuploidy`
- `homologous_pseudogenes`

## Flow

```mermaid
flowchart TD
    A[Stage 2 banked manifest] --> B[Load contract]
    B --> C{variant_branches}
    C -->|snv_indel| D[SNV/indel branch]
    C -->|structural_variants| E[Structural variant branch]
    C -->|copy_number_cnv| F[CNV branch]
    C -->|str_expansions| G[STR expansion branch]
    C -->|trisomy_aneuploidy| H[Trisomy/aneuploidy branch]
    C -->|homologous_pseudogenes| I[Homologous/pseudogene branch]
    D --> J[VCF harmonization]
    E --> J
    F --> J
    G --> J
    H --> J
    I --> J
    J --> K[Stage 3 banked manifest]
```

## Modules

- `modules/local/load_stage2_contract.nf`
- `modules/local/branch_snv_indel.nf`
- `modules/local/branch_structural_variants.nf`
- `modules/local/branch_copy_number_cnv.nf`
- `modules/local/branch_str_expansions.nf`
- `modules/local/branch_trisomy_aneuploidy.nf`
- `modules/local/assemble_stage3_banked_manifest.nf`

## Output

- `tests/fixtures/banked_stage3/samples_hg002_banked_stage3.yaml`
