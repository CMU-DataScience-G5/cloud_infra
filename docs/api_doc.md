# CT Segmentation API

HTTP API for 3D CT tumor segmentation. You upload a CT volume (NIfTI). A Swin UNETR model runs on a GPU (NVIDIA Triton, TensorRT FP16), and you get back a segmentation mask on **the same voxel grid as your input**, so you can overlay it directly in OHIF, 3D Slicer or ITK-SNAP.

- **Base URL:** `http://34.110.150.32`
- **Version:** `v1`
- **Format:** JSON request and response bodies (`Content-Type: application/json`)

---

## Quick start

```bash
export CTSEG_URL=http://34.110.150.32
export CTSEG_API_KEY=<your API key>

# Which models are available?
curl -H "X-API-Key: $CTSEG_API_KEY" $CTSEG_URL/v1/tasks

# Segment a scan (returns after ~4 minutes)
python scripts/client.py lung_095.nii.gz lung_095_mask.nii.gz --task lung_cancer
```

`scripts/client.py` uses only the Python standard library. See [Examples](#examples) for curl and plain Python.

---

## Authentication

Every endpoint except `GET /healthz` requires an API key. Send it in either header:

```
X-API-Key: <key>
Authorization: Bearer <key>
```

A missing or wrong key returns `401 {"detail": "invalid or missing API key"}`.

Ask the service operator for a key. Operators can read it with `terraform output -raw api_key` in `terraform/2-platform`.

> **Security:** the endpoint is currently plain HTTP, so the key and the CT data travel unencrypted. Don't send identifiable patient data until HTTPS is enabled. The deployment supports a managed TLS certificate through the `domain` Terraform variable.

---

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | [`/v1/segment`](#post-v1segment) | Segment a CT volume and return the mask |
| `GET` | [`/v1/results/{job_id}`](#get-v1resultsjob_id) | Fetch the mask of a previous job |
| `GET` | [`/v1/tasks`](#get-v1tasks) | List the available tasks (models) and their labels |
| `GET` | [`/healthz`](#get-healthz) | Liveness check (no auth) |

Any other path returns `404` from the load balancer.

---

### `POST /v1/segment`

Runs segmentation synchronously. The response arrives when the mask is ready.

#### Request body

| Field | Type | Required | Description |
|---|---|---|---|
| `volume_b64` | string | yes | The CT file, base64-encoded. Accepts `.nii.gz` or uncompressed `.nii`. Must be a **3D** volume in Hounsfield units. |
| `task` | string | no | Task name from [`/v1/tasks`](#get-v1tasks). Defaults to `lung_cancer`. |

```json
{
  "volume_b64": "H4sIAAAAAAAAA+3BMQEAAADCoPVPbQ...",
  "task": "lung_cancer"
}
```

#### Response `200 OK`

| Field | Type | Description |
|---|---|---|
| `job_id` | string | 32-character hex ID. Use it with [`/v1/results/{job_id}`](#get-v1resultsjob_id). |
| `task` | string | The task that ran |
| `shape` | int[3] | Mask shape, identical to the input volume's shape |
| `labels` | object | Class ID → label name. Keys are strings (`"0"`, `"1"`, …). |
| `voxels_per_label` | object | Label name → number of voxels predicted. Background is omitted, so this is `{}` if nothing was found. |
| `mask_uri` | string | Where the mask is stored server-side (`gs://…`). For reference only; clients can't read it. |
| `mask_b64` | string | The mask as a base64-encoded `.nii.gz` |
| `seconds` | number | Server-side processing time |

```json
{
  "job_id": "79d81eddec624e67bc6789f9146b62c3",
  "task": "lung_cancer",
  "shape": [512, 512, 231],
  "labels": { "0": "background", "1": "cancer" },
  "voxels_per_label": { "cancer": 4494 },
  "mask_uri": "gs://datasciencef26-ctseg-data/masks/79d81eddec624e67bc6789f9146b62c3/mask.nii.gz",
  "mask_b64": "H4sIAAAAAAAA/+3dwY...",
  "seconds": 227.76
}
```

#### The returned mask

- **Format:** NIfTI-1, gzip-compressed, `uint8`. Each voxel holds a class ID from `labels`; `0` is background.
- **Geometry:** the same shape, affine, orientation and voxel spacing as the uploaded CT. The server undoes its internal crop, reorientation and resize before returning, so no resampling is needed on the client.
- **Size:** typically a few hundred KB, because masks compress well.

#### What happens on the server

1. The server stores the CT and decodes it.
2. It preprocesses the volume the same way the model was trained: HU clipped to [-175, 250] and scaled to [0, 1], foreground crop, RAS orientation, resize to the task's working size.
3. It runs a 96³ sliding window with 0.8 overlap; the patches go to the GPU in batches of 4.
4. It takes the argmax, maps the mask back to the original grid, then stores and returns it.

---

### `GET /v1/results/{job_id}`

Returns the mask of a finished job. This is useful if the original request's connection dropped: the job still completes, and its mask is saved.

#### Response `200 OK`

```json
{
  "job_id": "79d81eddec624e67bc6789f9146b62c3",
  "mask_uri": "gs://datasciencef26-ctseg-data/masks/79d81eddec624e67bc6789f9146b62c3/mask.nii.gz",
  "mask_b64": "H4sIAAAAAAAA/+3dwY..."
}
```

| Status | When |
|---|---|
| `400` | `job_id` isn't alphanumeric |
| `404` | No such job, or it has expired (see [Data retention](#data-retention)) |

> A job whose connection dropped can only be fetched if you know its `job_id`. The ID is returned only in the `200` response of `/v1/segment`, and in the server logs.

---

### `GET /v1/tasks`

Lists the available tasks and the class labels of each one.

```json
{
  "default": "lung_cancer",
  "tasks": {
    "lung_cancer": { "0": "background", "1": "cancer" },
    "lung_lobes": {
      "0": "background", "1": "right upper", "2": "right middle",
      "3": "right lower", "4": "left upper", "5": "left lower"
    }
  }
}
```

| Task | Model | Working size | Status |
|---|---|---|---|
| `lung_cancer` | Swin UNETR, 2 classes (MSD Task06 Lung) | 340³ | **Available** |
| `lung_lobes` | Swin UNETR, 6 classes | 128³ | Listed but **not yet deployed**: requests return `503` until its weights are published |

---

### `GET /healthz`

Needs no authentication. It returns `200 {"status": "ok"}` when the gateway is up. It doesn't check whether the model is loaded; a model that isn't ready shows up as `503` on `/v1/segment`.

---

## Errors

Errors are JSON with a `detail` field:

```json
{ "detail": "unknown task 'lungs'; available: ['lung_cancer', 'lung_lobes']" }
```

| Status | Meaning | What to do |
|---|---|---|
| `400` | Bad input: unknown `task`, invalid base64, not a readable NIfTI, or not a 3D volume | Fix the request; don't retry as-is |
| `401` | Missing or wrong API key | Check the `X-API-Key` header |
| `404` | Unknown `job_id` (results endpoint) | — |
| `413` | Request body over 1024 MB | Send `.nii.gz` instead of `.nii` |
| `422` | Malformed JSON, or `volume_b64` missing. Here `detail` is a list of field errors. | Fix the request body |
| `502` | The gateway lost its connection to the backend, or the load balancer had no healthy backend (e.g. during a restart) | Retry after a short wait. If you had a `job_id`, check `/v1/results/{job_id}` first. |
| `503` | The model isn't loaded. This happens for about 5–10 min after a GPU restart while TensorRT compiles, or for a task that isn't deployed. | Retry with backoff (e.g. every 60 s) |
| `504` | The backend took longer than 840 s | Retry later; report it if it persists |

---

## Limits and timing

| | |
|---|---|
| **Max request body** | 1024 MB, which is the base64 JSON, about 1.33× the file size |
| **Gateway timeout** | 840 s per request (load balancer: 900 s) |
| **Typical time, `lung_cancer`** | **~4 min** (228 s server-side for a 512×512×231 CT on one NVIDIA L4). The time is almost independent of the input size, because every volume is resized to 340³ internally. |
| **Concurrency** | One GPU. Requests arriving at the same time share it, so each one takes longer. Send scans one at a time, or allow for queueing. |

**Client settings:** set your HTTP client's read timeout to at least **900 s**, and keep the connection open until the response arrives. Many libraries default to 30–60 s.

---

## Model accuracy

On held-out validation case `lung_095` (MSD Task06), served through this API: **Dice 0.691**, precision 0.784, recall 0.618. The model tends to under-segment, and it can miss very small tumors entirely. Treat its output as research output, not as a diagnostic result.

---

## Data retention

Uploaded CT volumes and returned masks are stored in the service's GCS data bucket and **deleted automatically after 30 days**. After that, `/v1/results/{job_id}` returns `404`.

---

## Examples

### curl

```bash
python3 -c 'import base64,json,sys; print(json.dumps({"volume_b64": base64.b64encode(open(sys.argv[1],"rb").read()).decode(), "task": "lung_cancer"}))' \
  lung_095.nii.gz > request.json

curl --max-time 900 -X POST "$CTSEG_URL/v1/segment" \
  -H "X-API-Key: $CTSEG_API_KEY" -H "Content-Type: application/json" \
  --data-binary @request.json -o response.json

python3 -c 'import base64,json; r=json.load(open("response.json")); open("mask.nii.gz","wb").write(base64.b64decode(r["mask_b64"])); print(r["job_id"], r["voxels_per_label"], r["seconds"])'
```

### Python (`requests`)

```python
import base64
import requests

URL = "http://34.110.150.32"
HEADERS = {"X-API-Key": "<your API key>"}

with open("lung_095.nii.gz", "rb") as f:
    body = {"volume_b64": base64.b64encode(f.read()).decode(), "task": "lung_cancer"}

r = requests.post(f"{URL}/v1/segment", json=body, headers=HEADERS, timeout=900)
r.raise_for_status()
result = r.json()

with open("lung_095_mask.nii.gz", "wb") as f:
    f.write(base64.b64decode(result["mask_b64"]))
print(result["job_id"], result["voxels_per_label"], f'{result["seconds"]:.0f} s')
```

### Fetching a previous result

```bash
curl -H "X-API-Key: $CTSEG_API_KEY" "$CTSEG_URL/v1/results/79d81eddec624e67bc6789f9146b62c3" \
  | python3 -c 'import base64,json,sys; open("mask.nii.gz","wb").write(base64.b64decode(json.load(sys.stdin)["mask_b64"]))'
```

### Viewing the result

The mask shares the CT's geometry, so you can load both files and overlay them:

- **3D Slicer:** *File → Add Data*, choose both files, and tick **LabelMap** for the mask.
- **ITK-SNAP:** open the CT as the main image, then *Segmentation → Open Segmentation* for the mask.
- **Python:** `nibabel.load("mask.nii.gz").get_fdata()` gives the label array, aligned voxel-for-voxel with the CT.
