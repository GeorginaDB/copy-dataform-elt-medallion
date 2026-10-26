locals {
  core_services = [
    "bigquery.googleapis.com",
    "bigquerystorage.googleapis.com",
    "dataform.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "developerconnect.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]
  target_project_services = [
    "bigquery.googleapis.com",
    "bigquerystorage.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]

  medallion_services = flatten([
    for k, layer in var.arch_config : [
      for svc in local.target_project_services : {
        key        = "${k}_${svc}"
        project_id = layer.project_id
        service    = svc
      }
    ] if k != "data_processing"
  ])

  medallion_services_map = {
    for item in local.medallion_services : item.key => item
  }
}

# Enable APIs on Data Processing Project
resource "google_project_service" "data_processing_services" {
  for_each = toset(local.core_services)
  project  = var.arch_config["data_processing"].project_id
  service  = each.key

  disable_on_destroy = false
}

# Enable APIs on Medallion Target Projects
resource "google_project_service" "medallion_services" {
  for_each = local.medallion_services_map
  project  = each.value.project_id
  service  = each.value.service

  disable_on_destroy = false
}