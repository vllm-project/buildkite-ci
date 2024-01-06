provider "google" {
  project = "vllm-405802"
  region  = "us-central1"
}

provider "google-beta" {
  project = "vllm-405802"
  region  = "us-central1"
}

variable "project_id" {
  default = "vllm-405802"
}

variable "buildkite_agent_token" {
  type      = string
  sensitive = true
}

resource "google_service_account" "artifact_registry_sa" {
  account_id   = "artifact-registry-sa"
  display_name = "Service Account for Artifact Registry"
  project      = var.project_id
}

resource "google_service_account_key" "artifact_registry_sa_key" {
  service_account_id = google_service_account.artifact_registry_sa.name
}

resource "google_project_iam_member" "artifact_registry_iam" {
  project = var.project_id
  role    = "roles/artifactregistry.repoAdmin"
  member  = "serviceAccount:${google_service_account.artifact_registry_sa.email}"
}

resource "google_compute_instance_template" "builder_template" {
  name        = "builder-template"
  machine_type = "e2-standard-16"  # 16 vCPUs, 64 GB RAM

  scheduling {
    preemptible       = true
    automatic_restart = false
  }

  metadata = {
    "startup-script" = <<-EOF
      #!/bin/bash

      apt-get update
      apt-get install -y curl

      curl -o- https://get.docker.com/ | bash -

      curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/32A37959C2FA5C3C99EFBC32A79206696452D198 | sudo gpg --dearmor -o /usr/share/keyrings/buildkite-agent-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/buildkite-agent-archive-keyring.gpg] https://apt.buildkite.com/buildkite-agent stable main" | sudo tee /etc/apt/sources.list.d/buildkite-agent.list
      apt-get update
      apt-get install -y buildkite-agent

      sudo usermod -a -G docker buildkite-agent
      sudo -u buildkite-agent gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

      sudo sed -i "s/xxx/${var.buildkite_agent_token}/g" /etc/buildkite-agent/buildkite-agent.cfg
      systemctl enable buildkite-agent
      systemctl start buildkite-agent
    EOF
  }

  disk {
    source_image = "debian-cloud/debian-11"  # Replace with your desired image
    boot         = true
    disk_size_gb = 512
  }

  network_interface {
    network = "default"
    access_config {
      // This block's existence will create ephemeral IP allowing egress internet access
    }
  }

  service_account {
    email  = google_service_account.artifact_registry_sa.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_region_instance_group_manager" "builder_group" {
  name               = "builder-group"
  base_instance_name = "builder-instance"
  region = "us-central1"

  version {
    instance_template  = google_compute_instance_template.builder_template.self_link_unique
  }

  target_size        = 0
}

resource "google_artifact_registry_repository" "my-repo" {
  provider      = google-beta

  location      = "us-central1"
  repository_id = "vllm-ci-test-repo"
  description   = "Hosting images for vLLM CI test"
  format        = "DOCKER"

  cleanup_policies {
    id     = "delete-old-images"
    action = "DELETE"
    condition {
      older_than   = "604800s" // 7 days
    }
  }
}