#!/usr/bin/env bash
# Builds the gateway and controller images with Cloud Build (linux/amd64, no local Docker needed)
# and pushes them to Artifact Registry.
# Usage: scripts/build_images.sh [TAG]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-v$(date +%Y%m%d-%H%M%S)}"

cd "$ROOT/terraform/1-infra"
PROJECT_ID="$(terraform output -raw project_id)"
REPO="$(terraform output -raw image_repo)"
BUILD_SA="$(terraform output -json gsa_emails | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])')"

for svc in gateway controller; do
  gcloud builds submit "$ROOT/services/$svc" \
    --project "$PROJECT_ID" \
    --config "$ROOT/services/cloudbuild.yaml" \
    --substitutions "_IMAGE=$REPO/$svc:$TAG" \
    --service-account "projects/$PROJECT_ID/serviceAccounts/$BUILD_SA"
done

cat <<EOF

Put these in terraform/2-platform/terraform.tfvars:
gateway_image    = "$REPO/gateway:$TAG"
controller_image = "$REPO/controller:$TAG"
EOF
