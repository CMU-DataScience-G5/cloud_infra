# System architecture

The CT segmentation service as deployed on GCP project `datasciencef26` and managed by Terraform (`terraform/1-infra` and `terraform/2-platform`). For the original design sketch, see [architecture.jpg](architecture.jpg). For the client API, see [api_doc.md](api_doc.md).

## Overview

How a scan travels from a client to the GPU and back, and where models and images come from.

```mermaid
flowchart TB
    CLIENT["Client app<br/>OHIF · 3D Slicer · scripts/client.py"]
    TRAIN["Training device (off-cloud)<br/>Swin-UNETR notebooks → export_model.py"]

    subgraph GCP["Google Cloud · project datasciencef26 · us-central1"]
        LB_API["API load balancer · HTTP<br/>34.110.150.32<br/>allowlist: /v1/*, /healthz"]

        subgraph GKE["GKE cluster ctseg-gke · private nodes · Workload Identity"]
            direction LR
            subgraph SYS["system pool · e2-standard-4 × 2–4"]
                GW["Gateway × 2<br/>API-key auth · routing"]
                CTRL["Controller × 2<br/>MONAI pre/post-processing<br/>sliding window 96³"]
            end
            subgraph GPUPOOL["gpu pool · g2-standard-8 + L4 · zones a/b/c"]
                TRITON["Triton Inference Server<br/>Swin UNETR · TensorRT FP16"]
            end
        end

        subgraph STORE["Storage"]
            direction LR
            GCS_DATA[("GCS ctseg-data<br/>ct/ · masks/ · 30-day retention")]
            GCS_W[("GCS ctseg-weights<br/>model_repository/ · versioned")]
            AR[("Artifact Registry<br/>gateway · controller images")]
        end

        CB["Cloud Build"]
        NAT["Cloud NAT"]
    end

    REG["Public registries<br/>nvcr.io · docker.io"]

    CLIENT -- "POST /v1/segment<br/>NIfTI (base64) · X-API-Key" --> LB_API
    LB_API --> GW
    GW -- "HTTP :8080" --> CTRL
    CTRL -- "gRPC :8001<br/>batches of 4 patches" --> TRITON
    CTRL -- "save CT + mask" --> GCS_DATA
    TRITON -- "load model, poll 60 s" --> GCS_W
    TRAIN -- "publish_weights.sh" --> GCS_W
    CB -- "build + push" --> AR
    AR -. "image pull" .-> SYS
    GKE -. "egress" .-> NAT -.-> REG
```

**Legend:** solid arrows are the request and model data path; dashed arrows are image pulls and outbound traffic.

## Observability

Metrics and logs, and how the operator reaches them. The Grafana and Kibana UIs are public over HTTPS with an admin login; Prometheus stays private.

```mermaid
flowchart LR
    ADMIN["Operator browser"]

    subgraph EDGE["HTTPS load balancers · Google-managed certs"]
        direction TB
        LB_G["grafana.136-82-70-130.sslip.io"]
        LB_K["kibana.8-233-83-11.sslip.io"]
    end

    subgraph SRC["Sources (ns ctseg + every node)"]
        direction TB
        GW["Gateway<br/>HTTP throughput · latency"]
        CTRL["Controller<br/>jobs · Triton call time · GCS bytes"]
        TRITON["Triton<br/>GPU util · memory · power"]
        NODES["Container stdout/stderr<br/>(all nodes)"]
    end

    subgraph METRICS["ns monitoring"]
        direction TB
        PROM["Prometheus<br/>scrapes /metrics"]
        GRAF["Grafana<br/>CT Segmentation dashboard"]
        AM["Alertmanager"]
    end

    subgraph LOGS["ns logging"]
        direction TB
        FLU["Fluentd DaemonSet"]
        ES["Elasticsearch 9 (ECK)"]
        KIB["Kibana"]
    end

    CM["Cloud Monitoring<br/>GCS bucket size · objects"]

    GW -. "/metrics" .-> PROM
    CTRL -. "/metrics" .-> PROM
    TRITON -. "/metrics :8002" .-> PROM
    PROM --> GRAF
    PROM --> AM
    CM -.-> GRAF
    NODES -. "tail" .-> FLU --> ES --> KIB
    ADMIN --> LB_G --> GRAF
    ADMIN --> LB_K --> KIB
```

## Request flow: `POST /v1/segment`

Timings are from a real run on `lung_095` (512×512×231 CT, TensorRT FP16, 1× L4).

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant LB as API load balancer
    participant G as Gateway
    participant K as Controller
    participant D as GCS ctseg-data
    participant T as Triton (L4 GPU)

    C->>LB: POST /v1/segment {volume_b64, task}
    LB->>G: forward (backend timeout 900 s)
    G->>G: check X-API-Key, body ≤ 1024 MB
    G->>K: POST /segment (timeout 840 s)
    K->>D: save ct/JOB_ID/volume.nii.gz
    K->>K: HU clip [-175, 250] → [0,1], crop foreground,<br/>RAS orientation, resize to 340³
    loop 686 batches × 4 patches (96³, overlap 0.8) — ~3.5 min
        K->>T: gRPC infer [4,1,96,96,96]
        T-->>K: logits [4,2,96,96,96]
    end
    K->>K: stitch, argmax, invert resize / orientation / crop<br/>→ mask on original CT grid
    K->>D: save masks/JOB_ID/mask.nii.gz
    K-->>G: 200 {job_id, mask_b64, voxels_per_label, seconds}
    G-->>LB: 200
    LB-->>C: 200 (~234 s end to end)
```

## Model lifecycle

```mermaid
flowchart LR
    NB["Train on own GPU<br/>(Swin-UNETR notebook)"] --> PTH["best_metric_model.pth"]
    PTH --> EXP["scripts/export_model.py<br/>ONNX, dynamic batch<br/>checked vs PyTorch"]
    EXP --> PUB["scripts/publish_weights.sh"]
    PUB --> BUCKET[("gs://…-ctseg-weights/<br/>model_repository/<br/>swin_unetr_lung_cancer/N/model.onnx")]
    BUCKET -- "poll every 60 s" --> TR["Triton loads version N<br/>builds TensorRT FP16 engine<br/>(~5 min, warm-up batch 4)"]
    TR --> LIVE["Served by /v1/segment"]
    BUCKET -. "rollback: delete version N" .-> TR
```

## Component reference

| Layer | Component | Where it's defined |
|---|---|---|
| Edge | 3 GKE Ingresses → Google external HTTP(S) LBs. The API path allowlist is `/v1/*` and `/healthz`; Grafana and Kibana use HTTPS with a redirect. | `2-platform/gateway.tf`, `ui.tf` |
| Network | VPC `ctseg-vpc`, private nodes, Cloud NAT for egress, 3 reserved global IPs | `1-infra/network.tf` |
| Compute | GKE zonal cluster, `system` pool (e2-standard-4, 2–4 nodes), `gpu` pool (g2-standard-8 + L4, zones a/b/c, 0–2 nodes) | `1-infra/gke.tf` |
| App | Gateway, Controller and Triton Deployments. Gateway and Controller have HPAs, PDBs, `safe-to-evict: false` and a 900 s graceful shutdown. | `2-platform/gateway.tf`, `controller.tf`, `triton.tf` |
| Model | Swin UNETR ONNX on Triton 25.01, TensorRT FP16, engine cache in an emptyDir | `model_repository/*/config.pbtxt` |
| Storage | GCS data bucket (30-day retention) and weights bucket (versioned); Artifact Registry | `1-infra/storage.tf` |
| Identity | One service account per workload via Workload Identity: controller (data bucket), triton (weights bucket, read-only), grafana (monitoring viewer), trainer (weights bucket), build (Artifact Registry push) | `1-infra/iam.tf` |
| Metrics | kube-prometheus-stack (Prometheus, Grafana, Alertmanager), scraping annotated pods and Triton GPU metrics; Cloud Monitoring data source for GCS | `2-platform/monitoring.tf` |
| Logs | ECK Elasticsearch 9 + Kibana; Fluentd DaemonSet (ES 8 client, label de-dotting) | `2-platform/logging.tf`, `values/fluentd.yaml` |
