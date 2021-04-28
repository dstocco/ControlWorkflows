#!/usr/bin/env bash

# 0: bare-only; 1: UL-only;  2 bare+UL
logicType="1"
cardIds="#0"
perGBT=0
workflowName="mid-raw-checker"
configDir="$HOME/daq_utils/config"
outFile="/home/{{\ user\ }}/output/ecs_raw_checker_out.txt"

optList="c:gi:o:u:w:"
while getopts $optList option; do
    case $option in
    c) configDir=$OPTARG ;;
    g) perGBT=1 ;;
    i) cardIds=$OPTARG ;;
    o) outFile=$OPTARG ;;
    u) logicType=$OPTARG ;;
    w) workflowName=$OPTARG ;;
    *)
        echo "Unimplemented option chosen $option."
        EXIT=1
        ;;
    esac
done

shift $((OPTIND - 1))

if [[ $EXIT -eq 1 ]]; then
    echo "Usage: $(basename "$0") (-$optList)"
    echo "       -c configuration files directory"
    echo "       -g launch one checker process per GBT link"
    echo "       -i comma-separated list of card IDs (default: $cardIds)"
    echo "       -o output file"
    echo "       -u logic type (0: bare-only; 1: UL-only; 2: bare+UL)"
    echo "       -w workflow name (default: $workflowName)"
    exit 2
fi

if [[ -z "$configDir" || ! -e "$configDir" ]]; then
    echo "Please specify directory with configuration files with -c"
    exit 1
fi

function getUniqueId() {
    linkId="$1"
    epId="$2"
    cruId="$3"
    if [ "$epId" -eq 0 ]; then
        echo $(((linkId + 1) + (cruId << 16)))
    else
        echo $(((linkId + 1 << 8) + (cruId << 16)))
    fi
}

function getDataSpec() {
    dataSpec=""
    iline=0
    ulSpec=""
    while read -r line; do
        IFS=', ' read -r -a arr <<<"$line"
        if [[ "${#arr[@]}" -eq 4 || "${#arr[@]}" -eq 5 ]]; then
            if [[ "$2" =~ [02] ]]; then
                if [ "$iline" -gt 0 ]; then
                    dataSpec="${dataSpec};"
                fi
                dataSpec="${dataSpec}${iline}:MID/RAWDATA/$(getUniqueId "${arr[1]}" "${arr[2]}" "${arr[3]}")"
                iline=$((iline + 1))
            fi
            ulSpec="$ulSpec $(getUniqueId 15 "${arr[2]}" "${arr[3]}")"
        fi
    done <"$1"
    if [[ "$2" =~ [12] ]]; then
        ulSpec=$(echo "$ulSpec" | tr ' ' '\n' | sort | uniq)
        for iul in $ulSpec; do
            if [ "$iline" -gt 0 ]; then
                dataSpec="${dataSpec};"
            fi
            dataSpec="${dataSpec}${iline}:MID/RAWDATA/$iul"
            iline=$((iline + 1))
        done
    fi
    echo "$dataSpec"
}

stfBuilderChAddress="ipc:///tmp/stf-builder-dpl-pipe-0"

tmpConfigDir="tmp_config"
if [ ! -e "$tmpConfigDir" ]; then
    mkdir "$tmpConfigDir"
fi

feeIdConfig="$tmpConfigDir/feeId_mapper.txt"
idsStr="${cardIds//#/}"
idsStr="${idsStr//,/ }"
read -ra ids <<<"$idsStr"
{
    for id in "${ids[@]}"; do
        cat "$configDir/feeId_mapper_${id}.txt"
    done
} >"$feeIdConfig"
crateMasks="$configDir/crate_masks.txt"
if [ -e "$crateMasks" ]; then
    cp -pi "$crateMasks" "$tmpConfigDir/"
fi
dataSpec="A:MID/RAWDATA"
if [[ "$perGBT" -eq 1 ]]; then
    dataSpec=$(getDataSpec "$feeIdConfig" "$logicType")
fi
dataSpec="dd:FLP/DISTSUBTIMEFRAME/0;$dataSpec"

echo "dataSpec: $dataSpec"

set -x # debug mode
set -e # exit on error
set -u # exit on undefined variable

# Variables
WF_NAME="$workflowName"
# QC_GEN_CONFIG_PATH='json://'${QUALITYCONTROL_ROOT}'/etc/mft-digit-qc-task-FLP-0-TaskLevel-0.json'
# QC_FINAL_CONFIG_PATH='consul-json://{{ consul_endpoint }}/o2/components/qc/ANY/any/'${WF_NAME}'-{{ it }}'
# QC_CONFIG_PARAM='qc_config_uri'
QC_GEN_CONFIG_PATH="$tmpConfigDir"
QC_FINAL_CONFIG_PATH="/home/{{ user }}/daq_utils/config"

dplProxyCmd="o2-dpl-raw-proxy -b --session default --dataspec \"$dataSpec\" --channel-config \"name=readout-proxy,type=pull,method=connect,address=${stfBuilderChAddress},transport=shmem,rateLogging=5\""

if [ "$logicType" -eq 2 ]; then
    # We have both common and user logic
    analysisCmd="o2-mid-ul-checker-workflow -b --session default --feeId-config-file $QC_GEN_CONFIG_PATH/feeId_mapper.txt"
else
    analysisCmd="o2-mid-raw-checker-workflow -b --session default --feeId-config-file $QC_GEN_CONFIG_PATH/feeId_mapper.txt"
    if [ "$perGBT" -eq 1 ]; then
        analysisCmd="$analysisCmd --per-gbt"
    fi
    if [ -e "$crateMasks" ]; then
        analysisCmd="$analysisCmd --crate-masks-file $QC_GEN_CONFIG_PATH/crate_masks.txt"
    fi
fi
if [ -n "$outFile" ]; then
    analysisCmd="$analysisCmd --mid-checker-outfile $outFile"
fi
stfSenderCmd="o2-dpl-output-proxy -b --session default --dpl-output-proxy --dataspec \"$dataSpec\" --channel-config \"name=downstream,type=push,method=bind,address=ipc:///tmp/stf-pipe-0,rateLogging=10,transport=shmem\""

# Generate the AliECS workflow and task templates
eval "$dplProxyCmd | $analysisCmd | $stfSenderCmd --o2-control $WF_NAME"
rm -rf "$tmpConfigDir"

# Add the final QC config file path as a variable in the workflow template
ESCAPED_QC_FINAL_CONFIG_PATH=$(printf '%s\n' "$QC_FINAL_CONFIG_PATH" | sed -e 's/[\/&]/\\&/g')
# # Will work only with GNU sed (Mac uses BSD sed)
# sed -i '' "/defaults:/a\\
#   ${QC_CONFIG_PARAM}: \"${ESCAPED_QC_FINAL_CONFIG_PATH}\"
# " workflows/"${WF_NAME}".yaml

# Find all usages of the QC config path which was used to generate the workflow and replace them with the template variable
# ESCAPED_QC_GEN_CONFIG_PATH=$(printf '%s\n' "$QC_GEN_CONFIG_PATH" | sed -e 's/[]\/$*.^[]/\\&/g')
# # Will work only with GNU sed (Mac uses BSD sed)
# sed -i '' "s/""${ESCAPED_QC_GEN_CONFIG_PATH}""/{{ ""${QC_CONFIG_PARAM}"" }}/g" "workflows/${WF_NAME}.yaml" tasks/"${WF_NAME}"-*
ESCAPED_QC_GEN_CONFIG_PATH=$(printf '%s\n' "$QC_GEN_CONFIG_PATH" | sed -e 's/[]\/$*.^[]/\\&/g')
# Will work only with GNU sed (Mac uses BSD sed)
sed -i '' "s/""${ESCAPED_QC_GEN_CONFIG_PATH}""/""${ESCAPED_QC_FINAL_CONFIG_PATH}""/g" "workflows/${WF_NAME}.yaml" tasks/"${WF_NAME}"-*
