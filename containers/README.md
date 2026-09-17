# Containers

This directory is the authoritative container build root for nf_Gen_Var_Pipe.

Images:
- `genvar-core:2.1.0`: Stages 0 through 4.
- `genvar-annotation:2.1.0`: Stage 5 annotation and PGx triage.
- `genvar-reporting:2.1.0`: Stage 6 reporting and workbench.

Current state:

- The reporting image now supports Stage 6 signature verification, manifest assembly, and checksum finalization.
- The annotation image continues to supply the signed Stage 5 bundle consumed by Stage 6.
- The core image remains the governed runtime for the Stage 0-4 analytical path.

Build policy:
- No placeholder binaries are embedded in production images.
- `genvar-core` is built from an official pinned elPrep release tarball by the build script, unless `--elprep-bin` overrides it.
- `genvar-annotation` requires a real PharmCAT JAR sourced from `control_plane/references.yaml`.
- `genvar-reporting` has no proprietary binary dependency.
- Optional SIF generation uses `apptainer` or `singularity` against the local Docker daemon images.

Examples:
```bash
containers/build_containers.sh --references control_plane/references.yaml --build-sif
```

```bash
containers/build_containers.sh --targets core --build-sif
```

```bash
containers/build_containers.sh --targets reporting --build-sif
```

The build script pins the official elPrep release URL and SHA-256 internally. Builders should confirm that the pinned source remains valid before refreshing the version. The governed PharmCAT asset key remains `container_assets.pharmcat_jar` in `control_plane/references.yaml`.

After building, update `control_plane/infrastructure.yaml` digests from the built image IDs before governed runs.
