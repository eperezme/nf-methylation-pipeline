/*
 * bismark subworkflow
 */

include { BISMARK_ALIGN                               } from '../../modules/nf-core/bismark/align/main'
include { SAMTOOLS_SORT as SAMTOOLS_SORT_ALIGNED      } from '../../modules/nf-core/samtools/sort/main'
include { SAMTOOLS_SORT as SAMTOOLS_SORT_DEDUPLICATED } from '../../modules/nf-core/samtools/sort/main'
include { BISMARK_DEDUPLICATE                         } from '../../modules/nf-core/bismark/deduplicate/main'
include { BISMARK_METHYLATIONEXTRACTOR                } from '../../modules/nf-core/bismark/methylationextractor/main'
include { BISMARK_COVERAGE2CYTOSINE                   } from '../../modules/nf-core/bismark/coverage2cytosine/main'
include { BISMARK_REPORT                              } from '../../modules/nf-core/bismark/report/main'
include { BISMARK_SUMMARY                             } from '../../modules/nf-core/bismark/summary/main'


workflow BISMARK {
    take:
    reads                   // channel: [ val(meta), [ reads ] ]
    bismark_index           // channel: /path/to/BismarkIndex
    skip_deduplication      // boolean: skip deduplication step
    cytosine_report         // boolean: generate cytosine report (coverage2cytosine)

    main:
    versions = Channel.empty()

    /*
     * BISMARK ALIGN READS
     */
    BISMARK_ALIGN (
        reads,
        bismark_index
    )
    versions = versions.mix(BISMARK_ALIGN.out.versions)

    /*
     * SAMTOOLS SORT ALIGNED
     */
    SAMTOOLS_SORT_ALIGNED (
        BISMARK_ALIGN.out.bam,
        bismark_index
    )
    versions = versions.mix(SAMTOOLS_SORT_ALIGNED.out.versions)


    /*
     * BISMARK DEDUPLICATE
     */
    if (skip_deduplication) {
        alignments = BISMARK_ALIGN.out.bam
        alignment_reports = BISMARK_ALIGN.out.report.map{ meta, report -> [ meta, report, [] ] }
    } else {

        BISMARK_DEDUPLICATE (
            BISMARK_ALIGN.out.bam
        )

        alignments = BISMARK_DEDUPLICATE.out.bam
        alignment_reports = BISMARK_ALIGN.out.report.join(BISMARK_DEDUPLICATE.out.report)
        versions = versions.mix(BISMARK_DEDUPLICATE.out.versions)
    }

    /*
     * METHYLATION EXTRACTION
     */
    BISMARK_METHYLATIONEXTRACTOR (
        alignments,
        bismark_index
    )
    versions = versions.mix(BISMARK_METHYLATIONEXTRACTOR.out.versions)


    /*
     * BISMARK COVERAGE2CYTOSINE
     */
    if (cytosine_report) {
        BISMARK_COVERAGE2CYTOSINE (
            BISMARK_METHYLATIONEXTRACTOR.out.coverage,
            bismark_index
        )
        versions = versions.mix(BISMARK_COVERAGE2CYTOSINE.out.versions)
    }

    /*
     * BISMARK REPORT
     */

    BISMARK_REPORT (
        alignment_reports
            .join(BISMARK_METHYLATIONEXTRACTOR.out.report)
            .join(BISMARK_METHYLATIONEXTRACTOR.out.mbias)
    )
    versions = versions.mix(BISMARK_REPORT.out.versions)


    /*
     * BISMARK SUMMARY
     */

    BISMARK_SUMMARY (
        BISMARK_ALIGN.out.bam.collect{ it[1].name }.ifEmpty([ ]),
        alignment_reports.collect{ it[1] }.ifEmpty([ ]),
        alignment_reports.collect{ it[2] }.ifEmpty([ ]),
        BISMARK_METHYLATIONEXTRACTOR.out.report.collect{ it[1] }.ifEmpty([ ]),
        BISMARK_METHYLATIONEXTRACTOR.out.mbias.collect{ it[1] }.ifEmpty([ ])
    )
    versions = versions.mix(BISMARK_SUMMARY.out.versions)

    /*
     * SAMTOOLS SORT DEDUPLICATED
     */
    SAMTOOLS_SORT_DEDUPLICATED (
        alignments,
        bismark_index
    )
    versions = versions.mix(SAMTOOLS_SORT_DEDUPLICATED.out.versions)


    /*
     * MULTIQC REPORTS
     */
    BISMARK_SUMMARY.out.summary.ifEmpty([ ])
        .mix(alignment_reports.collect{ it[1] })
        .mix(alignment_reports.collect{ it[2] })
        .mix(BISMARK_METHYLATIONEXTRACTOR.out.report.collect{ it[1] })
        .mix(BISMARK_METHYLATIONEXTRACTOR.out.mbias.collect{ it[1] })
        .mix(BISMARK_REPORT.out.report.collect{ it[1] })
        .set{ multiqc_files }

    // EXPORTS

    emit:
    bam             = SAMTOOLS_SORT_ALIGNED.out.bam         // channel: [ val(meta), [ bam ] ]
    dedup           = SAMTOOLS_SORT_DEDUPLICATED.out.bam    // channel: [ val(meta), [ bam ] ]
    mqc             = multiqc_files                         // path: *(html,txt)
    versions        = versions                              // path *.version.txt
}
