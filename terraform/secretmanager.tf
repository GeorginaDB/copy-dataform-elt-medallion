resource "google_secret_manager_secret" "githubssh" {
  project   = var.arch_config["data_processing"].project_id
  secret_id = var.secret_manager_id

  replication {
    auto {}
  }
  depends_on = [google_project_service.data_processing_services]
}


resource "google_secret_manager_secret_version" "githubssh_version" {
  secret      = google_secret_manager_secret.githubssh.id
  secret_data = file("${path.module}/../keys/${var.key_name}")
}
