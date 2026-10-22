"""Main Process / Controller: task orchestration and data coordination.

For each request:
  1. decode the base64 NIfTI CT volume and store it in the data bucket (ct/<job_id>/)
  2. preprocess exactly like the Swin UNETR training notebooks (see pipeline.py)
  3. sliding-window inference: 96^3 patches are batched to Triton over gRPC
  4. argmax, invert crop/orientation/resize -> mask on the original CT grid
  5. store the mask in the data bucket (masks/<job_id>/) and return it base64-encoded
"""

import base64
import gzip
import json
import logging
import os
import tempfile
import time
import uuid

import nibabel as nib
import numpy as np
import torch
import tritonclient.grpc as triton
from fastapi import FastAPI, HTTPException, Response
from google.cloud import storage
from nibabel.filebasedimages import ImageFileError
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel

from pipeline import Task, save_mask, segment

DATA_BUCKET = os.environ["DATA_BUCKET"]
TRITON_URL = os.environ["TRITON_URL"]
MODEL_INPUT_NAME = os.environ.get("MODEL_INPUT_NAME", "image")
MODEL_OUTPUT_NAME = os.environ.get("MODEL_OUTPUT_NAME", "logits")
TASKS = {name: Task.from_dict(cfg) for name, cfg in json.loads(os.environ["TASKS_JSON"]).items()}
DEFAULT_TASK = os.environ.get("DEFAULT_TASK", next(iter(TASKS)))

torch.set_num_threads(int(os.environ.get("TORCH_THREADS", "2")))

logging.basicConfig(level=logging.INFO, format='{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}')
log = logging.getLogger("controller")

JOBS = Counter("controller_jobs_total", "Segmentation jobs", ["task", "status"])
JOB_LATENCY = Histogram(
    "controller_job_duration_seconds",
    "End-to-end job time",
    ["task"],
    buckets=(5, 10, 30, 60, 120, 300, 600, 900),
)
TRITON_LATENCY = Histogram(
    "controller_triton_infer_duration_seconds", "Per-batch Triton call time", buckets=(0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10)
)
GCS_BYTES = Counter("controller_gcs_bytes_written_total", "Bytes written to the data bucket")

# Create every labelled series at 0 on startup. Otherwise a series first appears already
# incremented, and Prometheus rate()/histogram_quantile() never see that first job.
for _task in TASKS:
    JOB_LATENCY.labels(_task)
    for _status in ("succeeded", "rejected", "failed"):
        JOBS.labels(_task, _status)

app = FastAPI(title="CT Segmentation Controller")
gcs = storage.Client()
bucket = gcs.bucket(DATA_BUCKET)
triton_client = triton.InferenceServerClient(url=TRITON_URL)


class SegmentRequest(BaseModel):
    volume_b64: str  # .nii or .nii.gz bytes, base64-encoded
    task: str | None = None  # key of TASKS_JSON; defaults to DEFAULT_TASK


def _upload(path: str, data: bytes) -> None:
    bucket.blob(path).upload_from_string(data, content_type="application/octet-stream")
    GCS_BYTES.inc(len(data))


def _triton_predictor(model_name: str):
    def predict(patches: torch.Tensor) -> torch.Tensor:
        batch = np.ascontiguousarray(patches.cpu().numpy(), dtype=np.float32)
        inp = triton.InferInput(MODEL_INPUT_NAME, batch.shape, "FP32")
        inp.set_data_from_numpy(batch)
        out = triton.InferRequestedOutput(MODEL_OUTPUT_NAME)
        with TRITON_LATENCY.time():
            result = triton_client.infer(model_name, inputs=[inp], outputs=[out], client_timeout=120)
        return torch.from_numpy(result.as_numpy(MODEL_OUTPUT_NAME))

    return predict


@app.post("/segment")
def segment_volume(req: SegmentRequest):
    task_name = req.task or DEFAULT_TASK
    task = TASKS.get(task_name)
    if task is None:
        raise HTTPException(400, f"unknown task {task_name!r}; available: {sorted(TASKS)}")

    job_id = uuid.uuid4().hex
    start = time.perf_counter()
    try:
        raw = base64.b64decode(req.volume_b64, validate=True)
        nii_gz = raw if raw[:2] == b"\x1f\x8b" else gzip.compress(raw)
        _upload(f"ct/{job_id}/volume.nii.gz", nii_gz)

        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "volume.nii.gz")
            with open(src, "wb") as f:
                f.write(nii_gz)
            reference = nib.load(src)
            if len(reference.shape) != 3:
                raise HTTPException(400, f"expected a 3D volume, got shape {reference.shape}")

            mask = segment(src, task, _triton_predictor(task.triton_model))

            dst = os.path.join(tmp, "mask.nii.gz")
            save_mask(mask, reference, dst)
            with open(dst, "rb") as f:
                mask_bytes = f.read()

        mask_path = f"masks/{job_id}/mask.nii.gz"
        _upload(mask_path, mask_bytes)
    except HTTPException:
        JOBS.labels(task_name, "rejected").inc()
        raise
    except (ValueError, ImageFileError) as e:
        JOBS.labels(task_name, "rejected").inc()
        raise HTTPException(400, f"could not decode NIfTI volume: {e}")
    except triton.InferenceServerException as e:
        JOBS.labels(task_name, "failed").inc()
        log.error("job %s triton error: %s", job_id, e)
        raise HTTPException(503, f"inference failed ({task.triton_model}): {e.message()}")
    except Exception:
        JOBS.labels(task_name, "failed").inc()
        log.exception("job %s failed", job_id)
        raise

    elapsed = time.perf_counter() - start
    JOB_LATENCY.labels(task_name).observe(elapsed)
    JOBS.labels(task_name, "succeeded").inc()
    ids, counts = np.unique(mask, return_counts=True)
    voxels = {task.labels[i] if i < len(task.labels) else str(i): int(c) for i, c in zip(ids, counts) if i > 0}
    log.info("job %s task=%s shape=%s voxels=%s seconds=%.1f", job_id, task_name, mask.shape, voxels, elapsed)
    return {
        "job_id": job_id,
        "task": task_name,
        "shape": list(mask.shape),
        "labels": dict(enumerate(task.labels)),
        "voxels_per_label": voxels,
        "mask_uri": f"gs://{DATA_BUCKET}/{mask_path}",
        "mask_b64": base64.b64encode(mask_bytes).decode(),
        "seconds": round(elapsed, 2),
    }


@app.get("/results/{job_id}")
def results(job_id: str):
    if not job_id.isalnum():
        raise HTTPException(400, "invalid job id")
    blob = bucket.blob(f"masks/{job_id}/mask.nii.gz")
    if not blob.exists():
        raise HTTPException(404, "job not found")
    return {
        "job_id": job_id,
        "mask_uri": f"gs://{DATA_BUCKET}/{blob.name}",
        "mask_b64": base64.b64encode(blob.download_as_bytes()).decode(),
    }


@app.get("/tasks")
def tasks():
    return {"default": DEFAULT_TASK, "tasks": {name: dict(enumerate(t.labels)) for name, t in TASKS.items()}}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
