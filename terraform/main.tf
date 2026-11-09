# Enable required services

locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "sts.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com"
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# VPC

resource "google_compute_network" "vpc" {
  name                    = "moachu-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.apis]
}

# Subnet

resource "google_compute_subnetwork" "subnet" {
  name          = "moachu-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.30.0.0/20"
  }

  private_ip_google_access = true
}

# Cloud Router

resource "google_compute_router" "router" {
  name    = "moachu-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

# Cloud NAT

resource "google_compute_router_nat" "nat" {
  name                               = "moachu-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Artifact Registry

resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "moachu-images"
  description   = "Moachu Bakehaus Docker images"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

# GKE Cluster

resource "google_container_cluster" "gke" {
  name     = var.cluster_name
  location = var.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.subnet.id

  networking_mode = "VPC_NATIVE"

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "Public control plane access"
    }
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }

    http_load_balancing {
      disabled = false
    }
  }

  monitoring_config {
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS"
    ]
  }

  depends_on = [
    google_project_service.apis,
    google_compute_router_nat.nat
  ]
}

# GKE Node Pool

resource "google_container_node_pool" "primary" {
  name     = "moachu-node-pool"
  cluster  = google_container_cluster.gke.name
  location = var.zone

  initial_node_count = var.node_count

  autoscaling {
    min_node_count = 1
    max_node_count = 2
  }

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 30
    disk_type    = "pd-balanced"

    service_account = google_service_account.gke_nodes.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      environment = "dev"
      application = "moachu"
    }
  }
}

# GKE node service account

resource "google_service_account" "gke_nodes" {
  account_id   = "moachu-gke-nodes"
  display_name = "Moachu GKE Node Service Account"
}

resource "google_project_iam_member" "node_logging" {
  project = var.project_id
  role   = "roles/logging.logWriter"
  member = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "node_metrics" {
  project = var.project_id
  role   = "roles/monitoring.metricWriter"
  member = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "node_registry" {
  project = var.project_id
  role   = "roles/artifactregistry.reader"
  member = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# GitHub Actions service account

resource "google_service_account" "github_actions" {
  account_id   = "moachu-github-deploy"
  display_name = "GitHub Actions Deployment Account"
}

resource "google_project_iam_member" "github_artifact" {
  project = var.project_id
  role   = "roles/artifactregistry.writer"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_gke" {
  project = var.project_id
  role   = "roles/container.developer"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}

# Workload Identity Pool

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name               = "GitHub Actions Pool"

  depends_on = [google_project_service.apis]
}

# GitHub OIDC Provider

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  display_name = "GitHub Actions Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow the GitHub repository to impersonate the service account

resource "google_service_account_iam_member" "github_wif" {
  service_account_id = google_service_account.github_actions.name

  role = "roles/iam.workloadIdentityUser"

  member = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}