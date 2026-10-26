#!/usr/bin/env bash
# ==============================================================================
# GCP Dataform CI/CD Local Simulation Runner
# ==============================================================================
# Automates:
#   1. Fetching local gcloud OAuth2 access token (or Application Default Credentials)
#   2. Triggering Python Dataform REST API client (dataform_api_sync.py)
#   3. Pushing files, compiling DAG, and executing/polling BigQuery pipeline
# ==============================================================================

set -euo pipefail

# Visual styling
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Determine script root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../ && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/api_simulation/dataform_api_sync.py"
REQUIREMENTS_FILE="${SCRIPT_DIR}/api_simulation/requirements.txt"

# Default configuration values
DEFAULT_LOCATION="us-central1"
DEFAULT_REPOSITORY="dataform_demo_api"
DEFAULT_WORKSPACE="dev"
DEFAULT_SOURCE_DIR="${SCRIPT_DIR}"

# Try reading defaults from terraform.tfvars if available
TFVARS_FILE="${SCRIPT_DIR}/terraform/terraform.tfvars"
# Helper to extract a top-level key = "value" from terraform.tfvars (ignoring commented lines)
extract_tfvar() {
    local key="$1"
    local file="$2"
    awk -v k="${key}" '
        /^[[:space:]]*(#|\/\/)/ { next }
        $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub(/^[[:space:]]*[^=]+=[[:space:]]*"/, "")
            sub(/".*$/, "")
            print
            exit
        }
    ' "${file}"
}

# Helper to extract a nested key = "value" inside a block from terraform.tfvars (ignoring commented lines)
extract_tfvar_block() {
    local block="$1"
    local key="$2"
    local file="$3"
    awk -v b="${block}" -v k="${key}" '
        /^[[:space:]]*(#|\/\/)/ { next }
        $0 ~ "^[[:space:]]*" b "[[:space:]]*=[[:space:]]*\\{" { in_block=1; next }
        in_block && /^[[:space:]]*\}/ { in_block=0; next }
        in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            sub(/^[[:space:]]*[^=]+=[[:space:]]*"/, "")
            sub(/".*$/, "")
            print
            exit
        }
    ' "${file}"
}

if [[ -f "${TFVARS_FILE}" ]]; then
    # Extract data_processing project ID from arch_config or top-level variable
    DETECTED_PROJECT=$(extract_tfvar_block "data_processing" "project_id" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_PROJECT}" ]]; then
        DETECTED_PROJECT=$(extract_tfvar "data_processing_project_id" "${TFVARS_FILE}")
    fi

    # Extract API repository and workspace names
    DETECTED_REPO=$(extract_tfvar "dataform_repository_api_name" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_REPO}" ]]; then
        DETECTED_REPO=$(extract_tfvar "dataform_repository_name" "${TFVARS_FILE}")
    fi

    DETECTED_WORKSPACE=$(extract_tfvar "dataform_workspace_api_name" "${TFVARS_FILE}")

    DETECTED_LOCATION=$(extract_tfvar "dataform_region" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_LOCATION}" ]]; then
        DETECTED_LOCATION=$(extract_tfvar "location" "${TFVARS_FILE}")
    fi

    DETECTED_SA_NAME=$(extract_tfvar "sa_name" "${TFVARS_FILE}")

    # Medallion layers compilation variables from arch_config
    DETECTED_BRONZE_PROJECT=$(extract_tfvar_block "bronze" "project_id" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_BRONZE_PROJECT}" ]]; then
        DETECTED_BRONZE_PROJECT=$(extract_tfvar "bronze_project_id" "${TFVARS_FILE}")
    fi

    DETECTED_SILVER_PROJECT=$(extract_tfvar_block "silver" "project_id" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_SILVER_PROJECT}" ]]; then
        DETECTED_SILVER_PROJECT=$(extract_tfvar "silver_project_id" "${TFVARS_FILE}")
    fi

    DETECTED_GOLD_PROJECT=$(extract_tfvar_block "gold" "project_id" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_GOLD_PROJECT}" ]]; then
        DETECTED_GOLD_PROJECT=$(extract_tfvar "gold_project_id" "${TFVARS_FILE}")
    fi

    DETECTED_BRONZE_DATASET=$(extract_tfvar_block "bronze" "default_schema" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_BRONZE_DATASET}" ]]; then
        DETECTED_BRONZE_DATASET=$(extract_tfvar "bronze_dataset_id" "${TFVARS_FILE}")
    fi

    DETECTED_SILVER_DATASET=$(extract_tfvar_block "silver" "default_schema" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_SILVER_DATASET}" ]]; then
        DETECTED_SILVER_DATASET=$(extract_tfvar "silver_dataset_id" "${TFVARS_FILE}")
    fi

    DETECTED_GOLD_DATASET=$(extract_tfvar_block "gold" "default_schema" "${TFVARS_FILE}")
    if [[ -z "${DETECTED_GOLD_DATASET}" ]]; then
        DETECTED_GOLD_DATASET=$(extract_tfvar "gold_dataset_id" "${TFVARS_FILE}")
    fi

    DETECTED_ASSERTION_DATASET=$(extract_tfvar "assertion_dataset_id" "${TFVARS_FILE}")
else
    DETECTED_PROJECT=""
    DETECTED_REPO=""
    DETECTED_WORKSPACE=""
    DETECTED_LOCATION=""
    DETECTED_SA_NAME=""
    DETECTED_BRONZE_PROJECT=""
    DETECTED_SILVER_PROJECT=""
    DETECTED_GOLD_PROJECT=""
    DETECTED_BRONZE_DATASET=""
    DETECTED_SILVER_DATASET=""
    DETECTED_GOLD_DATASET=""
    DETECTED_ASSERTION_DATASET=""
fi

PROJECT_ID="${PROJECT_ID:-${DETECTED_PROJECT}}"
LOCATION="${LOCATION:-${DETECTED_LOCATION:-${DEFAULT_LOCATION}}}"
REPOSITORY="${REPOSITORY:-${DETECTED_REPO:-${DEFAULT_REPOSITORY}}}"
WORKSPACE="${WORKSPACE:-${DETECTED_WORKSPACE:-${DEFAULT_WORKSPACE}}}"
SOURCE_DIR="${DEFAULT_SOURCE_DIR}"

BRONZE_PROJECT="${BRONZE_PROJECT:-${DETECTED_BRONZE_PROJECT}}"
SILVER_PROJECT="${SILVER_PROJECT:-${DETECTED_SILVER_PROJECT}}"
GOLD_PROJECT="${GOLD_PROJECT:-${DETECTED_GOLD_PROJECT}}"
BRONZE_DATASET="${BRONZE_DATASET:-${DETECTED_BRONZE_DATASET}}"
SILVER_DATASET="${SILVER_DATASET:-${DETECTED_SILVER_DATASET}}"
GOLD_DATASET="${GOLD_DATASET:-${DETECTED_GOLD_DATASET}}"
ASSERTION_DATASET="${ASSERTION_DATASET:-${DETECTED_ASSERTION_DATASET}}"

if [[ -n "${DETECTED_SA_NAME}" && -n "${PROJECT_ID}" ]]; then
    DEFAULT_SERVICE_ACCOUNT="${DETECTED_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
else
    DEFAULT_SERVICE_ACCOUNT=""
fi
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-${DATAFORM_SERVICE_ACCOUNT:-${DEFAULT_SERVICE_ACCOUNT}}}"
TAGS=()
EXTRA_PYTHON_ARGS=()
COMPILATION_VARS=()

usage() {
    cat <<EOF
${BOLD}Usage:${NC} $(basename "$0") [OPTIONS]

${BOLD}Core Options:${NC}
  -p, --project <PROJECT_ID>    GCP Data Processing Project ID (Default: ${PROJECT_ID:-"gcloud default"})
  -l, --location <REGION>       Dataform Region/Location (Default: ${LOCATION})
  -r, --repository <REPO_NAME>  Dataform Repository Name (Default: ${REPOSITORY})
  -w, --workspace <WORKSPACE>   Dataform Workspace Name (Default: ${WORKSPACE})
  -s, --service-account <EMAIL> Service account email to execute workflow (Default: ${SERVICE_ACCOUNT:-"unset"})
  -d, --dir <DIRECTORY>         Local directory containing Dataform files (Default: current directory)
  -t, --tags <TAG1 TAG2...>     Specific tags to execute (e.g. -t bronze silver gold)
  --full-refresh                Force full refresh on BigQuery incremental tables
  --install-deps                Install/verify Python dependencies before running
  -h, --help                    Display this help message

${BOLD}Compilation Variables:${NC}
  --bronze-project <PROJECT>    Bronze Layer Project ID (Default: ${BRONZE_PROJECT:-"unset"})
  --silver-project <PROJECT>    Silver Layer Project ID (Default: ${SILVER_PROJECT:-"unset"})
  --gold-project <PROJECT>      Gold Layer Project ID (Default: ${GOLD_PROJECT:-"unset"})
  --bronze-dataset <DATASET>    Bronze Layer Dataset ID (Default: ${BRONZE_DATASET:-"unset"})
  --silver-dataset <DATASET>    Silver Layer Dataset ID (Default: ${SILVER_DATASET:-"unset"})
  --gold-dataset <DATASET>      Gold Layer Dataset ID (Default: ${GOLD_DATASET:-"unset"})
  -V, --var, --vars <KEY=VAL..> Additional compilation variables (e.g. -V bronze_project=bronze-502623)

${BOLD}Examples:${NC}
  # Run pipeline with auto-detected configuration from terraform.tfvars
  $(basename "$0")

  # Run pipeline with explicit or overridden parameters
  $(basename "$0") -p data-procesisng-502623 -r dataform_demo_api -w dev

  # Pass explicit compilation project IDs as arguments
  $(basename "$0") \\
    --bronze-project bronze-502623 \\
    --silver-project silver-502623 \\
    --gold-project gold-502623

  # Pass custom compilation vars using -V / --vars
  $(basename "$0") \\
    -V bronze_project=bronze-502623 silver_project=silver-502623 gold_project=gold-502623
EOF
    exit 0
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project)
            PROJECT_ID="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -r|--repository)
            REPOSITORY="$2"
            shift 2
            ;;
        -w|--workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        -s|--service-account)
            SERVICE_ACCOUNT="$2"
            shift 2
            ;;
        -d|--dir)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --bronze-project|--bronze-project-id)
            BRONZE_PROJECT="$2"
            shift 2
            ;;
        --silver-project|--silver-project-id)
            SILVER_PROJECT="$2"
            shift 2
            ;;
        --gold-project|--gold-project-id)
            GOLD_PROJECT="$2"
            shift 2
            ;;
        --bronze-dataset)
            BRONZE_DATASET="$2"
            shift 2
            ;;
        --silver-dataset)
            SILVER_DATASET="$2"
            shift 2
            ;;
        --gold-dataset)
            GOLD_DATASET="$2"
            shift 2
            ;;
        --assertion-schema|--assertion-dataset)
            ASSERTION_DATASET="$2"
            shift 2
            ;;
        -V|--var|--vars)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                COMPILATION_VARS+=("$1")
                shift
            done
            ;;
        -t|--tags)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do
                TAGS+=("$1")
                shift
            done
            ;;
        --full-refresh)
            EXTRA_PYTHON_ARGS+=("--full-refresh")
            shift
            ;;
        --install-deps)
            INSTALL_DEPS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            EXTRA_PYTHON_ARGS+=("$1")
            shift
            ;;
    esac
done

# If SERVICE_ACCOUNT was not set explicitly and PROJECT_ID is set, recalculate default SA if possible
if [[ -z "${SERVICE_ACCOUNT}" && -n "${DETECTED_SA_NAME}" && -n "${PROJECT_ID}" ]]; then
    SERVICE_ACCOUNT="${DETECTED_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

echo -e "${BOLD}${BLUE}======================================================${NC}"
echo -e "${BOLD}${BLUE}   GCP Dataform CI/CD Local Simulation Runner         ${NC}"
echo -e "${BOLD}${BLUE}======================================================${NC}"

# Check for required tools
if ! command -v gcloud &> /dev/null; then
    echo -e "${RED}Error: 'gcloud' CLI is not installed or not in PATH.${NC}" >&2
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Error: 'python3' is not installed or not in PATH.${NC}" >&2
    exit 1
fi

# Determine GCP Project ID if not set
if [[ -z "${PROJECT_ID}" ]]; then
    echo -e "${YELLOW}Project ID not explicitly passed. Detecting from gcloud config...${NC}"
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
    if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
        echo -e "${RED}Error: Project ID could not be determined. Please specify with -p <PROJECT_ID>.${NC}" >&2
        exit 1
    fi
fi

# Refresh service account if project changed
if [[ -z "${SERVICE_ACCOUNT}" && -n "${DETECTED_SA_NAME}" && -n "${PROJECT_ID}" ]]; then
    SERVICE_ACCOUNT="${DETECTED_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

echo -e "Target Project:    ${CYAN}${PROJECT_ID}${NC}"
echo -e "Location / Region: ${CYAN}${LOCATION}${NC}"
echo -e "Repository:        ${CYAN}${REPOSITORY}${NC}"
echo -e "Workspace:         ${CYAN}${WORKSPACE}${NC}"
echo -e "Service Account:   ${CYAN}${SERVICE_ACCOUNT:-"None"}${NC}"
echo -e "Bronze Project:    ${CYAN}${BRONZE_PROJECT:-"None"}${NC}"
echo -e "Silver Project:    ${CYAN}${SILVER_PROJECT:-"None"}${NC}"
echo -e "Gold Project:      ${CYAN}${GOLD_PROJECT:-"None"}${NC}"
echo -e "Local Source Dir:  ${CYAN}${SOURCE_DIR}${NC}"

# Step A: Retrieve gcloud OAuth2 Access Token
echo -e "\n${BOLD}${BLUE}[AUTH] Retrieving gcloud access token...${NC}"
if ! ACCESS_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null); then
    echo -e "${YELLOW}Warning: Could not retrieve Application Default Credentials token.${NC}"
    echo -e "${YELLOW}Attempting 'gcloud auth print-access-token'...${NC}"
    if ! ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null); then
        echo -e "${YELLOW}Note: Passing no token; Python will use google.auth ADC directly.${NC}"
        ACCESS_TOKEN=""
    fi
fi

if [[ -n "${ACCESS_TOKEN}" ]]; then
    echo -e "${GREEN}✓ Access token acquired successfully.${NC}"
fi

# Step B: Check / Install Python Dependencies
if [[ "${INSTALL_DEPS:-false}" == "true" ]]; then
    echo -e "\n${BOLD}${BLUE}[DEPS] Installing requirements from ${REQUIREMENTS_FILE}...${NC}"
    python3 -m pip install -q -r "${REQUIREMENTS_FILE}"
fi

# Step C: Construct and execute the Python Dataform REST synchronization command
PYTHON_CMD=(
    python3 "${PYTHON_SCRIPT}"
    --project "${PROJECT_ID}"
    --location "${LOCATION}"
    --repository "${REPOSITORY}"
    --workspace "${WORKSPACE}"
    --directory "${SOURCE_DIR}"
)

if [[ -n "${SERVICE_ACCOUNT}" ]]; then
    PYTHON_CMD+=(--service-account "${SERVICE_ACCOUNT}")
fi

if [[ -n "${BRONZE_PROJECT}" ]]; then
    PYTHON_CMD+=(--bronze-project "${BRONZE_PROJECT}")
fi

if [[ -n "${SILVER_PROJECT}" ]]; then
    PYTHON_CMD+=(--silver-project "${SILVER_PROJECT}")
fi

if [[ -n "${GOLD_PROJECT}" ]]; then
    PYTHON_CMD+=(--gold-project "${GOLD_PROJECT}")
fi

if [[ -n "${BRONZE_DATASET}" ]]; then
    PYTHON_CMD+=(--bronze-dataset "${BRONZE_DATASET}")
fi

if [[ -n "${SILVER_DATASET}" ]]; then
    PYTHON_CMD+=(--silver-dataset "${SILVER_DATASET}")
fi

if [[ -n "${GOLD_DATASET}" ]]; then
    PYTHON_CMD+=(--gold-dataset "${GOLD_DATASET}")
fi

if [[ -n "${ASSERTION_DATASET}" ]]; then
    PYTHON_CMD+=(--assertion-schema "${ASSERTION_DATASET}")
fi

if [[ ${#COMPILATION_VARS[@]} -gt 0 ]]; then
    PYTHON_CMD+=(--vars "${COMPILATION_VARS[@]}")
fi

if [[ -n "${ACCESS_TOKEN}" ]]; then
    PYTHON_CMD+=(--token "${ACCESS_TOKEN}")
fi

if [[ ${#TAGS[@]} -gt 0 ]]; then
    PYTHON_CMD+=(--tags "${TAGS[@]}")
fi

if [[ ${#EXTRA_PYTHON_ARGS[@]} -gt 0 ]]; then
    PYTHON_CMD+=("${EXTRA_PYTHON_ARGS[@]}")
fi

echo -e "\n${BOLD}${BLUE}[EXEC] Triggering Dataform API synchronization...${NC}"
"${PYTHON_CMD[@]}"

echo -e "\n${GREEN}${BOLD}✔ Simulation pipeline finished successfully!${NC}"
