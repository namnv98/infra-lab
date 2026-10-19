terraform {
  required_version = ">= 1.8"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.7"
    }
    google-beta = { # chỉ cho target instance chọn card WAN (tham số network còn beta)
      source  = "hashicorp/google-beta"
      version = "~> 8.7"
    }
  }
  # State để local cho lab (xoá sạch bằng `tofu destroy` là xong).
  # Production: backend "gcs" { bucket = "<tên>-tfstate" } có bật versioning.
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
