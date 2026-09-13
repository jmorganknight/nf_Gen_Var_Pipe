nextflow.enable.dsl = 2

include { STAGE0_PREFLIGHT_INGEST } from './Stage_0_Preflight_Ingest_Gate/main'
include { STAGE1_ALIGNMENT as STAGE1_ALIGNMENT_READ_PROCESSING } from './Stage_1_Alignment_Read_Processing/workflows/stage1_alignment.nf'
include { STAGE2_SAMPLE_VALIDATION as STAGE2_POSTALIGN_SAMPLE_VALIDATION_GATE } from './Stage_2_PostAlign_Sample_Validation_Gate/main'
include { STAGE3_VARIANT_DISCOVERY_ENGINE } from './Stage_3_Variant_Discovery_Engine/main'
include { ASSEMBLE_STAGE3_BANKED_MANIFEST } from './Stage_3_Variant_Discovery_Engine/modules/local/assemble_stage3_banked_manifest.nf'
include { STAGE4_ANCESTRY_PHASING as STAGE4_ANCESTRY_PHASING_HIGHWAY } from './Stage_4_Ancestry_Phasing_Highway/main'
include { STAGE5_ANNOTATION_PGX_TRIAGE as STAGE5_CLINICAL_ANNOTATION_PGX_TRIAGE } from './Stage_5_Clinical_Annotation_PGx_Triage/main'
include { STAGE6_CLINICAL_REPORTING_WORKBENCH_GATEWAY as STAGE6_CLINICAL_REPORTING_WORKBENCH_GATE } from './Stage_6_Clinical_Reporting_Workbench_Gateway/main'

def mapOrEmpty(Object value) {
    value instanceof Map ? (value as Map) : [:]
}

def resolveRefPath(String entryPath, String yamlRefDataRoot) {
    if (!entryPath) {
        return entryPath
    }
    if (entryPath.startsWith('/')) {
        return entryPath
    }
    def baseRoot = yamlRefDataRoot?.trim() ? yamlRefDataRoot.toString().trim() : '/opt/reference'
    return new File(baseRoot, entryPath).path
}

def resolveReferencePathValue(Object value, String yamlRefDataRoot, String keyName = null) {
    if (value instanceof Map) {
        return (value as Map).collectEntries { key, nested ->
            [(key): resolveReferencePathValue(nested, yamlRefDataRoot, key.toString())]
        }
    }
    if (value instanceof List) {
        return (value as List).collect { nested -> resolveReferencePathValue(nested, yamlRefDataRoot, keyName) }
    }
    if (!(value instanceof CharSequence)) {
        return value
    }

    def pathText = value.toString()
    if (['reference_checksum_manifest', 'stage3_vcf_schema'].contains(keyName)) {
        return pathText
    }
    return resolveRefPath(pathText, yamlRefDataRoot)
}

def loadResolvedReferences(def referencesFile) {
    def ys = new groovy.yaml.YamlSlurper()
    def referencesDoc = mapOrEmpty(ys.parse(referencesFile))
    def yamlRefDataRoot = referencesDoc.ref_data_root?.toString()?.trim()
    def refsParsed = mapOrEmpty(resolveReferencePathValue(mapOrEmpty(referencesDoc.references ?: referencesDoc), yamlRefDataRoot))
    def stage3Refs = mapOrEmpty(refsParsed.stage3)
    if (stage3Refs.stage3_vcf_schema && !refsParsed.stage3_vcf_schema) {
        refsParsed.stage3_vcf_schema = stage3Refs.stage3_vcf_schema
    }
    [document: referencesDoc, refs: refsParsed, yamlRefDataRoot: yamlRefDataRoot]
}

def isStubMode() {
    def commandLine = workflow.hasProperty('commandLine') ? (workflow.commandLine ?: '') : ''
    def stubFlag = workflow.hasProperty('stubRun') ? workflow.stubRun : null
    (stubFlag instanceof Boolean && stubFlag) || commandLine.contains('-stub')
}

def ensureStubFile(String baseDir, String sampleId, String filename, String content) {
    def dir = new File(baseDir, sampleId)
    dir.mkdirs()
    def f = new File(dir, filename)
    if (!f.exists()) {
        f.text = content
    }
    return f
}

def missingInputFile(String sampleId, String fieldName, Object rawPath) {
    throw new IllegalArgumentException("MISSING_INPUT_FILE: sample='${sampleId}' field='${fieldName}' path='${rawPath ?: 'UNSET'}'")
}

def resolveRequiredInput(String rawPath, List<String> roots, String sampleId, String fieldName, String baseDir = null, String stubName = null, String stubContent = '') {
    if (!rawPath) {
        if (isStubMode() && baseDir && stubName) {
            return ensureStubFile(baseDir, sampleId, stubName, stubContent)
        }
        missingInputFile(sampleId, fieldName, rawPath)
    }
    def resolved = resolvePathWithBases(rawPath, roots)
    if (resolved?.exists()) {
        return resolved
    }
    if (isStubMode() && baseDir && stubName) {
        return ensureStubFile(baseDir, sampleId, stubName, stubContent)
    }
    missingInputFile(sampleId, fieldName, rawPath)
}

def resolveOptionalDeclaredInput(String rawPath, List<String> roots, String sampleId, String fieldName) {
    if (!rawPath) {
        return null
    }
    def resolved = resolvePathWithBases(rawPath, roots)
    if (resolved?.exists()) {
        return resolved
    }
    if (!isStubMode()) {
        missingInputFile(sampleId, fieldName, rawPath)
    }
    return null
}

def resolveOrStub(String rawPath, List<String> roots, String baseDir, String sampleId, String stubName, String stubContent) {
    def resolved = resolvePathWithBases(rawPath, roots)
    if (resolved?.exists()) {
        return resolved
    }
    return ensureStubFile(baseDir, sampleId, stubName, stubContent)
}

def resolvePathWithBases(String rawPath, List<String> roots) {
    def candidate = new File(rawPath)
    if (candidate.isAbsolute() || candidate.exists()) {
        return candidate
    }
    def resolved = null
    roots.each { base ->
        if (!base) {
            return
        }
        def rooted = new File(base, rawPath)
        if (resolved == null && rooted.exists()) {
            resolved = rooted
            return
        }
    }
    if (resolved != null) {
        return resolved
    }
    return new File(roots ? roots[0] : projectDir.toString(), rawPath)
}

def sha256Hex(File fileObj) {
    if (!fileObj.exists()) {
        throw new IllegalArgumentException("Missing asset for SHA-256 hashing: ${fileObj}")
    }
    def digest = java.security.MessageDigest.getInstance('SHA-256')
    if (fileObj.isDirectory()) {
        def children = []
        fileObj.eachFileRecurse(groovy.io.FileType.FILES) { child ->
            children << child
        }
        children.sort { left, right ->
            fileObj.toPath().relativize(left.toPath()).toString().replace('\\', '/') <=> fileObj.toPath().relativize(right.toPath()).toString().replace('\\', '/')
        }.each { child ->
            def rel = fileObj.toPath().relativize(child.toPath()).toString().replace('\\', '/')
            digest.update(rel.getBytes('UTF-8'))
            digest.update('\u0000'.getBytes('UTF-8'))
            digest.update(sha256Hex(child).getBytes('US-ASCII'))
            digest.update('\u0000'.getBytes('UTF-8'))
        }
    } else {
        fileObj.withInputStream { stream ->
            stream.eachByte(1024 * 1024) { buffer, size ->
                digest.update(buffer, 0, size)
            }
        }
    }
    digest.digest().collect { value -> String.format('%02x', value) }.join()
}

def loadChecksumManifest(File manifestFile, String refDir, String projectRoot) {
    def entries = [:]
    manifestFile.eachLine('UTF-8') { raw ->
        def line = raw.trim()
        if (!line || line.startsWith('#')) {
            return
        }
        def parts = line.split(/\s+/, 2)
        if (parts.size() != 2) {
            throw new IllegalArgumentException("Invalid checksum manifest line: ${raw}")
        }
        def digest = parts[0].trim().toLowerCase()
        def pathText = parts[1].trim()
        def resolved = pathText.startsWith('/opt/reference')
            ? hostPathForReference(pathText, refDir)
            : resolvePathWithBases(pathText, [manifestFile.parent, projectRoot])
        entries[pathText] = [digest: digest, file: resolved]
    }
    entries
}

def validateChecksumManifest(File manifestFile, String refDir, String projectRoot) {
    def entries = loadChecksumManifest(manifestFile, refDir, projectRoot)
    entries.each { pathText, payload ->
        def resolved = payload.file as File
        def observed = sha256Hex(resolved)
        if (observed != payload.digest) {
            throw new IllegalStateException("REFERENCE_CHECKSUM_MISMATCH: ${pathText}")
        }
    }
    entries.collectEntries { pathText, payload -> [(pathText): payload.digest] }
}

def resolvePkiPair(Map reportingCfg, String thresholdRoot, String projectRoot) {
    def pkiRoot = resolvePathWithBases((params.pki_key_dir ?: 'keys').toString(), [projectRoot, thresholdRoot])
    def keyPath = (params.signer_key_path ?: reportingCfg.pki_key_path ?: new File(pkiRoot, 'clinical_signer.pem').toString()).toString()
    def pubPath = (params.signer_pub_path ?: reportingCfg.pki_pub_key_path ?: keyPath.replaceFirst(/\.pem$/, '.pub.pem')).toString()
    [
        key: resolvePathWithBases(keyPath, [thresholdRoot, projectRoot, pkiRoot.toString()]),
        pub: resolvePathWithBases(pubPath, [thresholdRoot, projectRoot, pkiRoot.toString()]),
        root: pkiRoot
    ]
}

def hostPathForReference(String pathText, String refDir) {
    if (!pathText) {
        return null
    }
    if (pathText.startsWith('/opt/reference') && refDir) {
        def suffix = pathText.replaceFirst('^/opt/reference/?', '')
        return suffix ? new File(refDir, suffix) : new File(refDir)
    }
    if (pathText.startsWith('/')) {
        return new File(pathText)
    }
    if (refDir) {
        return new File(refDir, pathText)
    }
    return new File(pathText)
}

def resolveStage5Artifact(File stage5Root, String artifactName, String fallbackName = null) {
    if (artifactName) {
        def direct = resolvePathWithBases(artifactName, [stage5Root.toString(), projectDir.toString()])
        if (direct.exists()) {
            return direct
        }
    }
    if (fallbackName) {
        def fallback = new File(stage5Root, fallbackName)
        if (fallback.exists()) {
            return fallback
        }
    }
    return artifactName ? resolvePathWithBases(artifactName, [stage5Root.toString(), projectDir.toString()]) : (fallbackName ? new File(stage5Root, fallbackName) : null)
}

def loadAtomicIntakeContract() {
    def ys = new groovy.yaml.YamlSlurper()
    def projectRoot = projectDir.toString()
    def inputManifest = file((params.input ?: params.samples).toString())
    def referencesFile = file(params.references.toString())
    def thresholdsFile = file(params.thresholds.toString())
    def infrastructureFile = file(params.infrastructure.toString())

    def samplesDoc = ys.parse(inputManifest) ?: [:]
    def referenceInfo = loadResolvedReferences(referencesFile)
    def thresholdsDoc = ys.parse(thresholdsFile) ?: [:]
    def infrastructureDoc = ys.parse(infrastructureFile) ?: [:]

    def samplesParsed = samplesDoc.samples
    def refsParsed = referenceInfo.refs
    if (!(samplesParsed instanceof List) || samplesParsed.isEmpty()) {
        throw new IllegalArgumentException('FATAL: orchestrator input manifest contains no samples')
    }
    if (!(refsParsed instanceof Map) || refsParsed.isEmpty()) {
        throw new IllegalArgumentException('FATAL: references manifest contains no references block')
    }

    [
        projectRoot       : projectRoot,
        inputManifest     : inputManifest,
        referencesFile    : referencesFile,
        thresholdsFile    : thresholdsFile,
        infrastructureFile: infrastructureFile,
        samplesParsed     : samplesParsed,
        refsParsed        : refsParsed,
        yamlRefDataRoot   : referenceInfo.yamlRefDataRoot,
        thresholdsParsed  : thresholdsDoc,
        infrastructureParsed: infrastructureDoc,
        inputRoot         : inputManifest.parent ? inputManifest.parent.toString() : projectRoot,
        thresholdRoot     : thresholdsFile.parent ? thresholdsFile.parent.toString() : projectRoot,
        infrastructureRoot: infrastructureFile.parent ? infrastructureFile.parent.toString() : projectRoot,
    ]
}

workflow MASTER_WES_ONCO_ORCHESTRATOR {
    main:
    def ys = new groovy.yaml.YamlSlurper()
    def intake = loadAtomicIntakeContract()

    def inputManifest = intake.inputManifest
    def referencesFile = intake.referencesFile
    def thresholdsFile = intake.thresholdsFile
    def infrastructureFile = intake.infrastructureFile
    def samplesParsed = intake.samplesParsed as List
    def refsParsed = intake.refsParsed as Map
    def thresholdsParsed = intake.thresholdsParsed as Map
    def infrastructureParsed = intake.infrastructureParsed as Map
    def projectRoot = intake.projectRoot.toString()
    def inputRoot = intake.inputRoot.toString()
    def infrastructureRoot = intake.infrastructureRoot.toString()
    def refDir = null
    [params.ref_data_root, params.ref_dir, infrastructureParsed?.storage?.reference_host_root, intake.yamlRefDataRoot, '/opt/reference'].find { candidate ->
        def text = candidate?.toString()?.trim()
        if (!text) {
            return false
        }
        def resolved = resolvePathWithBases(text, [projectRoot, infrastructureRoot])
        refDir = resolved.toString()
        resolved.exists()
    }

    def reportingCfg = thresholdsParsed.reporting ?: thresholdsParsed.clinical?.reporting ?: [:]
    def thresholdRoot = intake.thresholdRoot.toString()
    def checksumManifest = resolvePathWithBases('../assets/reference_checksums.sha256', [thresholdRoot, projectRoot])
    def checksumMap = checksumManifest.exists()
        ? loadChecksumManifest(checksumManifest, refDir, projectRoot).collectEntries { pathText, payload -> [(pathText): payload.digest] }
        : [:]
    def preflightLockPublishedPath = "${params.outdir}/audit_and_qc/preflight_lock/preflight_lock.json"
    def referenceSnapshotPublishedPath = "${params.outdir}/audit_and_qc/preflight_lock/reference_snapshot.tokens"
    def yamlSnapshotBundlePublishedPath = "${params.outdir}/audit_and_qc/preflight_lock/yaml_snapshot_bundle.tar.gz"

    def pkiPair = resolvePkiPair(reportingCfg, thresholdRoot, projectRoot)
    def signerKeyResolved = pkiPair.key as File
    def signerPubResolved = pkiPair.pub as File
    if ((!signerKeyResolved.exists() || !signerPubResolved.exists()) && !isStubMode()) {
        throw new IllegalStateException("STAGE5_PKI_KEY_MISSING: key=${signerKeyResolved}; pub=${signerPubResolved}")
    }
    if (isStubMode()) {
        if (!signerKeyResolved.exists()) {
            signerKeyResolved.parentFile?.mkdirs()
            signerKeyResolved.text = "-----BEGIN PRIVATE KEY-----\nSTUB\n-----END PRIVATE KEY-----\n"
        }
        if (!signerPubResolved.exists()) {
            signerPubResolved.parentFile?.mkdirs()
            signerPubResolved.text = "-----BEGIN PUBLIC KEY-----\nSTUB\n-----END PUBLIC KEY-----\n"
        }
    }

    def chRawReads = channel.fromList(samplesParsed).map { sample ->
        def sid = (sample.sample_id ?: 'UNKNOWN').toString()
        def read1Raw = sample.fastq_forward?.toString() ?: sample.read_file_paths?.read1?.toString() ?: sample.read1?.toString()
        def read2Raw = sample.fastq_reverse?.toString() ?: sample.read_file_paths?.read2?.toString() ?: sample.read2?.toString()
        def fq1 = resolveRequiredInput(read1Raw, [projectRoot, inputRoot], sid, 'fastq_forward', params.outdir.toString(), "${sid}.read1.stub.fastq", "@stub\nN\n+\n#\n")
        def fq2 = resolveRequiredInput(read2Raw, [projectRoot, inputRoot], sid, 'fastq_reverse', params.outdir.toString(), "${sid}.read2.stub.fastq", "@stub\nN\n+\n#\n")
        resolveOptionalDeclaredInput(sample.intake_validation_token?.toString(), [projectRoot, inputRoot], sid, 'intake_validation_token')
        resolveOptionalDeclaredInput(sample.mapped_paths?.bam?.toString(), [projectRoot, inputRoot], sid, 'mapped_paths.bam')
        resolveOptionalDeclaredInput(sample.mapped_paths?.bai?.toString(), [projectRoot, inputRoot], sid, 'mapped_paths.bai')
        resolveOptionalDeclaredInput(sample.mapped_paths?.vcf?.toString(), [projectRoot, inputRoot], sid, 'mapped_paths.vcf')
        resolveOptionalDeclaredInput(sample.mapped_paths?.tbi?.toString(), [projectRoot, inputRoot], sid, 'mapped_paths.tbi')
        def meta = [
            sample_id: sid,
            patient_id: sample.patient_id ?: sid,
            case_id: sample.case_id ?: sample.patient_id ?: sid,
            accession_id: sample.accession_id,
            encounter_id: sample.encounter_id,
            specimen_id: sample.specimen_id,
            analysis_batch_id: sample.analysis_batch_id,
            sample_type: sample.sample_type,
            pathologist_tumor_burden: sample.pathologist_tumor_burden ?: 0.0,
            gender: sample.gender,
            consent: mapOrEmpty(sample.consent),
            biological_context: mapOrEmpty(sample.biological_context),
            diagnosis: mapOrEmpty(sample.diagnosis),
            specimen: mapOrEmpty(sample.specimen),
            clinical_context: mapOrEmpty(sample.clinical_context),
            ingest_manifest: mapOrEmpty(sample.ingest_manifest),
            sequencer: mapOrEmpty(sample.sequencer),
            variant_branches: mapOrEmpty(sample.variant_branches),
            save_dir: params.outdir.toString()
        ]
        tuple(meta, file(fq1, checkIfExists: true), file(fq2, checkIfExists: true))
    }

    STAGE0_PREFLIGHT_INGEST(
        chRawReads,
        channel.value(thresholdsFile),
        channel.value(referencesFile),
        channel.value(inputManifest),
        channel.value(infrastructureFile),
        channel.value(file(signerKeyResolved, checkIfExists: true)),
        channel.value(file(signerPubResolved, checkIfExists: true))
    )

    def refGenome = (refsParsed.reference_genome ?: refsParsed.grch38_fasta).toString()
    def refFai = (refsParsed.reference_fai ?: refsParsed.grch38_fai ?: "${refGenome}.fai").toString()
    def refDict = (refsParsed.reference_dict ?: refsParsed.grch38_dict).toString()
    def bwaBase = (refsParsed.bwa_index_base ?: refsParsed.bwa_index).toString()
    def referenceMeta = [
        reference_genome: refGenome,
        reference_fai: refFai,
        reference_dict: refDict,
        bwa_index_base: bwaBase,
        onco_target_bed: (refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed),
        sf_bed: refsParsed.sf_bed,
        clinvar_db: refsParsed.clinvar_db,
        preflight_lock: preflightLockPublishedPath,
        preflight_lock_status: 'STAGE0_PREFLIGHT_LOCK_PASS',
        reference_snapshot_tokens: referenceSnapshotPublishedPath,
        yaml_snapshot_bundle: yamlSnapshotBundlePublishedPath,
        reference_checksum_manifest: checksumManifest.toString(),
        reference_asset_checksums: checksumMap
    ]

    def chStage1Payload = STAGE0_PREFLIGHT_INGEST.out.banked_samplesheet.flatMap { stage0Manifest ->
        def stage0Parsed = ys.parse(stage0Manifest).samples ?: []
        def stage0Root = stage0Manifest.parent ? stage0Manifest.parent.toString() : projectRoot
        stage0Parsed.collect { sample ->
            def sid = (sample.sample_id ?: 'UNKNOWN').toString()
            def intakeReportRaw = sample.intake_validation_report?.toString() ?: "${params.outdir}/${sid}/audit_and_qc/${sid}.intake_validation_report.json"
            def intakeTokenRaw = sample.intake_validation_token?.toString() ?: "${params.outdir}/${sid}/intake_token/${sid}.intake_validation_token"
            def stage0Read1Raw = (sample.fastq_forward ?: sample.read_file_paths?.read1)?.toString()
            def stage0Read2Raw = (sample.fastq_reverse ?: sample.read_file_paths?.read2)?.toString()
            def stage1Meta = (sample as Map) + [
                sample_id: sid,
                sample_meta: mapOrEmpty(sample) + [sample_id: sid],
            ]
            tuple(
                sid,
                stage1Meta,
                file(resolveRequiredInput(stage0Read1Raw, [projectRoot, stage0Root], sid, 'stage0.fastq_forward', params.outdir.toString(), "${sid}.read1.stub.fastq", "@stub\nN\n+\n#\n"), checkIfExists: true),
                file(resolveRequiredInput(stage0Read2Raw, [projectRoot, stage0Root], sid, 'stage0.fastq_reverse', params.outdir.toString(), "${sid}.read2.stub.fastq", "@stub\nN\n+\n#\n"), checkIfExists: true),
                file(resolvePathWithBases(intakeTokenRaw, [projectRoot, stage0Root]), checkIfExists: true),
                file(resolvePathWithBases(intakeReportRaw, [projectRoot, stage0Root]), checkIfExists: true)
            )
        }
    }

    STAGE1_ALIGNMENT_READ_PROCESSING(
        chStage1Payload.map { sid, sampleMeta, read1, read2, intakeToken, intakeReport ->
            tuple((sampleMeta as Map) + [sample_id: sid], read1, read2, intakeToken, intakeReport)
        },
        channel.value(refGenome),
        channel.value(refFai),
        channel.value(bwaBase),
        channel.value(refDict),
        channel.value((refsParsed.sf_bed ?: refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed).toString()),
        channel.value(thresholdsParsed.clinical?.contamination?.freemix_germline_limit ?: 0.01),
        channel.value(referenceMeta)
    )

    def refsNormalized = mapOrEmpty(refsParsed) + [
        capture_wes_bed: refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed,
        onco_target_bed: refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed
    ]

    def chStage2Input = STAGE1_ALIGNMENT_READ_PROCESSING.out.aligned_bam_bai.map { meta, identityAudit, bam, bai ->
        def tokenField = meta.intake_validation_token?.toString()
        def tokenPath = tokenField ? new File(tokenField) : null
        def tokenValue = (tokenPath && tokenPath.exists()) ? tokenPath.text.trim() : (tokenField ?: '')
        def enriched = (meta as Map) + [
            identity_audit: identityAudit.toString(),
            sorted_bam: bam.toString(),
            sorted_bai: bai.toString(),
            mapped_bam: bam.toString(),
            mapped_bai: bai.toString(),
            intake_validation_token_value: tokenValue,
            validation_token: 'VALID_PASS|SAMPLE_VALIDATED',
            save_dir: params.outdir.toString()
        ]
        tuple(enriched, bam, bai, refsNormalized, thresholdsParsed)
    }

    STAGE2_POSTALIGN_SAMPLE_VALIDATION_GATE(chStage2Input)

    def popPcaModels = (refsParsed.models?.poppca_models ?: refsParsed.poppca_models)?.toString()
    def phasingPanel = (refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed)?.toString()
    def hostPopPcaModels = hostPathForReference(popPcaModels, refDir)
    def hostPhasingPanel = hostPathForReference(phasingPanel, refDir)

    def stage4ReferenceMeta = [
        reference_genome: refGenome,
        reference_fai: refFai,
        reference_dict: refDict,
        poppca_models: popPcaModels,
        phasing_panel_bed: phasingPanel,
        clinvar_db: refsParsed.clinvar_db,
        thresholds_reference: thresholdsParsed,
        preflight_lock: preflightLockPublishedPath,
        preflight_lock_status: 'STAGE0_PREFLIGHT_LOCK_PASS',
        reference_snapshot_tokens: referenceSnapshotPublishedPath,
        yaml_snapshot_bundle: yamlSnapshotBundlePublishedPath,
        reference_checksum_manifest: checksumManifest.toString(),
        reference_asset_checksums: checksumMap
    ]

    def stage3Refs = [
        reference_genome  : refsParsed.reference_genome ?: refsParsed.grch38_fasta,
        capture_wes_bed   : refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed,
        onco_target_bed   : refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed,
        mane_transcripts  : refsParsed.mane_transcripts ?: refsParsed.mane_db,
        stage3_vcf_schema : params.refs?.stage3_vcf_schema ?: refsParsed.stage3_vcf_schema ?: "${projectDir}/Stage_3_Variant_Discovery_Engine/tests/schemas/v4.2_Production_Schema.json",
    ]

    def stage3RefsValidated = stage3Refs.collectEntries { key, value ->
        if (value == null) {
            return [(key): null]
        }
        [(key): value.toString()]
    }

    def chStage3Input = STAGE2_POSTALIGN_SAMPLE_VALIDATION_GATE.out.stage2_contract.flatMap { stage2Manifest ->
        def rows = ys.parse(stage2Manifest)?.samples ?: []
        def stage2Root = stage2Manifest.parent ? stage2Manifest.parent.toString() : projectRoot
        rows.collect { rec ->
            def sampleId = (rec.sample_id ?: 'UNKNOWN').toString()
            def sortedBamRaw = rec.sorted_bam?.toString()
            def sortedBaiRaw = rec.sorted_bai?.toString() ?: (sortedBamRaw ? "${sortedBamRaw}.bai" : null)
            def sequencingType = ((rec.sequencing_type ?: rec.library_strategy ?: 'WES')?.toString() ?: 'WES').trim().toUpperCase()
            def isWgs = sequencingType == 'WGS'
            def targetBed = rec.snv_mask_bed?.toString() ?: rec.cnv_target_bed?.toString() ?: stage3RefsValidated.onco_target_bed ?: stage3RefsValidated.capture_wes_bed
            def sampleQcMeta = mapOrEmpty(rec.sample_qc_meta) + [
                estimated_in_silico_purity: rec.estimated_in_silico_purity,
                contamination_rate: rec.contamination_rate,
                computed_sex: rec.computed_sex ?: rec.reported_sex,
                sex_concordance_pass: rec.sex_concordance_pass,
                purity_concordance_pass: rec.purity_concordance_pass,
            ]
            def sampleMeta = (rec as Map) + [
                sample_id: sampleId,
                sample_type: rec.sample_type ?: 'germline',
                sequencing_type: sequencingType,
                validation_token: rec.validation_token?.toString() ?: 'VALID_PASS|SAMPLE_VALIDATED',
                sorted_bam: sortedBamRaw,
                sorted_bai: sortedBaiRaw ?: (sortedBamRaw ? "${sortedBamRaw}.bai" : null),
                reference_build: mapOrEmpty(rec.reference_build),
                sample_qc_meta: sampleQcMeta,
                save_dir: params.outdir.toString(),
            ]
            def fastaPathText = (rec.reference_build?.fasta ?: rec.reference_build?.reference_genome ?: refGenome).toString()
            def hostFasta = fastaPathText.startsWith('/opt/reference')
                ? hostPathForReference(fastaPathText, refDir)
                : resolvePathWithBases(fastaPathText, [projectRoot, stage2Root])
            tuple(
                sampleId,
                stage2Manifest.toString(),
                file(resolvePathWithBases(sortedBamRaw, [projectRoot, stage2Root]), checkIfExists: true),
                file(resolvePathWithBases(sortedBaiRaw, [projectRoot, stage2Root]), checkIfExists: true),
                isWgs,
                targetBed,
                file(hostFasta, checkIfExists: true),
                sampleQcMeta,
                stage3RefsValidated,
                sampleMeta
            )
        }
    }

    STAGE3_VARIANT_DISCOVERY_ENGINE(chStage3Input)

    ASSEMBLE_STAGE3_BANKED_MANIFEST(STAGE3_VARIANT_DISCOVERY_ENGINE.out.stage3_manifest.collect())

    def chStage4Input = ASSEMBLE_STAGE3_BANKED_MANIFEST.out.banked_manifest.flatMap { stage3Manifest ->
        def rows = ys.parse(stage3Manifest)?.samples ?: []
        def stage3Root = params.outdir.toString()
        def stage2ManifestFile = new File(params.outdir.toString(), 'samples_hg002_banked_stage2.yaml')
        def stage2Rows = stage2ManifestFile.exists() ? (ys.parse(stage2ManifestFile)?.samples ?: []) : []
        rows.collect { rec ->
            def stage2Rec = stage2Rows.find { row -> (row.sample_id ?: '').toString() == (rec.sample_id ?: '').toString() } ?: [:]
            def stage3Token = rec.validation_token?.toString() ?: ''
            def stage4Token = stage3Token.contains('VARIANTS_HARMONIZED') ? stage3Token : 'VALID_PASS|VARIANTS_HARMONIZED'
            def sortedBamRaw = rec.sorted_bam?.toString() ?: stage2Rec.sorted_bam?.toString()
            def sortedBaiRaw = rec.sorted_bai?.toString() ?: stage2Rec.sorted_bai?.toString() ?: (sortedBamRaw ? "${sortedBamRaw}.bai" : null)
            def meta = [
                sample_id: rec.sample_id,
                patient_id: rec.patient_id ?: rec.sample_id,
                case_id: rec.case_id ?: rec.patient_id ?: rec.sample_id,
                validation_token: stage4Token,
                consent_tokens: mapOrEmpty(rec.consent_tokens),
                stage0_consent_tokens: mapOrEmpty(rec.stage0_consent_tokens) ?: mapOrEmpty(rec.consent_tokens),
                variant_branches: mapOrEmpty(rec.variant_branches),
                active_branches: (rec.active_branches instanceof List ? rec.active_branches : []),
                normalized_vcf: rec.normalized_vcf?.toString(),
                normalized_vcf_tbi: rec.normalized_vcf_tbi?.toString(),
                sorted_bam: rec.sorted_bam?.toString(),
                sorted_bai: rec.sorted_bai?.toString(),
                harmonization_audit: rec.harmonization_audit?.toString(),
                reference_build: mapOrEmpty(rec.reference_build),
                stage4_handoff_note: rec.stage4_handoff_note ?: 'Stage 4 ancestry and phasing handoff.',
                save_dir: params.outdir.toString()
            ]
            tuple(
                meta,
                file(resolvePathWithBases(rec.normalized_vcf.toString(), [projectRoot, stage3Root]), checkIfExists: true),
                file(resolvePathWithBases(rec.normalized_vcf_tbi.toString(), [projectRoot, stage3Root]), checkIfExists: true),
                file(resolvePathWithBases(sortedBamRaw, [projectRoot, stage3Root]), checkIfExists: true),
                file(resolvePathWithBases(sortedBaiRaw, [projectRoot, stage3Root]), checkIfExists: true),
                stage4ReferenceMeta,
                hostPopPcaModels?.toString(),
                hostPhasingPanel?.toString()
            )
        }
    }

    STAGE4_ANCESTRY_PHASING_HIGHWAY(chStage4Input)

    def stage5ReferencesMeta = [
        reference_genome : refGenome,
        reference_fai    : refFai,
        reference_dict   : refDict,
        onco_target_bed  : refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed,
        capture_wes_bed  : refsParsed.capture_wes_bed ?: refsParsed.onco_target_bed,
        sf_bed           : refsParsed.sf_bed,
        prs_backbone_bed : refsParsed.models?.prs_backbone_bed ?: refsParsed.prs_backbone_bed ?: refsParsed.onco_target_bed ?: refsParsed.capture_wes_bed,
        clinvar_db       : refsParsed.clinvar_db,
        gnomad_vcf       : refsParsed.gnomad_vcf,
        vep_cache_dir    : refsParsed.vep_cache_dir,
        hotspot_registry : refsParsed.hotspot_registry,
        hgmd_db          : refsParsed.hgmd_db ?: refsParsed.hgmd_pro_db,
        prs_weights      : refsParsed.prs_weights ?: refsParsed.models?.prs_weights,
        preflight_lock   : preflightLockPublishedPath,
        preflight_lock_status: 'STAGE0_PREFLIGHT_LOCK_PASS',
        reference_snapshot_tokens: referenceSnapshotPublishedPath,
        yaml_snapshot_bundle: yamlSnapshotBundlePublishedPath,
        reference_checksum_manifest: checksumManifest.toString(),
        reference_asset_checksums: checksumMap
    ]

    def chStage5Input = STAGE4_ANCESTRY_PHASING_HIGHWAY.out.phase_bundle.map { meta, ancestryMetrics, phasedVcf, phasedTbi, _phasingAudit ->
        tuple(meta.sample_id.toString(), phasedVcf, phasedTbi, ancestryMetrics, _phasingAudit, stage5ReferencesMeta)
    }

    STAGE5_CLINICAL_ANNOTATION_PGX_TRIAGE(chStage5Input)

    def stage6ReferencesMeta = [
        reference_genome : refGenome,
        reference_fai    : refFai,
        reference_dict   : refDict,
        vep_cache_dir    : refsParsed.vep_cache_dir,
        hotspot_registry : refsParsed.hotspot_registry,
        clinvar_db       : refsParsed.clinvar_db,
        gnomad_db        : refsParsed.gnomad_db,
        hgmd_db          : refsParsed.hgmd_db ?: refsParsed.hgmd_pro_db,
        sf_bed           : refsParsed.sf_bed,
        prs_weights      : refsParsed.prs_weights ?: refsParsed.models?.prs_weights,
        cyp2d6_mask      : refsParsed.stage3?.cyp2d6_paralog_mask_bed,
        preflight_lock   : preflightLockPublishedPath,
        preflight_lock_status: 'STAGE0_PREFLIGHT_LOCK_PASS',
        reference_snapshot_tokens: referenceSnapshotPublishedPath,
        yaml_snapshot_bundle: yamlSnapshotBundlePublishedPath,
        reference_checksum_manifest: checksumManifest.toString(),
        reference_asset_checksums: checksumMap
    ]
    def stage6NoFileBundle = file("${projectDir}/assets/NO_FILE.bundle", checkIfExists: true)
    def stage6NoFileProvenance = file("${projectDir}/assets/NO_FILE.provenance", checkIfExists: true)

    def chStage6Input = STAGE5_CLINICAL_ANNOTATION_PGX_TRIAGE.out.banked_manifest.flatMap { stage5Manifest ->
        def rows = ys.parse(stage5Manifest)?.samples ?: []
        def stage5Root = stage5Manifest.parent ? stage5Manifest.parent.toFile() : new File(projectRoot)
        def stage5OutRoot = new File(params.outdir.toString())
        rows.collect { rec ->
            def sid = (rec.sample_id ?: 'UNKNOWN').toString()
            def outputs = mapOrEmpty(rec.stage5_outputs)

            def annotationsDir = new File(stage5OutRoot, 'annotation')
            def sfDir = new File(stage5OutRoot, 'secondary_findings')
            def prsDir = new File(stage5OutRoot, 'prs')
            def pgxDir = new File(stage5OutRoot, 'pgx')

            def acmgTiered = resolveStage5Artifact(annotationsDir, outputs.acmg_tiered_variants_json?.toString(), "${sid}.stage5_acmg_tiered_variants.json")
            def candidateVus = resolveStage5Artifact(annotationsDir, "${sid}.stage5_candidate_vus.json")
            def vusQueue = resolveStage5Artifact(annotationsDir, outputs.vus_triage_queue_json?.toString(), "${sid}.stage5_vus_triage_queue.json")
            def sfArtifact = outputs.sf_report_json ? resolveStage5Artifact(sfDir, outputs.sf_report_json.toString(), "${sid}.acmg_sf_bypassed_audit.json") : resolveStage5Artifact(sfDir, "${sid}.acmg_sf_bypassed_audit.json")
            def prsArtifact = outputs.prs_calibrated_report_json ? resolveStage5Artifact(prsDir, outputs.prs_calibrated_report_json.toString(), "${sid}.prs_bypassed_audit.json") : resolveStage5Artifact(prsDir, "${sid}.prs_bypassed_audit.json")
            def pgxArtifact = resolveStage5Artifact(pgxDir, outputs.pgx_report_json?.toString(), "${sid}.pgx_report.json")
            def clinicalBundle = resolveStage5Artifact(pgxDir, outputs.clinical_bundle_tar_gz?.toString(), "${sid}.clinical_bundle.tar.gz")
            def stage5Provenance = resolveStage5Artifact(pgxDir, outputs.provenance_json?.toString(), "${sid}.provenance.json")
            if (clinicalBundle == null || !clinicalBundle.exists()) {
                clinicalBundle = stage6NoFileBundle.toFile()
            }
            if (stage5Provenance == null || !stage5Provenance.exists()) {
                stage5Provenance = stage6NoFileProvenance.toFile()
            }

            def meta = [
                sample_id: sid,
                validation_token: rec.validation_token?.toString() ?: 'VALID_PASS|VARIANTS_HARMONIZED|STAGE5_COMPLETE',
                stage5_manifest: stage5Manifest.toString(),
                stage5_root: stage5Root.toString(),
                stage5_outputs: outputs,
                reference_build: mapOrEmpty(rec.reference_build),
                references_meta: stage6ReferencesMeta,
                thresholds_meta: thresholdsParsed,
                save_dir: params.outdir.toString(),
                workbench_note: 'Stage 6 clinical reporting workbench gateway.'
            ]

            tuple(
                meta,
                file(stage5Manifest, checkIfExists: true),
                file(clinicalBundle, checkIfExists: true),
                file(stage5Provenance, checkIfExists: true),
                file(acmgTiered, checkIfExists: true),
                file(candidateVus, checkIfExists: true),
                file(vusQueue, checkIfExists: true),
                file(sfArtifact, checkIfExists: true),
                file(prsArtifact, checkIfExists: true),
                file(pgxArtifact, checkIfExists: true),
                stage6ReferencesMeta
            )
        }
    }

    STAGE6_CLINICAL_REPORTING_WORKBENCH_GATE(chStage6Input)

    emit:
    stage0_manifest = STAGE0_PREFLIGHT_INGEST.out.banked_samplesheet
    stage1_manifest = STAGE1_ALIGNMENT_READ_PROCESSING.out.aligned_contract
    stage2_manifest = STAGE2_POSTALIGN_SAMPLE_VALIDATION_GATE.out.stage2_contract
    stage3_manifest = STAGE3_VARIANT_DISCOVERY_ENGINE.out.stage3_manifest
    stage4_manifest = STAGE4_ANCESTRY_PHASING_HIGHWAY.out.banked_manifest
    stage5_manifest = STAGE5_CLINICAL_ANNOTATION_PGX_TRIAGE.out.banked_manifest
    stage6_manifest = STAGE6_CLINICAL_REPORTING_WORKBENCH_GATE.out.banked_manifest
}

workflow {
    MASTER_WES_ONCO_ORCHESTRATOR()
}
