/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryLog; paramsSummaryMap; fromSamplesheet } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def summary_params = paramsSummaryMap(workflow)

// Print parameter summary
log.info logo + paramsSummaryLog(workflow)

WorkflowMethylation.initialise(params, log)


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config          = Channel.fromPath("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config   = params.multiqc_config ? Channel.fromPath( params.multiqc_config, checkIfExists: true ) : Channel.empty()
ch_multiqc_logo            = params.multiqc_logo   ? Channel.fromPath( params.multiqc_logo, checkIfExists: true ) : Channel.empty()
ch_multiqc_custom_methods_description = params.multiqc_methods_description ? file(params.multiqc_methods_description, checkIfExists: true) : file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES / SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOWS
//

include { INDEX_GENOME } from '../subworkflows/local/genome_index'
include { BISMARK      } from '../subworkflows/local/bismark'


//
// MODULES
//

include { TRIMDIVERSITY } from '../modules/local/trimdiversity/main'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CAT_FASTQ                     } from '../modules/nf-core/cat/fastq/main'
include { FASTQC                        } from '../modules/nf-core/fastqc/main'
include { MULTIQC                       } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS   } from '../modules/nf-core/custom/dumpsoftwareversions/main'
include { TRIMGALORE                    } from '../modules/nf-core/trimgalore/main'
include { QUALIMAP_BAMQC                } from '../modules/nf-core/qualimap/bamqc/main'
// include { PRESEQ_LCEXTRAP             } from '../modules/nf-core/preseq/lcextrap/main'


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
// For email and summary
def multiqc_report = []

workflow METHYLATION {

    ch_versions = Channel.empty()
    
    //
    // SUBWORKFLOW: INDEX_GENOME
    //
    INDEX_GENOME()
    ch_versions = ch_versions.mix(INDEX_GENOME.out.versions)

    //
    // Create input channel from samplesheet
    //
    Channel
        .fromSamplesheet("input")
        .map {
            meta, fastq_1, fastq_2 ->
            if (!fastq_2) {
                return [meta + [single_end:true], [fastq_1]]
            } else {
                return [meta + [single_end:false], [fastq_1, fastq_2]]
            }
        }
        .groupTuple()
        .map {
            meta, fastq ->
            def meta_clone = meta.clone()
            parts = meta_clone.id.split('_')
            meta_clone.id = parts.length > 1 ? parts[0..-2].join('_') : meta_clone.id
            [ meta_clone, fastq ]
        }
        .groupTuple(by: [0])
        .branch {
            meta, fastq ->
            single: fastq.size() == 1
            return [ meta, fastq.flatten() ]
            multiple: fastq.size() > 1
            return [ meta, fastq.flatten() ]
        }
        .set { ch_fastq }

    //
    // MODULE: CAT_FASTQ Combine same sample fastq files
    //
    CAT_FASTQ (
        ch_fastq.multiple
    )
    .reads
    .mix(ch_fastq.single)
    .set { ch_cat_fastq }
    ch_versions = ch_versions.mix(CAT_FASTQ.out.versions.first())

    //
    // MODULE: FASTQC
    //
    FASTQC (
        ch_cat_fastq
    )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    //
    // MODULE: TRIMGALORE
    //
    if (!params.skip_trimming || params.ovation) {
        TRIMGALORE(
            ch_cat_fastq
        )
        reads = TRIMGALORE.out.reads
        ch_versions = ch_versions.mix(TRIMGALORE.out.versions.first())
    } else {
        reads = ch_cat_fastq
    }

    //
    // MODULE: Run NuMetRRBS/trimRRBSdiversityAdaptCustomers.py
    //
    if (params.ovation) {
        TRIMDIVERSITY(reads)
        reads = TRIMDIVERSITY.out.reads
        ch_versions = ch_versions.mix(TRIMDIVERSITY.out.versions.first())
    }

    //
    // SUBWORKFLOW: BISMARK (Alignment, deduplication, methylation extraction)
    //
    BISMARK (
        reads,
        INDEX_GENOME.out.bismark_index,
        params.skip_deduplication || params.rrbs,
        params.cytosine_report || params.nomeseq
    )
    ch_versions     = ch_versions.mix(BISMARK.out.versions.unique{ it.baseName })
    ch_bam          = BISMARK.out.bam
    ch_dedup        = BISMARK.out.dedup
    ch_aligner_mqc  = BISMARK.out.mqc
    ch_bedgraph     = BISMARK.out.bedgraph
    ch_cov          = BISMARK.out.cov

    //
    // MODULE: QUALIMAP_BAMQC
    //
    QUALIMAP_BAMQC (
        ch_dedup,
        params.bamqc_regions_file ? Channel.fromPath( params.bamqc_regions_file, checkIfExists: true ).toList() : []
    )
    ch_versions = ch_versions.mix(QUALIMAP_BAMQC.out.versions.first())


    //
    // MODULE: CUSTOM_DUMPSOFTWAREVERSIONS
    // 
    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )


    //
    // MODULE: MULTIQC
    //
    if (!params.skip_multiqc) {
        workflow_summary    = WorkflowMethylation.paramsSummaryMultiqc(workflow, summary_params)
        ch_workflow_summary = Channel.value(workflow_summary)

        methods_desciption      = WorkflowMethylation.methodsDescriptionText(workflow, ch_multiqc_custom_methods_description, params)
        ch_methods_description  = Channel.value(methods_desciption)


        ch_multiqc_files = Channel.empty()
        ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
        ch_multiqc_files = ch_multiqc_files.mix(ch_methods_description.collectFile(name: 'methods_description_mqc.yaml'))
        ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
        ch_multiqc_files = ch_multiqc_files.mix(QUALIMAP_BAMQC.out.results.collect{ it[1] }.ifEmpty([]))
        ch_multiqc_files = ch_multiqc_files.mix(ch_aligner_mqc.ifEmpty([]))
        if (!params.skip_trimming) {
            ch_multiqc_files = ch_multiqc_files.mix(TRIMGALORE.out.log.collect{ it[1] })
        }
        if (params.ovation) {
            ch_multiqc_files = ch_multiqc_files.mix(TRIMDIVERSITY.out.log.collect{ it[1] })
        }
        ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{ it[1] }.ifEmpty([]))

        MULTIQC (
            ch_multiqc_files.collect(),
            ch_multiqc_config.toList(),
            ch_multiqc_custom_config.toList(),
            ch_multiqc_logo.toList()
        )
        multiqc_report  = MULTIQC.out.report.toList()
        ch_versions     = ch_versions.mix(MULTIQC.out.versions)

        }
}
/*
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.dump_parameters(workflow, params)
    NfcoreTemplate.summary(workflow, params, log)
    if (params.hook_url) {
        NfcoreTemplate.IM_notification(workflow, params, summary_params, projectDir, log)
    }
}


/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
