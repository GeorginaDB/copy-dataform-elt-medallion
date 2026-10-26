terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 4.0.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.7.0"
    }
  }
}

provider "google" {
  # Configuration options are set at the resource level to support multiple projects.
}

provider "google-beta" {
  # Configuration options
}

provider "time" {
  # Configuration options
}
data "google_client_config" "default" {}
