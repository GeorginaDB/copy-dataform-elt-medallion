locals {
  data_processing_project = var.arch_config["data_processing"].project_id
}

# Generate the Dataform Service Agent (P4SA) synchronously to prevent JIT timing errors
resource "google_project_service_identity" "dataform_p4sa" {
  provider = google-beta
  project  = local.data_processing_project
  service  = "dataform.googleapis.com"

  depends_on = [
    google_project_service.data_processing_services
  ]
}


# Create the Dataform Repository configured for GitHub SSH authentication
resource "google_dataform_repository" "dataform_repository" {
  provider        = google-beta
  project         = local.data_processing_project
  region          = var.dataform_region
  name            = var.dataform_repository_name
  deletion_policy = "FORCE"

  git_remote_settings {
    url            = var.git_remote_url
    default_branch = var.git_default_branch

    ssh_authentication_config {
      user_private_key_secret_version = "${google_secret_manager_secret.githubssh.id}/versions/latest"
      host_public_key                 = var.ssh_host_public_key
    }
  }

  depends_on = [
    google_project_service.data_processing_services,
    google_secret_manager_secret_version.githubssh_version,
    google_secret_manager_secret_iam_member.dataform_p4sa_secret_accessor,
    time_sleep.wait_for_dataform_p4sa
  ]
}

# Create the Minimal Dataform Repository (without Git remote requirements, for direct API usage)
resource "google_dataform_repository" "dataform_repository_api" {
  provider        = google-beta
  project         = local.data_processing_project
  region          = var.dataform_region
  name            = var.dataform_repository_api_name
  deletion_policy = "FORCE"

  depends_on = [
    google_project_service.data_processing_services,
    time_sleep.wait_for_dataform_p4sa
  ]
}


resource "terraform_data" "dataform_workspace_api" {
  triggers_replace = {
    project    = local.data_processing_project
    region     = var.dataform_region
    repository = google_dataform_repository.dataform_repository_api.name
    workspace  = var.dataform_workspace_api_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -f -s -S -X POST \
        -H "Authorization: Bearer $${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{}" \
        "https://dataform.googleapis.com/v1/projects/${self.triggers_replace.project}/locations/${self.triggers_replace.region}/repositories/${self.triggers_replace.repository}/workspaces?workspaceId=${self.triggers_replace.workspace}"
    EOT
    environment = {
      ACCESS_TOKEN = data.google_client_config.default.access_token
    }
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      curl -f -s -S -X DELETE \
        -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
        "https://dataform.googleapis.com/v1/projects/${self.triggers_replace.project}/locations/${self.triggers_replace.region}/repositories/${self.triggers_replace.repository}/workspaces/${self.triggers_replace.workspace}"
    EOT
  }

  depends_on = [
    google_dataform_repository.dataform_repository_api
  ]
}


# Release Configuration for Dataform Repository
resource "google_dataform_repository_release_config" "release_config" {
  count         = var.enable_dataform_workflow && var.git_remote_url != "" ? 1 : 0
  provider      = google-beta
  project       = local.data_processing_project
  region        = var.dataform_region
  repository    = google_dataform_repository.dataform_repository.name
  name          = var.release_config_name
  git_commitish = var.git_commitish

  code_compilation_config {
    default_schema   = var.arch_config["data_processing"].default_schema
    assertion_schema = var.assertion_dataset_id

    vars = merge(
      { for k, v in var.arch_config : "${k}_project" => v.project_id if k != "data_processing" },
      { for k, v in var.arch_config : "${k}_dataset" => v.default_schema if k != "data_processing" }
    )
  }

  depends_on = [
    google_dataform_repository.dataform_repository
  ]
}

# Workflow Configurations (On-Demand) for Dataform Repository
resource "google_dataform_repository_workflow_config" "workflow_configs" {
  for_each = var.enable_dataform_workflow && var.git_remote_url != "" ? {
    for k, v in var.arch_config : k => v if k != "data_processing"
  } : {}
  provider       = google-beta
  project        = local.data_processing_project
  region         = var.dataform_region
  repository     = google_dataform_repository.dataform_repository.name
  name           = each.key
  release_config = google_dataform_repository_release_config.release_config[0].id

  invocation_config {
    service_account                  = google_service_account.dataform_executor.email
    included_tags                    = [each.key]
    transitive_dependencies_included = true
  }

  depends_on = [
    google_dataform_repository_release_config.release_config,
    google_project_iam_member.bq_editor,
    google_project_iam_member.bq_job_user
  ]
}


resource "terraform_data" "compile_dataform_releases" {
  # Crucial: Wait for the Dataform repository and release configs to be created/updated
  depends_on = [
    google_dataform_repository_release_config.release_config
  ]

  count = var.enable_dataform_workflow && var.git_remote_url != "" ? 1 : 0

  # Creation provisioner
  provisioner "local-exec" {
    command = "bash ${path.module}/helper/compile_releases.sh"

    # Pass Terraform variables directly to the bash script as environment variables
    environment = {
      PROJECT_ID   = local.data_processing_project
      REGION       = var.dataform_region
      REPOSITORY   = var.dataform_repository_name
      RELEASE_ID   = var.release_config_name
      ACCESS_TOKEN = data.google_client_config.default.access_token
    }
  }
}

# Wait for IAM propagation
resource "time_sleep" "wait_for_cred_propagations" {
  create_duration = "60s"

  depends_on = [
    google_project_iam_member.token_creator,
    google_dataform_repository_workflow_config.workflow_configs
  ]
}

