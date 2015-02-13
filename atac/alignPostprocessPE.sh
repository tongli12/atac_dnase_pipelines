#!/usr/bin/env bash

set -o nounset
set -o pipefail
set -o errexit

if hash module 2>/dev/null; then
   module add samtools/0.1.19
   module add picard-tools/1.92
   module add bedtools/2.19.1
fi

RAW_BAM_FILE=$1
OFPREFIX=$2
MAPQ_THRESH=$3

if [[ -z $MAPQ_THRESH ]]
then
    echo "MAPQ threshold defaulting to 30"
    MAPQ_THRESH=30
fi

# =============================
# Remove  unmapped, mate unmapped
# not primary alignment, reads failing platform
# Remove low MAPQ reads
# Only keep properly paired reads
# Obtain name sorted BAM file
# ==================
FILT_BAM_PREFIX="${OFPREFIX}.filt.srt"
FILT_BAM_FILE="${FILT_BAM_PREFIX}.bam"
TMP_FILT_BAM_PREFIX="tmp.${FILT_BAM_PREFIX}.nmsrt"
TMP_FILT_BAM_FILE="${TMP_FILT_BAM_PREFIX}.bam"

samtools view -F 1804 -f 2 -q "${MAPQ_THRESH}" -u "${RAW_BAM_FILE}" | \
    samtools sort -n - "${TMP_FILT_BAM_PREFIX}" # Will produce name sorted BAM

# Remove orphan reads (pair was removed)
# and read pairs mapping to different chromosomes
# Obtain position sorted BAM

samtools fixmate -O bam -r "${TMP_FILT_BAM_FILE}" - | \
    samtools view -F 1804 -f 2 -u - | \
    samtools sort - "${FILT_BAM_PREFIX}" # Will produce coordinate sorted BAM
rm "${TMP_FILT_BAM_FILE}"

# =============
# Mark duplicates
# =============

TMP_FILT_BAM_FILE="${FILT_BAM_PREFIX}.dupmark.bam"
MARKDUP="$PICARDROOT/MarkDuplicates.jar"
DUP_FILE_QC="${FILT_BAM_PREFIX}.dup.qc"

java -Xmx4G -jar "${MARKDUP}" \
    INPUT="${FILT_BAM_FILE}" OUTPUT="${TMP_FILT_BAM_FILE}" \
    METRICS_FILE="${DUP_FILE_QC}" VALIDATION_STRINGENCY=LENIENT \
    ASSUME_SORTED=true REMOVE_DUPLICATES=false
mv "${TMP_FILT_BAM_FILE}" "${FILT_BAM_FILE}"

# ============================
# Remove duplicates
# Index final position sorted BAM
# Create final name sorted BAM
# ============================

FINAL_BAM_PREFIX="${OFPREFIX}.filt.srt.nodup"
FINAL_BAM_FILE="${FINAL_BAM_PREFIX}.bam" # To be stored
FINAL_BAM_INDEX_FILE="${FINAL_BAM_PREFIX}.bai"
FINAL_BAM_FILE_MAPSTATS="${FINAL_BAM_PREFIX}.flagstat.qc" # QC file
FINAL_NMSRT_BAM_PREFIX="${OFPREFIX}.filt.nmsrt.nodup"
FINAL_NMSRT_BAM_FILE="${FINAL_NMSRT_BAM_PREFIX}.bam" # To be stored

samtools view -F 1804 -f 2 -b "${FILT_BAM_FILE}" > "${FINAL_BAM_FILE}"
samtools sort -n "${FINAL_BAM_FILE}" "${FINAL_NMSRT_BAM_PREFIX}"

# Index Final BAM file
samtools index "${FINAL_BAM_FILE}"
mv -f "${FINAL_BAM_FILE}".bai "${FINAL_BAM_INDEX_FILE}" 
samtools flagstat "${FINAL_BAM_FILE}" > "${FINAL_BAM_FILE_MAPSTATS}"

# =============================
# Compute library complexity
# =============================
# Sort by name
# convert to bedPE and obtain fragment coordinates
# sort by position and strand
# Obtain unique count statistics

PBC_FILE_QC="${FINAL_BAM_PREFIX}.pbc.qc"

# TotalReadPairs [tab] DistinctReadPairs [tab] OneReadPair [tab] TwoReadPairs [tab] NRF=Distinct/Total [tab] PBC1=OnePair/Distinct [tab] PBC2=OnePair/TwoPair
samtools sort -n -o "${FILT_BAM_FILE}" tmp."${FILT_BAM_FILE}" | \
    bedtools bamtobed -bedpe -i stdin | \
    awk 'BEGIN{OFS="\t"}{print $1,$2,$4,$6,$9,$10}' | \
    grep -v 'chrM' | \
    sort | \
    uniq -c | \
    awk 'BEGIN{mt=0;m0=0;m1=0;m2=0} ($1==1){m1=m1+1} ($1==2){m2=m2+1} {m0=m0+1} {mt=mt+$1} END{printf "%d\t%d\t%d\t%d\t%f\t%f\t%f\n",mt,m0,m1,m2,m0/mt,m1/m0,m1/m2}' > "${PBC_FILE_QC}"
rm "${FILT_BAM_FILE}"

echo "Postprocessing done - sorted final BAM file is:"
echo "${FINAL_BAM_FILE}"
