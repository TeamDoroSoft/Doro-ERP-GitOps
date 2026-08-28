#!/usr/bin/env bash

set -euo pipefail

readonly AWS_ACCOUNT_ID="727646470302"
readonly AWS_REGION="ap-northeast-2"
MIGRATION_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../migrations/prod-alpha" && pwd)"
readonly MIGRATION_DIRECTORY
readonly MIGRATION_FILE="${MIGRATION_DIRECTORY}/kustomization.yaml"

usage() {
  echo "Usage: $0 <store-access|commerce|payment|queue> <40-char-git-sha> <sha256:digest>" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

readonly SERVICE="$1"
readonly SOURCE_REVISION="$2"
readonly IMAGE_DIGEST="$3"

case "${SERVICE}" in
  store-access|commerce|payment|queue)
    ;;
  *)
    echo "Unsupported migration service: ${SERVICE}" >&2
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

readonly SOURCE_REVISION_SHORT="${SOURCE_REVISION:0:12}"
readonly IMAGE_TAG="${SOURCE_REVISION_SHORT}-migration"
readonly REPOSITORY="doro-erp-${SERVICE}"
readonly IMAGE_NAME="doro-erp-${SERVICE}-migration"

if [[ "$(aws sts get-caller-identity --query Account --output text)" != "${AWS_ACCOUNT_ID}" ]]; then
  echo "Refusing to read or record a migration release outside AWS account ${AWS_ACCOUNT_ID}." >&2
  exit 1
fi

PUBLISHED_DIGEST="$(aws ecr describe-images \
  --region "${AWS_REGION}" \
  --repository-name "${REPOSITORY}" \
  --image-ids "imageTag=${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"
readonly PUBLISHED_DIGEST

if [[ "${PUBLISHED_DIGEST}" != "${IMAGE_DIGEST}" ]]; then
  echo "ECR tag ${REPOSITORY}:${IMAGE_TAG} resolves to ${PUBLISHED_DIGEST}, not ${IMAGE_DIGEST}." >&2
  exit 1
fi

TEMP_FILE="$(mktemp "${MIGRATION_FILE}.XXXXXX")"
readonly TEMP_FILE
BACKUP_FILE="$(mktemp "${MIGRATION_FILE}.backup.XXXXXX")"
readonly BACKUP_FILE
cp "${MIGRATION_FILE}" "${BACKUP_FILE}"

cleanup() {
  local status=$?
  if [[ ${status} -ne 0 && -f "${BACKUP_FILE}" ]]; then
    cp "${BACKUP_FILE}" "${MIGRATION_FILE}"
  fi
  rm -f "${TEMP_FILE}" "${BACKUP_FILE}"
  exit "${status}"
}

trap cleanup EXIT

awk \
  -v image_name="${IMAGE_NAME}" \
  -v image_tag="${IMAGE_TAG}" \
  -v revision="${SOURCE_REVISION}" '
    $0 == "  - name: " image_name {
      in_target = 1
      print
      next
    }
    in_target && $1 == "newTag:" {
      print "    newTag: " image_tag " # source-revision: " revision
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
  ' "${MIGRATION_FILE}" > "${TEMP_FILE}"

mv "${TEMP_FILE}" "${MIGRATION_FILE}"

kubectl kustomize "${MIGRATION_DIRECTORY}" >/dev/null

rm -f "${BACKUP_FILE}"
trap - EXIT

echo "Recorded ${REPOSITORY}:${IMAGE_TAG}@${IMAGE_DIGEST} from ${SOURCE_REVISION}."
echo "Review and merge the GitOps diff before manually syncing the Prod migration Application."
