#!/usr/bin/env bash
# One-time setup: creates the GCS bucket that stores Terraform state.
# Usage: scripts/bootstrap.sh <PROJECT_ID> [REGION]
set -euo pipefail

PROJECT_ID="${1:?usage: bootstrap.sh <PROJECT_ID> [REGION]}"
REGION="${2:-us-central1}"
STATE_BUCKET="${PROJECT_ID}-tfstate"

gcloud config set project "$PROJECT_ID"
gcloud services enable storage.googleapis.com cloudresourcemanager.googleapis.com serviceusage.googleapis.com

if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
fi

echo "State bucket: ${STATE_BUCKET}"
echo "Next: cd terraform/1-infra && terraform init -backend-config=\"bucket=${STATE_BUCKET}\""
