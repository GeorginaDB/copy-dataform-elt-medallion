# Terraform Configuration for Dataform Demo

This Terraform configuration sets up the GCP infrastructure for a multi-project Dataform demo using **existing** projects. It provisions:
- BigQuery Datasets for Medallion architecture (Bronze, Silver, Gold layers).
- A Dataform Repository configured with Git-on-Borg/GitHub SSH integration.
- IAM permissions and Service Account for execution.
- A Secret Manager secret for storing Git SSH credentials.

## Prerequisites

Before running Terraform, you MUST have the following resources created in your Google Cloud organization:
1.  **A GCP Folder** (Optional but Recommended for better visibility and organization to group these projects).
2.  **4 GCP Projects**:
    -   1 Primary Project (where Dataform, the execution Service Account, and Secrets will live).
    -   3 Target Projects (for the Bronze, Silver, and Gold data layers respectively).

You must have sufficient permissions (e.g., Project IAM Admin, BigQuery Admin, Service Account Admin, Secret Manager Admin) on all 4 projects to apply this configuration.


## Usage

1.  **Initialize Terraform**:
    ```bash
    cd terraform
    terraform init
    ```

2.  **Configure Variables**:
    - Open `terraform.tfvars`.
    - Configure the `arch_config` dictionary map with your actual GCP Project IDs, Git branches (`git_commitish`), default BigQuery database/project targets, and default dataset schemas for each layer (`data_processing`, `bronze`, `silver`, `gold`).
    - Configure your Git repository URL and SSH settings.


3.  **Review the Plan**:
    ```bash
    terraform plan
    ```

4.  **Apply the Configuration**:
    ```bash
    terraform apply
    ```

## Notes & Assumptions

- **Folder & Project Placement**: This configuration does NOT create GCP Folders or Projects. You must provide existing Project IDs via the `arch_config` map in `terraform.tfvars`. It is recommended to place the 4 projects in a single GCP Folder for better visibility.
- **Project Existence**: You must use existing Project IDs in the `arch_config` configuration in `terraform.tfvars`.
- **BigQuery Tables**: `google_bigquery_table` resources are OMITTED from this Terraform configuration. Since this is a Dataform project, Dataform is the source of truth for table schemas and will create them upon execution (`dataform run`).
- **Dataset Deduplication**: The configuration in `bigquery.tf` iterates over `arch_config` to provision both the layer schemas (`default_schema`) and assertion datasets (`project_id` / `assertion_dataset_id`). It uses `distinct(...)` to automatically deduplicate `{project_id, dataset_id}` pairs so that shared or identical dataset targets are only created once.
- **GitHub SSH Integration**:
  - To connect to your GitHub repository using **SSH**:
    1. Provide your SSH URL in `git_remote_url` (e.g., `git@github.com:user/repo.git`) in `terraform.tfvars`.
    2. Create the **Public Key** and **Private Key** in the `keys/` directory so terraform creates the secret version.
    3. Register the corresponding **Public Key** as a **Deploy Key** on your GitHub repository with Read/Write access.

- **Dataform Workflow Orchestration**:
  - By default, Terraform only creates the Repository and IAM bindings. Set `enable_dataform_workflow = true` in `terraform.tfvars` and run `terraform apply` **AFTER** your SSH Deploy Key is registered and authorized on GitHub! 
  - Terraform will provision **Release Configurations and Workflow Configurations** dynamically using `for_each` loops over `arch_config` (for `"bronze"`, `"silver"`, and `"gold"`).
  - Compilation variables (`bronze_project`, `silver_project`, `gold_project`, `bronze_dataset`, `silver_dataset`, `gold_dataset`) are automatically merged and injected into the release compilation configurations.
  - Each layer is configured for **on-demand execution**. 
  - **Tag Filtering (Optional)**: Workflows invoke actions filtered by tags matching each layer key (`"bronze"`, `"silver"`, `"gold"`).
- **Secret Version**: The `google_secret_manager_secret` is created to hold the SSH key. The configuration automatically points to the `latest` version of this secret.
- **IAM Permissions**: The Service Account is granted `roles/bigquery.dataEditor` AND `roles/bigquery.jobUser` across all projects defined in `arch_config` using `for_each` loops. The Dataform Service Agent (P4SA) is dynamically generated and granted Secret Accessor, User, and Token Creator roles.




