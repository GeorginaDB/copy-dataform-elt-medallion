# New GCP Folder Creation

# Service Account in Primary Project
resource "google_service_account" "dataform_executor" {
  account_id   = var.sa_name
  display_name = var.sa_name
  project      = var.arch_config["data_processing"].project_id
  
  depends_on   = [google_project_service.data_processing_services]
}
