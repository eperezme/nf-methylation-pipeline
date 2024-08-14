/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    PRINT PARAMS SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { paramsSummaryLog; paramsSummaryMap; fromSamplesheet } from 'plugin/nf-validation'

def logo = NfcoreTemplate.logo(workflow, params.monochrome_logs)
def summary_params = paramsSummaryMap(workflow)

// Print parameter summary
log.info + paramsSummaryLog(workflow)

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

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { CAT_FASTQ                     } from '../modules/nf-core/fastq/cat/main'
include { FASTQC                        } from '../modules/nf-core/fastqc/main'
include { MULTIQC                       } from '../modules/nf-core/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS   } from '../modules/nf-core/custom/dumpsoftwareversions/main'
include { TRIMGALORE                    } from '../modules/nf-core/trim_galore/main'
include { QUALIMAP_BAMQC                } from '../modules/nf-core/qualimap/bamqc/main'
// include { PRESEQ_LCEXTRAP             } from '../modules/nf-core/preseq/lcextrap/main'

include { paramsSummaryMultiqc          } from '../subworkflows/nf-core/utils_nfcore_pipeline'

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










        
        }
    
    take:
    ch_samplesheet // channel: samplesheet read in from --input

    main:

    ch_multiqc_files = Channel.empty()

    //
    // MODULE: Run FastQC
    //
    FASTQC (
        ch_samplesheet
    )
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]})
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    //
    // Collate and save software versions
    //
    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_pipeline_software_mqc_versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))

    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList()
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
