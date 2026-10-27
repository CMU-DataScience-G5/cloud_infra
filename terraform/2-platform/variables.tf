variable "state_bucket" {
  description = "GCS bucket holding Terraform state (same one used by 1-infra)."
  type        = string
}

# ---------------------------------------------------------------- Images

variable "gateway_image" {
  description = "Full image reference, e.g. us-central1-docker.pkg.dev/<project>/ctseg-images/gateway:v1"
  type        = string
}

variable "controller_image" {
  description = "Full image reference, e.g. us-central1-docker.pkg.dev/<project>/ctseg-images/controller:v1"
  type        = string
}

variable "triton_image" {
  description = "NVIDIA Triton image. Must match the ONNX opset / TorchScript version you export with."
  type        = string
  default     = "nvcr.io/nvidia/tritonserver:25.01-py3"
}

# ---------------------------------------------------------------- Scaling

variable "gateway_replicas" {
  type    = number
  default = 2
}

variable "controller_replicas" {
  type    = number
  default = 2
}

variable "triton_replicas" {
  description = "Set to 0 (with gpu_min_nodes = 0 in 1-infra) to release the GPU node when idle."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------- Models
# One entry per Swin UNETR task. Values mirror the training notebooks
# (Swin-UNETR/notebook/*.ipynb): Resized(spatial_size=resize), out_channels = length(labels),
# sliding_window_inference(roi 96^3, sw_batch_size, overlap). A task only works once its
# triton_model has been published to the weights bucket (scripts/publish_weights.sh).

variable "tasks" {
  type = map(object({
    triton_model  = string
    labels        = list(string)
    resize        = list(number)
    overlap       = optional(number, 0.8)
    sw_batch_size = optional(number, 4)
    hu_min        = optional(number, -175)
    hu_max        = optional(number, 250)
  }))
  default = {
    lung_cancer = {
      triton_model = "swin_unetr_lung_cancer"
      labels       = ["background", "cancer"]
      resize       = [340, 340, 340]
    }
    lung_lobes = {
      triton_model = "swin_unetr_lung_lobes"
      labels       = ["background", "right upper", "right middle", "right lower", "left upper", "left lower"]
      resize       = [128, 128, 128]
    }
  }
}

variable "default_task" {
  description = "Task used when a request doesn't name one."
  type        = string
  default     = "lung_cancer"
}

# ---------------------------------------------------------------- Gateway / TLS

variable "domain" {
  description = "Optional DNS name pointing at the gateway IP. When set, a Google-managed TLS certificate is provisioned."
  type        = string
  default     = ""
}

variable "monitoring_admin_user" {
  description = "Admin login for the public Grafana and Kibana UIs (password: terraform output -raw monitoring_admin_password)."
  type        = string
  default     = "admin"
}

variable "max_upload_mb" {
  description = "Largest request body (base64 CT volume) the gateway accepts."
  type        = number
  default     = 1024
}

variable "cors_allow_origins" {
  description = "Browser origins allowed to call the API, e.g. where the web frontend is hosted (\"https://viewer.example.com\"). Empty disables CORS."
  type        = list(string)
  default     = []
}
