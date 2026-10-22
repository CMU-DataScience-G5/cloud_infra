# 3D CT Tumor Segmentation on GCP

Terraform for the architecture in [docs/architecture.jpg](docs/architecture.jpg): Gateway → Controller → Triton (GPU) on GKE, with GCS buckets for data and weights, Prometheus + Grafana for metrics, and EFK for logs.

```
Client ──HTTP/base64──▶ GCLB (static IP) ─▶ Gateway (API key, routing) ─▶ Controller ──gRPC──▶ Triton (L4 GPU)
                                                                           │    ▲                     ▲
                                                                  CT/masks ▼    │                     │ poll model_repository/
                                                               gs://…-data ─────┘          gs://…-weights ◀── training pipeline
Prometheus ◀─ /metrics (gateway, controller, Triton GPU) · Grafana ◀─ Prometheus + Cloud Monitoring (GCS)
Fluentd (DaemonSet) ─▶ Elasticsearch ─▶ Kibana
```

| Diagram box | Implementation | Where |
|---|---|---|
| Gateway | FastAPI (API key auth) behind GKE Ingress, which provisions a Google external HTTP(S) load balancer. The gateway scales with an HPA. | `services/gateway`, `terraform/2-platform/gateway.tf` |
| Main Process / Controller | FastAPI service. It stores CT volumes and masks in GCS, runs the notebooks' MONAI preprocessing, sends 96³ sliding-window patches to Triton over gRPC, and maps the mask back onto the original CT grid. | `services/controller`, `controller.tf` |
| Triton Inference Server | `nvcr.io/nvidia/tritonserver` on a GPU node pool, serving the Swin UNETR models as ONNX. It reads `gs://<weights>/model_repository` and checks for new versions every 60 s. | `triton.tf`, `model_repository/` |
| Data Storage | GCS bucket `<project>-ctseg-data`. Objects are deleted after 30 days by default. | `1-infra/storage.tf` |
| Trained Weights | GCS bucket `<project>-ctseg-weights`, versioned | `1-infra/storage.tf` |
| Monitoring | kube-prometheus-stack, plus a provisioned Grafana dashboard covering HTTP throughput, Triton, GPU, pods and GCS | `monitoring.tf`, `dashboards/` |
| Logging | ECK (Elasticsearch + Kibana) and a Fluentd DaemonSet | `logging.tf` |
| Training pipeline | Runs on your own GPU machine (the `Swin-UNETR/` notebooks). It exports to ONNX and uploads to the weights bucket. | `scripts/export_model.py`, `scripts/publish_weights.sh` |

The Terraform is split into **two stages** because the Kubernetes and Helm providers need a running cluster:

- `terraform/1-infra`: APIs, VPC + Cloud NAT, private GKE cluster (CPU pool and GPU pool), buckets, Artifact Registry, service accounts and Workload Identity
- `terraform/2-platform`: namespaces, the three services, Prometheus/Grafana and EFK

## What you need to set up in the GCP console

You don't need to share any credentials with anyone. Everything authenticates with your own `gcloud` login.

1. **A project with billing enabled.** Note the project ID.
2. **Quotas.** New projects start too low for this stack. Enable the Compute Engine API first (`gcloud services enable compute.googleapis.com`), because the quotas below don't appear in the console until it is enabled. Then go to *IAM & Admin → Quotas & system limits* and request:
   - `GPUs (all regions)` (`GPUS_ALL_REGIONS`) ≥ 1. The default is 0.
   - `NVIDIA L4 GPUs` in your region (e.g. `us-central1`) ≥ 1. If you plan to use `gpu_spot = true`, request `Preemptible NVIDIA L4 GPUs` instead.
   - `CPUs (all regions)` (`CPUS_ALL_REGIONS`) ≥ 32. The default is 12, but the system nodes plus the GPU node already need 16.
   - `Persistent Disk SSD (GB)` in your region ≥ 1000. The default is 250, while node boot disks (2 × 100 GB system + 200 GB GPU, all `pd-balanced`) plus the Prometheus, Elasticsearch and Grafana volumes need about 465 GB.

   Approval can take minutes to days, so request these first.
3. **Your role**: Owner on the project, or Editor + Project IAM Admin + Service Account Admin.
4. **Local tools**: `gcloud`, `terraform >= 1.6`, `kubectl`, and the `gke-gcloud-auth-plugin` (`gcloud components install gke-gcloud-auth-plugin`).
   If `gcloud storage` commands crash with `module 'ssl' has no attribute 'PROTOCOL_TLSv1'`, gcloud is running on Python 3.14. Point it at an older Python, for example with `export CLOUDSDK_PYTHON=/opt/homebrew/bin/python3.13` in `~/.zshrc`.
5. **Log in:**
   ```bash
   gcloud auth login
   gcloud auth application-default login   # Terraform uses these credentials
   ```

## Deploy

```bash
# 0. State bucket (one time)
scripts/bootstrap.sh <PROJECT_ID> us-central1          # creates gs://<PROJECT_ID>-tfstate

# 1. Infrastructure (~15 min)
cd terraform/1-infra
cp terraform.tfvars.example terraform.tfvars            # set project_id
terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
terraform apply
$(terraform output -raw get_credentials_command)        # configure kubectl
cd ../..

# 2. Build images with Cloud Build (no local Docker needed)
scripts/build_images.sh v1                              # prints the image refs

# 3. Publish model weights (see "Training and publishing weights" below)
python scripts/export_model.py --weights Swin-UNETR/data/best_metric_model.pth --out-channels 2 --output build/cancer.onnx
scripts/publish_weights.sh swin_unetr_lung_cancer build/cancer.onnx

# 4. Platform: services, monitoring, logging (~10 min)
cd terraform/2-platform
cp terraform.tfvars.example terraform.tfvars            # set state_bucket + image refs
terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
terraform apply
```

The Ingress takes about 5–10 minutes after apply before the load balancer starts answering.

## Use it

```bash
cd terraform/2-platform
export CTSEG_URL=$(terraform output -raw gateway_url)
export CTSEG_API_KEY=$(terraform output -raw api_key)
cd ../..
python scripts/client.py lung_095.nii.gz lung_095_mask.nii.gz --task lung_cancer
```

API:

- `POST /v1/segment` with header `X-API-Key` and body `{"volume_b64": "<base64 .nii/.nii.gz>", "task": "lung_cancer"}`. It returns `job_id`, `mask_b64` (a `.nii.gz`), `mask_uri`, `voxels_per_label` and `seconds`.
- `GET /v1/results/{job_id}` fetches a stored mask again.
- `GET /v1/tasks` lists the tasks and their labels.

The mask has the same shape and affine as the uploaded CT, so you can overlay the two directly in OHIF or 3D Slicer and render them in 3D locally.

## Models (Swin UNETR)

The serving pipeline reproduces `test_transforms` and the inference cell from `Swin-UNETR/notebook/*.ipynb`:

1. Scale HU from [-175, 250] to [0, 1].
2. Crop to the foreground.
3. Reorient to RAS.
4. Resize the whole volume to the task's `resize`.
5. Run `sliding_window_inference` with a 96³ ROI, `sw_batch_size` 4 and `overlap` 0.8. Triton serves the patches.
6. Take the argmax.

After that, the controller inverts the resize, orientation and crop, so the mask lands on the original CT grid. The original `inferer.py` instead saved masks in the resized space with an identity affine.

| Task | Triton model | Notebook | Classes | `resize` |
|---|---|---|---|---|
| `lung_cancer` (default) | `swin_unetr_lung_cancer` | `cancer` | background, cancer | 340³ |
| `lung_lobes` | `swin_unetr_lung_lobes` | `lung lobes` | background + 5 lobes | 128³ |

Both models are `SwinUNETR(in_channels=1, feature_size=48)`, and they differ only in `out_channels`. To add a task, such as the 4-class covid model:

1. Add an entry to the `tasks` variable in `terraform/2-platform/variables.tf`.
2. Copy a `model_repository/*/config.pbtxt` and change `name` and the output `dims`.

A task only works once its model has been published. Until then, requests for it return 503.

**Speed:** overlap 0.8 on a 340³ volume is 2,744 patches. A lower `overlap` in `tasks` is much faster (0.5 gives 343 patches) at a small accuracy cost.

## Training and publishing weights

Training happens on your own GPU machine. The cloud only receives the exported model:

```bash
# On the training machine (needs torch, monai>=1.5, einops, onnx, onnxruntime, and gcloud logged in)
python scripts/export_model.py --weights best_metric_model.pth --out-channels 2 --output cancer.onnx
WEIGHTS_BUCKET=<PROJECT_ID>-ctseg-weights scripts/publish_weights.sh swin_unetr_lung_cancer cancer.onnx
```

- `export_model.py` loads the notebook's `state_dict`, exports ONNX with a dynamic batch dimension, and refuses to continue unless ONNX Runtime matches PyTorch.
- `publish_weights.sh` uploads to `model_repository/<model>/<N+1>/model.onnx`. Triton switches to it within about 60 s, with no redeploy.
- To roll back, delete the newest version directory from the bucket.
- The training machine needs only this repo's `scripts/` and `model_repository/` folders, plus a `gcloud` login. That login can be your own account, or, for least privilege, `IMPERSONATE_SA=ctseg-trainer@<PROJECT_ID>.iam.gserviceaccount.com`. Impersonation requires `roles/iam.serviceAccountTokenCreator` on that service account.

## Observability

Grafana and Kibana are public over HTTPS. Each has its own login, and one admin account works for both:

```bash
cd terraform/2-platform
terraform output monitoring_urls                  # https://grafana.<ip>.sslip.io, https://kibana.<ip>.sslip.io
terraform output -raw monitoring_admin_user       # admin
terraform output -raw monitoring_admin_password
```

- **Hostnames** use `sslip.io` (`grafana.1-2-3-4.sslip.io` resolves to `1.2.3.4`), so you don't need to buy a domain. Each UI has a reserved static IP, a Google-managed certificate, and an HTTP→HTTPS redirect. After the first apply, the certificate takes 15–60 minutes to issue.
- **Grafana:** open *Dashboards → CT Segmentation → CT Segmentation Service*. It shows HTTP throughput and latency, job and Triton latency, GPU utilization, memory and power, CPU and memory per pod, and bucket size and object count. The bucket metrics come from Cloud Monitoring, which updates them about once a day.
- **Kibana:** the first time, create a data view under *Stack Management → Data Views* with the pattern `k8s-logs-*` and timestamp field `@timestamp`. Then filter in *Discover*, e.g. `kubernetes.namespace_name : "ctseg"`. Fluentd replaces dots in label keys (`app.kubernetes.io/name` becomes `app_kubernetes_io/name`), because otherwise Elasticsearch rejects logs from pods with a plain `app` label.
- **Prometheus** has no login of its own, so it stays private. Query it in Grafana under *Explore → Prometheus*, or with `terraform output access_commands` (port-forward).
- **Cloud Logging:** logs also go there automatically.
- **Hardening:** the logins are the only protection. For anything beyond a demo, restrict who can reach the load balancers, for example with Cloud Armor allowlists or IAP.

## Cost control

| Item | Approx. cost (us-central1) |
|---|---|
| g2-standard-8 + 1×L4 | ~$0.85/h on-demand, ~$0.30/h spot |
| 2× e2-standard-4 system nodes | ~$0.27/h |
| GKE zonal cluster | free tier covers one zonal cluster |
| Load balancer + NAT | ~$0.05/h + traffic |

To stop paying for the GPU when idle, set `triton_replicas = 0` in 2-platform and apply. The autoscaler then removes the GPU node because `gpu_min_nodes = 0`.

To tear everything down:

```bash
cd terraform/2-platform && terraform destroy
cd ../1-infra && terraform destroy
```

Set `force_destroy_buckets = true` first if the buckets contain data.

## Hardening for production

This setup is suitable for a course project or demo, not for production. Before real use:

- Use `domain` to get HTTPS (it provisions a managed certificate). Add Cloud Armor and IAP or OAuth in front of the gateway.
- Restrict `master_authorized_cidrs`.
- Enable GKE Dataplane V2 and add NetworkPolicies.
- CT data may contain PHI. Apply de-identification before upload, and use CMEK on the buckets.
- For very large volumes, switch to signed-URL uploads (client → GCS directly) plus asynchronous jobs (Pub/Sub) instead of base64 over HTTP.
