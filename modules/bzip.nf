#!/usr/bin/env nextflow

process recompress {

    input:
    path bz2_file

    output:
    path gz_file

    script:
    // Extract the base filename (without extension) for the output
    def base_name = bz2_file.baseName

    // Define output gz file
    def gz_file = "${base_name}.gz"

    """
    # Decompress the .bz2 file to a .tmp file
    bzip2 -d -k -c ${bz2_file} > ${base_name}.tmp
    
    # Recompress the .tmp file to .gz
    gzip -c ${base_name}.tmp > ${gz_file}
    
    # Remove the temporary file
    rm ${base_name}.tmp
    """
}

workflow {
    // Path to the input .bz2 file
    bz2_file = file(params.input_file)
    
    // Call the decompress_recompress process
    recompress(bz2_file)
}
