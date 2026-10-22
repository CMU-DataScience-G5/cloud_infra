data "terraform_remote_state" "infra" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "ctseg/infra"
  }
}

locals {
  infra = data.terraform_remote_state.infra.outputs
}

provider "google" {
  project = local.infra.project_id
  region  = local.infra.region
}

data "google_client_config" "current" {}

data "google_container_cluster" "this" {
  name     = local.infra.cluster_name
  location = local.infra.cluster_location
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${data.google_container_cluster.this.endpoint}"
    token                  = data.google_client_config.current.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  }
}
