locals {
  raw_datasets = distinct(flatten([
    for k, layer in var.arch_config : [
      { project_id = layer.project_id, dataset_id = layer.default_schema },
      { project_id = layer.project_id,       dataset_id = var.assertion_dataset_id }
    ]
  ]))

  # Deduplicate datasets based on "project_id/dataset_id"
  unique_datasets = {
    for ds in local.raw_datasets : "${ds.project_id}/${ds.dataset_id}" => ds
  }
}

resource "google_bigquery_dataset" "datasets" {
  for_each = local.unique_datasets

  project                    = each.value.project_id
  dataset_id                 = each.value.dataset_id
  location                   = var.location
  delete_contents_on_destroy = true

  # Dependency on APIs for all projects to ensure BQ is ready
  depends_on = [
    google_project_service.data_processing_services,
    google_project_service.medallion_services
  ]
}
