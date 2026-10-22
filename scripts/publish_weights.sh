#!/usr/bin/env bash
# Training device -> Trained Weights bucket.
# Uploads the Triton config and a new model version; Triton polls the bucket
# and switches to the newest version within ~60 s.
#
# Usage: scripts/publish_weights.sh <MODEL_NAME> <model.onnx> [VERSION]
#   MODEL_NAME: a directory under model_repository/ (e.g. swin_unetr_lung_cancer)
#   VERSION defaults to (latest published version + 1).
#
# Works on any machine with gcloud logged in (`gcloud auth login`); no Terraform needed
# when WEIGHTS_BUCKET is set:
#   WEIGHTS_BUCKET=<project>-ctseg-weights scripts/publish_weights.sh swin_unetr_lung_cancer model.onnx
# Set IMPERSONATE_SA=ctseg-trainer@<project>.iam.gserviceaccount.com to upload as the
# least-privilege trainer service account.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_NAME="${1:?usage: publish_weights.sh <MODEL_NAME> <model.onnx> [VERSION]}"
MODEL_FILE="${2:?usage: publish_weights.sh <MODEL_NAME> <model.onnx> [VERSION]}"
CONFIG="$ROOT/model_repository/$MODEL_NAME/config.pbtxt"

[[ -f "$CONFIG" ]] || { echo "no Triton config at $CONFIG" >&2; exit 1; }
[[ "$MODEL_FILE" == *.onnx ]] || { echo "expected an .onnx file (run scripts/export_model.py first)" >&2; exit 1; }

BUCKET="${WEIGHTS_BUCKET:-$(cd "$ROOT/terraform/1-infra" && terraform output -raw weights_bucket)}"

GCLOUD_ARGS=()
if [[ -n "${IMPERSONATE_SA:-}" ]]; then
  GCLOUD_ARGS+=(--impersonate-service-account="$IMPERSONATE_SA")
fi

DEST="gs://$BUCKET/model_repository/$MODEL_NAME"

if [[ $# -ge 3 ]]; then
  VERSION="$3"
else
  # `ls` fails when nothing has been published yet; that just means version 1.
  LATEST="$({ gcloud storage ls ${GCLOUD_ARGS[@]+"${GCLOUD_ARGS[@]}"} "$DEST/" 2>/dev/null || true; } \
    | sed -nE 's#.*/([0-9]+)/$#\1#p' | sort -n | tail -1)"
  VERSION=$(( ${LATEST:-0} + 1 ))
fi

# Model file first, config last: Triton only (re)loads once both are present.
gcloud storage cp ${GCLOUD_ARGS[@]+"${GCLOUD_ARGS[@]}"} "$MODEL_FILE" "$DEST/$VERSION/model.onnx"
gcloud storage cp ${GCLOUD_ARGS[@]+"${GCLOUD_ARGS[@]}"} "$CONFIG" "$DEST/config.pbtxt"

echo "Published $MODEL_NAME version $VERSION -> $DEST/$VERSION/model.onnx"
