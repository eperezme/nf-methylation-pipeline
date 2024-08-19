//
// Prepare reference genome files
//

include { UNTAR                       } from '../../modules/nf-core/untar/main'
include { BISMARK_GENOMEPREPARATION   } from '../../modules/nf-core/bismark/genomepreparation/main'
include { SAMTOOLS_FAIDX              } from '../../modules/nf-core/samtools/faidx/main'


workflow INDEX_GENOME {

    main:
    ch_versions         = Channel.empty()
    ch_fasta            = Channel.empty()
    ch_bismark_index    = Channel.empty()


    // FASTA supplied
    if (params.fasta) {
        ch_fasta = Channel.value(file(params.fasta))
    }

    // Generate Bismark index if not supplied
    if (params.bismark_index) {
        if (params.bismark_index.endsWith('.gz')) {
            ch_bismark_index = UNTAR( [ [:], file(params.bismark_index) ] ).untar.map { it[1] }
        } else {
            ch_bismark_index = Channel.value(file(params.bismark_index))
        }

    } else {
            BISMARK_GENOMEPREPARATION(ch_fasta)
            ch_bismark_index = BISMARK_GENOMEPREPARATION.out.index
            ch_versions = ch_versions.mix(BISMARK_GENOMEPREPARATION.out.versions)
        }

    emit:
    fasta           = ch_fasta            // channel: path(genome.fasta)
    bismark_index   = ch_bismark_index    // channel: path(genome.fasta)
    versions        = ch_versions         // channel: [ versions.yml ]

}
