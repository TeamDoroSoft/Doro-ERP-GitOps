#!/usr/bin/env bash

set -euo pipefail

readonly AWS_ACCOUNT_ID="727646470302"
readonly AWS_REGION="ap-northeast-2"
OVERLAY_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlays/prod/alpha" && pwd)"
readonly OVERLAY_DIRECTORY
readonly OVERLAY_FILE="${OVERLAY_DIRECTORY}/kustomization.yaml"

usage() {
  echo "Usage: $0 <edge|store-access|commerce|payment|queue|audit> <40-char-git-sha> <sha256:digest>" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

readonly SERVICE="$1"
readonly SOURCE_REVISION="$2"
readonly IMAGE_DIGEST="$3"

case "${SERVICE}" in
  edge|store-access|commerce|payment|queue|audit)
    ;;
  *)
    echo "Unsupported service: ${SERVICE}" >&2
    usage
    exit 64
    ;;
esac

if [[ ! "${SOURCE_REVISION}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "source revision must be a full 40-character lowercase Git SHA." >&2
  exit 64
fi

if [[ ! "${IMAGE_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "image digest must match sha256 followed by 64 lowercase hexadecimal characters." >&2
  exit 64
fi

readonly REPOSITORY="doro-erp-${SERVICE}"
readonly IMAGE_NAME="doro-erp-${SERVICE}"

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
readonly TEMP_FILE
BACKUP_FILE="$(mktemp "${OVERLAY_FILE}.backup.XXXXXX")"
readonly BACKUP_FILE
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

kubectl kustomize "${OVERLAY_DIRECTORY}" >/prod/null

rm -f "${BACKUP_FILE}"
trap - EXIT

echo "Recorded ${REPOSITORY}@${IMAGE_DIGEST} from ${SOURCE_REVISION}."
echo "Review and commit the Infra diff before applying the Prod Alpha overlay."
