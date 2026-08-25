#!/usr/bin/env bash

set -euo pipefail

readonly AWS_ACCOUNT_ID="727646470302"
readonly AWS_REGION="ap-northeast-2"
readonly REPOSITORY="doro-erp-frontend"
readonly IMAGE_NAME="doro-erp-frontend"
readonly ADMIN_RESOURCE="  - ../../../base/provider-admin"
OVERLAY_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlays/prod/alpha" && pwd)"
readonly OVERLAY_DIRECTORY
readonly OVERLAY_FILE="${OVERLAY_DIRECTORY}/kustomization.yaml"

usage() {
  echo "Usage: $0 <40-char-front-git-sha> <sha256:digest>" >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 64
fi

readonly SOURCE_REVISION="$1"
readonly IMAGE_DIGEST="$2"

if [[ ! "${SOURCE_REVISION}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "source revision must be a full 40-character lowercase Git SHA." >&2
  exit 64
fi

if [[ ! "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "image digest must match sha256 followed by 64 lowercase hexadecimal characters." >&2
  exit 64
fi

if [[ "$(aws sts get-caller-identity --query Account --output text)" != "${AWS_ACCOUNT_ID}" ]]; then
  echo "Refusing to read or record a release outside AWS account ${AWS_ACCOUNT_ID}." >&2
  exit 1
fi

PUBLISHED_DIGEST="$(aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${REPOSITORY}" \
  --image-ids "imageTag=${SOURCE_REVISION}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"
readonly PUBLISHED_DIGEST

if [[ "${PUBLISHED_DIGEST}" != "${IMAGE_DIGEST}" ]]; then
  echo "ECR tag ${REPOSITORY}:${SOURCE_REVISION} resolves to ${PUBLISHED_DIGEST}, not ${IMAGE_DIGEST}." >&2
  exit 1
fi

TEMP_FILE="$(mktemp "${OVERLAY_FILE}.XXXXXX")"
BACKUP_FILE="$(mktemp "${OVERLAY_FILE}.backup.XXXXXX")"
readonly TEMP_FILE BACKUP_FILE
cp "${OVERLAY_FILE}" "${BACKUP_FILE}"

cleanup() {
  local status=$?
  if [[ ${status} -ne 0 && -f "${BACKUP_FILE}" ]]; then
    cp "${BACKUP_FILE}" "${OVERLAY_FILE}"
  fi
  rm -f "${TEMP_FILE}" "${BACKUP_FILE}"
  exit "${status}"
}

trap cleanup EXIT

if ! grep -Fxq "${ADMIN_RESOURCE}" "${OVERLAY_FILE}"; then
  echo "Provider Admin Base must remain part of the reviewed Prod Alpha topology." >&2
  exit 1
fi

if grep -Fq "  - name: ${IMAGE_NAME}" "${OVERLAY_FILE}"; then
  awk \
    -v image_name="${IMAGE_NAME}" \
    -v digest="${IMAGE_DIGEST}" \
    -v revision="${SOURCE_REVISION}" '
      $0 == "  - name: " image_name {
        in_target = 1
        print
        next
      }
      in_target && $1 == "digest:" {
        print "    digest: " digest " # source-revision: " revision
        in_target = 0
        updated = 1
        next
      }
      { print }
      END {
        if (!updated) {
          exit 42
        }
      }
    ' "${OVERLAY_FILE}" > "${TEMP_FILE}"
  mv "${TEMP_FILE}" "${OVERLAY_FILE}"
else
  printf '%s\n' \
    "  - name: ${IMAGE_NAME}" \
    "    newName: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${REPOSITORY}" \
    "    digest: ${IMAGE_DIGEST} # source-revision: ${SOURCE_REVISION}" \
    >> "${OVERLAY_FILE}"
fi

kubectl kustomize "${OVERLAY_DIRECTORY}" >/dev/null

rm -f "${BACKUP_FILE}"
trap - EXIT

echo "Recorded ${REPOSITORY}@${IMAGE_DIGEST} from ${SOURCE_REVISION}."
echo "Review and merge the GitOps release PR before Argo CD deploys Provider Admin."
