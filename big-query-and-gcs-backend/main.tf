terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.49.0"
    }
  }
}

provider "google" {
  # Configuration options
}

variable "folder_id" {
  type = string
}

variable "backend_prefix" {
  type = string
}

variable "billing_account_id" {
  type = string
}

variable "gcp_region" {
  type = string
}

locals {
  backend_folder_display_name = "${var.backend_prefix}-bq-driver-folder"
  service_project_name        = "main-${var.backend_prefix}-bq-driver"
  service_project_id          = "${var.backend_prefix}-bq-driver"
  service_account_id          = substr("${var.backend_prefix}-main-service-acc", 0, 30)
  service_query_account_id    = substr("${var.backend_prefix}-query-history-acc", 0, 30)
}

variable "services" {
  type    = list(any)
  default = [
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "cloudbilling.googleapis.com",
    "analyticshub.googleapis.com",
    "bigquery.googleapis.com",
  ]
}

data "google_folder" "existing_folder" {
  folder = "folders/${var.folder_id}"
}

resource "google_project" "service_project_in_a_folder" {
  name            = local.service_project_name
  project_id      = local.service_project_id
  folder_id       = data.google_folder.existing_folder.folder_id
  billing_account = var.billing_account_id
}

resource "google_project_service" "services" {
  for_each                   = toset(var.services)
  project                    = google_project.service_project_in_a_folder.project_id
  service                    = each.key
  disable_dependent_services = false
  disable_on_destroy         = false
  depends_on                 = [google_project.service_project_in_a_folder]
}

resource "google_service_account" "service_account" {
  account_id  = local.service_account_id
  description = "Service account to managing keboola backend projects"
  project     = google_project.service_project_in_a_folder.project_id
}

resource "google_folder_iam_member" "folder_service_acc_project_creator_role" {
  folder = data.google_folder.existing_folder.name
  role   = "roles/resourcemanager.projectCreator"
  member = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_folder_iam_member" "folder_service_acc_project_list_role" {
  folder = data.google_folder.existing_folder.name
  role   = "roles/browser"
  member = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_billing_account_iam_member" "billing_acc_binding" {

  billing_account_id = var.billing_account_id
  member             = "serviceAccount:${google_service_account.service_account.email}"
  role               = "roles/billing.user"
}

output "service_project_id" {
  value = google_project.service_project_in_a_folder.project_id
}

resource "google_storage_bucket" "kbc_file_storage_backend" {
  name                     = "${var.backend_prefix}-files-bq-driver"
  project                  = google_project.service_project_in_a_folder.project_id
  location                 = var.gcp_region
  storage_class            = "STANDARD"
  force_destroy            = true
  public_access_prevention = "enforced"
  versioning {
    enabled = false
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age            = 2
      matches_prefix = ["exp-2/"]
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      age            = 15
      matches_prefix = ["exp-15/"]
    }
  }
}

output "file_storage_bucket_id" {
  value = google_storage_bucket.kbc_file_storage_backend.id
}

resource "google_project_iam_member" "prj_service_acc_owner" {
  project = google_project.service_project_in_a_folder.project_id
  role    = "roles/owner"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "prj_service_acc_objAdm" {
  project = google_project.service_project_in_a_folder.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Service account for query history (telemetry)
resource "google_service_account" "service_account_query_history" {
  account_id  = local.service_query_account_id
  description = "Service account for query history"
  project     = google_project.service_project_in_a_folder.project_id
}

resource "google_folder_iam_member" "folder_service_acc_query_history_role" {
  folder = data.google_folder.existing_folder.name
  role   = "roles/bigquery.resourceViewer"
  member = "serviceAccount:${google_service_account.service_account_query_history.email}"
}

resource "google_project_iam_member" "query_history_bq_data_editor" {
  project = google_project.service_project_in_a_folder.project_id
  role    = "roles/bigquery.dataEditor"
  member = "serviceAccount:${google_service_account.service_account_query_history.email}"
}

resource "google_project_iam_member" "query_history_bq_job_user" {
  project = google_project.service_project_in_a_folder.project_id
  role    = "roles/bigquery.jobUser"
  member = "serviceAccount:${google_service_account.service_account_query_history.email}"
}

resource "google_storage_bucket" "query_history_extractor" {
  name                        = "${var.backend_prefix}-q-history"
  project                     = google_project.service_project_in_a_folder.project_id
  location                    = var.gcp_region
  storage_class               = "STANDARD"
  force_destroy               = true
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
  versioning {
    enabled = false
  }
}

resource "google_storage_bucket_iam_member" "query_history_extractor" {
  bucket = google_storage_bucket.query_history_extractor.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.service_account_query_history.email}"
}

output "service_account_query_history_id" {
  value = google_service_account.service_account_query_history.id
}

output "query_history_bucket_id" {
  value = google_storage_bucket.query_history_extractor.name
}