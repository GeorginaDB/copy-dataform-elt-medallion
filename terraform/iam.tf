# Grant BigQuery Data Editor on all medallion layers and data processing project
resource "google_project_iam_member" "bq_editor" {
  for_each = var.arch_config

  project = each.value.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.dataform_executor.email}"
}

# Grant BigQuery Job User on all medallion layers and data processing project
resource "google_project_iam_member" "bq_job_user" {
  for_each = var.arch_config

  project = each.value.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dataform_executor.email}"
}

# Grant Secret Manager Secret Accessor in the data processing project
resource "google_project_iam_member" "primary_secret_accessor" {
  project = var.arch_config["data_processing"].project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.dataform_executor.email}"
}

# Grant Service Account Token Creator in the data processing project
resource "google_project_iam_member" "token_creator" {
  project = var.arch_config["data_processing"].project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.dataform_executor.email}"
}

# Grant the dataform-executor Service Account roles/dataform.admin in the Primary project
# so it can trigger and manage pipelines.
resource "google_project_iam_member" "primary_dataform_admin" {
  provider = google
  project  = local.data_processing_project
  role     = "roles/dataform.admin"
  member   = "serviceAccount:${google_service_account.dataform_executor.email}"

  depends_on = [
    google_project_service.data_processing_services
  ]
}


# Wait for IAM propagation of the newly generated P4SA on the GCP side
resource "time_sleep" "wait_for_dataform_p4sa" {
  create_duration = "20s"

  triggers = {
    p4sa_email = google_project_service_identity.dataform_p4sa.email
  }

  depends_on = [
    google_project_service_identity.dataform_p4sa
  ]
}


# Grant the Dataform Service Agent (P4SA) read access to the SSH key in Secret Manager
resource "google_secret_manager_secret_iam_member" "dataform_p4sa_secret_accessor" {
  provider  = google
  project   = local.data_processing_project
  secret_id = google_secret_manager_secret.githubssh.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${time_sleep.wait_for_dataform_p4sa.triggers["p4sa_email"]}"
  
  depends_on = [
    google_project_service.data_processing_services,
    time_sleep.wait_for_dataform_p4sa
  ]
}

# Grant the Dataform Service Agent (P4SA) permission to act as the execution SA
# so it can run BigQuery jobs in strict act-as mode.
resource "google_service_account_iam_member" "dataform_p4sa_user" {
  provider           = google
  service_account_id = google_service_account.dataform_executor.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${time_sleep.wait_for_dataform_p4sa.triggers["p4sa_email"]}"
  
  depends_on = [
    google_project_service.data_processing_services,
    time_sleep.wait_for_dataform_p4sa
  ]
}

# Grant the Dataform Service Agent (P4SA) permission to create tokens for the execution SA
# so it can run queries.
resource "google_service_account_iam_member" "dataform_p4sa_token_creator" {
  provider           = google
  service_account_id = google_service_account.dataform_executor.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${time_sleep.wait_for_dataform_p4sa.triggers["p4sa_email"]}"
  
  depends_on = [
    google_project_service.data_processing_services,
    time_sleep.wait_for_dataform_p4sa
  ]
}