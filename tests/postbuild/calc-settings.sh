#!/bin/bash

set -eo pipefail
set -x

original_dir=$PWD
: "${PIPELINE_DEBUG:=0}"
if [ ${PIPELINE_DEBUG} -eq 1 ]; then
    set -x
    env
fi

# Input variables
git_repo=${1}
git_source_branch=${2}
git_target_branch=${3}

# Output variables
labels=cp-shared:ibm-cloudpaks
workers=3
setup_gps=false

rc_major=0
rc_minor=0
rc_patch=1

# Output files
labels_output_file="${original_dir}/test-sh-labels.txt"
workers_output_file="${original_dir}/test-sh-workers.txt"
gps_output_file="${original_dir}/test-sh-gps.txt"
semver_output_file="${original_dir}/test-sh-semver.txt"


#
# Clean up at end of task
#
cleanRun() {
    cd "${original_dir}"
    if [ -n "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}


#
# Extracts only the file names containing differences between the source
# and target branches.
#
function extract_branch_delta() {
    local output_file=${1}

    local result=0

    #
    # Analyze the differences between branches
    # to determine which Cloud Paks to test
    git clone "${git_repo}" cloudpak-gitops \
    && cd cloudpak-gitops \
    && git config pull.rebase false \
    || result=1

    if [ ${result} -eq 0 ]; then
        git pull origin "${git_source_branch}" || result=1
        git diff "${git_target_branch}" origin/main --name-only | tee "${output_file}" \
        && result=0 \
        || result=1

        cat "${branch_delta_output_file}"
    fi

    return ${result}
}


#
#
#
function infer_rc_release() {
    while read -r chart
    do
        if [ -z "${chart}" ]; then
            continue
        fi
        echo "${chart}"

        chart_yaml="${WORKDIR}/chart.yaml"
        git diff "${git_target_branch}" "${chart}" > "${chart_yaml}"

        is_minor=0
        grep "new file" "${chart_yaml}" 1> /dev/null \
        && is_minor=1 \
        || is_minor=0

        if [ ${is_minor} -eq 1 ]; then
           echo "minor"
        else
           new_version=$(grep "^+version" "${chart_yaml}" | cut -d " " -f 2)
           old_version=$(grep "^-version" "${chart_yaml}" | cut -d " " -f 2)
           new_major_version=${new_version//.*/}
           old_major_version=${old_version//.*/}
           if [ "${new_major_version}" -gt "${old_major_version}" ]; then 
               rc_major=1
               rc_minor=0
               rc_patch=0
               echo "major"
               break
           else
               new_minor_version=$(echo "${new_version}" | cut -d "." -f 2)
               old_minor_version=$(echo "${old_version}" | cut -d "." -f 2)
               if [ "${new_minor_version}" -gt "${old_minor_version}" ]; then 
                   rc_minor=1
                   rc_patch=0
                   echo "minor"
               elif [ "${rc_minor}" -eq 0 ]; then
                   new_patch_version=${new_version//*./}
                   old_patch_version=${old_version//*./}
                   if [ "${new_patch_version}" -gt "${old_patch_version}" ]; then 
                       rc_patch=1
                       echo "patch"
                   fi
               fi
           fi           
        fi
    done <<< "$(git diff "${git_target_branch}" --name-only | grep Chart.yaml)"

    echo "Delta: ${rc_major}.${rc_minor}.${rc_patch}"
}

WORKDIR=$(mktemp -d) || exit 1

cd "${WORKDIR}"

branch_delta_output_file="${WORKDIR}/diff.txt"
extract_branch_delta "${branch_delta_output_file}"
# As of CP4D 4.0.6, cp4d has to be last in the "labels" field
for cloudpak in cp4i cp4a cp4waiops cp4s cp4d
do
    if grep "/${cloudpak}/" "${branch_delta_output_file}"; then
        labels="${labels},${cloudpak}:${cloudpak}"
        if [ "${cloudpak}" == "cp4d" ]; then
            setup_gps=true
        fi
        if [ "${cloudpak}" != "cp-shared" ]; then
            workers=$((workers+3))
        fi
    fi
done
if grep "rhacm" "${branch_delta_output_file}"; then
    labels="${labels},rhacm"
fi

infer_rc_release

echo ${labels}

echo "${labels}" > "${labels_output_file}"
echo "${workers}" > "${workers_output_file}"
echo "${setup_gps}" > "${gps_output_file}"
echo "${rc_major}.${rc_minor}.${rc_patch}" > "${semver_output_file}"

# echo "::set-output name=delta:: ${rc_major}.${rc_minor}.${rc_patch}"
