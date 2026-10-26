variable "arch_config" {
  description = "Map of configuration for medallion architecture layers and data processing project."
  type = map(object({
    project_id       = string
    default_schema   = string
  }))
  default = {
    data_processing = {
      project_id       = "data-procesisng-502623"
      default_schema   = "source_A"
    }
    bronze = {
      project_id       = "bronze-502623"
      default_schema   = "source_A"
    }
    silver = {
      project_id       = "silver-502623"
      default_schema   = "domain_A"
    }
    gold = {
      project_id       = "gold-502623"
      default_schema   = "domain_A"
    }
  }
}

variable "git_commitish" {
  description = "Git commitish (branch or tag) for the Dataform release configuration."
  type        = string
  default     = "main"
}

variable "release_config_name" {
  description = "The name of the Dataform release configuration."
  type        = string
  default     = "main"
}

variable "sa_name" {
  description = "The name of the Service Account for Dataform execution."
  type        = string
  default     = "dataform-executor"
}

variable "location" {
  description = "Location for BigQuery datasets."
  type        = string
  default     = "US"
}

variable "assertion_dataset_id" {
  description = "Dataset ID for Dataform assertions across projects."
  type        = string
  default     = "dataform_assertions"
}

# Dataform Integration Variables
variable "dataform_repository_name" {
  description = "The name of the Dataform repository."
  type        = string
  default     = "dataform_demo"
}

variable "dataform_repository_api_name" {
  description = "The name of the Dataform API repository with minimal requirements."
  type        = string
  default     = "dataform_demo_api"
}

variable "dataform_workspace_api_name" {
  description = "The name of the workspace for the Dataform API repository."
  type        = string
  default     = "dev"
}

variable "dataform_region" {
  description = "The GCP region for the Dataform repository."
  type        = string
  default     = "us-central1"
}

variable "git_remote_url" {
  description = "The SSH URL of the Git repository (e.g., git@github.com:user/repo.git)."
  type        = string
  default     = ""
}

variable "git_default_branch" {
  description = "The default branch of the Git repository."
  type        = string
  default     = "main"
}

variable "ssh_host_public_key" {
  description = "The SSH public key of the Git host (e.g., GitHub's RSA public key)."
  type        = string
  # Defaulting to the standard GitHub RSA public key rotated in March 2023.
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="
}

variable "enable_dataform_workflow" {
  description = "Set to true to create the Dataform Release Config and Workflow Config. Requires that the Git remote is accessible and the SSH key is authorized on Git."
  type        = bool
  default     = false
}

variable "secret_manager_id" {
  description = "Secret Version for Secret Manager"
  type        = string
}

variable "key_name" {
  description = "Key Name"
  type        = string
}

