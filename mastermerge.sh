#!/usr/bin/env bash

# Treat unset variables and parameters other than the special parameters ‘@’ or
# ‘*’ as an error when performing parameter expansion. An 'unbound variable'
# error message will be written to the standard error, and a non-interactive
# shell will exit.
set -o nounset
# Exit immediately if a pipeline returns non-zero.
set -o errexit
# Print a helpful message if a pipeline with non-zero exit code causes the
# script to exit as described above.
trap 'echo "Aborting due to errexit on line $LINENO. Exit code: $?" >&2' ERR
# Allow the above trap be inherited by all functions in the script.
set -o errtrace
# Return value of a pipeline is the value of the last (rightmost) command to
# exit with a non-zero status, or zero if all commands in the pipeline exit
# successfully.
set -o pipefail
# Set $IFS to only newline and tab.
IFS=$'\n\t'

#### Environment ####

# Set to the program's basename.
_ME=$(basename "${0}")

#### Help function ####

_print_help() {
cat <<HEREDOC
Usage:
  ${_ME} [input_file] [output_directory]
Options:
  input_file		File with a list of paths to poseidon module directories
  output_directory	Path to an output directory
 -h --help		Show this screen
HEREDOC
}

#### Program Functions ####

_create_binary_file_list_file() {
  # start message
  printf "Creating input file for plink merge...\\n"
  # input file
  _input_file=${1}
  # temporary output file
  _result_file=${2}
  rm -f ${_result_file}
  touch ${_result_file}
  # loop through all modules directories
  while read p; do
    # ignore empty names (empty lines in the input dir list)
    if [ -z "${p}" ]
    then
      continue
    fi
    # loop through relevant file types (bed, bim, fam)
    _file_list=""
    for extension in bed bim fam
    do
      _new_file=$(find "${p}/" -name "*.${extension}")
      _file_list="${_file_list} ${_new_file}"
    done
    # write result to output file
    echo "${_file_list}" >> ${_result_file}
  done <${_input_file}
  # end message
  printf "Done\\n"
}

_plink_merge() {
  # start message
  printf "Merge genome data with plink...\\n"

  sbatch -p "short" -c 4 --mem=10000 -J "plink-merge" --wrap="plink --merge-list ${1} --make-bed --indiv-sort f ${2} --out ${3}_TF"
  # write slurm logs somewhere

  sbatch -p "short" -c 1 --mem=10000 -J "extract_SNPs" --wrap="plink --bfile ${3}_TF --extract ${4} --make-bed --out ${5}_HO"
  # To extract Human Origins SNPs for PCA & other analysis with modern samples

  # end message
  printf "Done\\n"
}

_ped2eig() {
  # start message
  printf "Converting plink files to eigenstrat format...\\n"

  sbatch -p "short" -c 1 --mem=10000 -J "bed2map" --wrap="plink --bfile ${3}_TF --recode --out ${6}_TF"
  # For 1240K dataset

  sbatch -p "short" -c 1 --mem=10000 -J "bed2map" --wrap="plink --bfile ${5}_HO --recode --out ${7}_HO"
  # For Human Origins dataset, we can have this as only a temporary file

  cat convertf_TF.par <<EOF
  genotypename: $PWD/${6}_TF.ped
  snpname: $PWD/${6}_TF.map
  indivname: $PWD/${6}_TF.pedind
  outputformat: EIGENSTRAT
  genotypeoutname: $PWD/${6}_TF.geno
  snpoutname: $PWD/${6}_TF.snp
  indivoutname: $PWD/${6}_TF.ind
  familynames: NO
EOF
 # TODO: check .pedind format, we might have create it or just modify one of plink files
  sbatch -c 1 --mem=2000  -J "convertf" --wrap="convertf -p convertf_TF.par > convert.log"
}

_merge_multiple_files() {
  Rscript -e "
    input_files_paths <- commandArgs(trailingOnly = TRUE)
    input_files_dfs <- lapply(input_files_paths, read.delim, stringsAsFactors = F)
    res_df <- do.call(rbind, input_files_dfs)
    res_df[is.na(res_df)] <- 'n/a'
    out_file <- '/tmp/mastermerge_mergedfile'
    write.table(res_df, file = out_file, sep = '\t', quote = F, row.names = F)
    cat(out_file)
  " ${@}
  # replace R script with concat solution: The janno fiels do have the same columns and column order all the time - no complex merge logic necessary
  # sort by order file
}

_janno_merge() {
  # start message
  printf "Merge janno files...\\n"
  _input_file=${1}
  _output_file="${2}/test_merged_janno.janno"
  # loop through all modules directories
  _janno_files=()
  while read p; do
    # ignore empty names (empty lines in the input dir list)
    if [ -z "${p}" ]
    then
      continue
    fi
    _new_file=$(find "${p}/" -name "*.tsv" -not -path '*/\.*')
    if [ -z "${_new_file}" ]
    then
      continue
    fi
    _janno_files+=("${_new_file}")
  done <${_input_file}
  # merge resulting janno files
  _merged_janno_tmp_file=$(_merge_multiple_files ${_janno_files[@]})
  # move output file
  mv ${_merged_janno_tmp_file} ${_output_file}
  # end message
  printf "Done\\n"
}

_janno_merge() {
  # TODO: Create order file from fam files
}

#### Main function ####

_workflow() {
  # make output directory
  mkdir -p ${2:-}
  # run steps
  _plink_input_file="/tmp/mastermerge_binary_file_list_file"
  _create_binary_file_list_file ${1:-} ${_plink_input_file}
  # TODO: create concatenated order file from first two columns of fam files
  # _order_file = ...
  _plink_merge ${_plink_input_file} ${_order_file} ${2:-}
  _janno_merge ${1:-} ${_order_file} ${2:-}
}

_main() {
  if [[ $# -eq 0 ]] ; then
    _print_help
    exit 0
  fi

  case "${1}" in
    -h) _print_help ;;
    --help) _print_help ;;
    *) _workflow ${1} ${2} ;;
  esac
  exit 0
}

_main "$@"
