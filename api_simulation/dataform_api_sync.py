#!/usr/bin/env python3
"""
Dataform REST API CI/CD Simulator
=================================
Automates deploying local Dataform files (.sqlx, .yaml, .json, .js)
into GCP Dataform, compiling the workspace DAG, and triggering/polling
execution in BigQuery.

Workflow:
  Step 1: Push local files to Dataform Workspace via :writeFile and :commit
  Step 2: Compile Workspace into a SQL DAG via compilationResults.create
  Step 3: Trigger Workflow Invocation on BigQuery & poll until completion
"""

import argparse
import base64
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests
import google.auth
import google.auth.transport.requests

# ANSI Color codes for polished terminal output
GREEN = "\033[92m"
BLUE = "\033[94m"
CYAN = "\033[96m"
YELLOW = "\033[93m"
RED = "\033[91m"
BOLD = "\033[1m"
RESET = "\033[0m"

DATAFORM_API_BASE = "https://dataform.googleapis.com/v1beta1"

# Directories and files to exclude when scanning the local Dataform repository
DEFAULT_EXCLUDE_DIRS = {
    ".git",
    ".terraform",
    "terraform",
    "__pycache__",
    ".idea",
    ".vscode",
    ".venv",
    "venv",
    "env",
    ".pytest_cache",
    ".mypy_cache",
}

DEFAULT_EXCLUDE_FILES = {
    ".gitignore",
    ".DS_Store",
    "run_simulation.sh",
    "requirements.txt",
    "dataform_api_sync.py",
    "terraform.tfvars",
    "terraform.tfstate",
    "terraform.tfstate.backup",
}

DEFAULT_INCLUDE_EXTENSIONS = {
    ".sqlx",
    ".json",
    ".yaml",
    ".yml",
    ".js",
    ".proto",
    ".sql",
    ".md",
}


class DataformClient:
    """Client for interacting with Google Cloud Dataform v1beta1 REST API."""

    def __init__(
        self,
        project_id: str,
        location: str,
        repository_id: str,
        workspace_id: str,
        access_token: Optional[str] = None,
        service_account: Optional[str] = None,
    ):
        self.project_id = project_id
        self.location = location
        self.repository_id = repository_id
        self.workspace_id = workspace_id
        self.token = access_token
        self.service_account = service_account
        self.session = requests.Session()

        # Workspace resource paths
        self.repo_path = f"projects/{self.project_id}/locations/{self.location}/repositories/{self.repository_id}"
        self.workspace_path = f"{self.repo_path}/workspaces/{self.workspace_id}"

        # Initialize credentials if token not explicitly supplied
        if not self.token:
            self._init_adc_credentials()

    def _init_adc_credentials(self) -> None:
        """Acquires and refreshes Google Application Default Credentials (ADC)."""
        logging.info(f"{CYAN}Detecting Google Application Default Credentials (ADC)...{RESET}")
        try:
            scopes = ["https://www.googleapis.com/auth/cloud-platform"]
            credentials, detected_project = google.auth.default(scopes=scopes)
            request = google.auth.transport.requests.Request()
            credentials.refresh(request)
            self.token = credentials.token
            if not self.project_id and detected_project:
                self.project_id = detected_project
                self.repo_path = f"projects/{self.project_id}/locations/{self.location}/repositories/{self.repository_id}"
                self.workspace_path = f"{self.repo_path}/workspaces/{self.workspace_id}"
            logging.info(f"{GREEN}✓ ADC authentication initialized successfully.{RESET}")
        except Exception as e:
            logging.error(f"{RED}Failed to obtain ADC credentials: {e}{RESET}")
            logging.error("Ensure you ran: gcloud auth application-default login")
            sys.exit(1)

    def _get_headers(self) -> Dict[str, str]:
        """Builds HTTP headers with authorization bearer token."""
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def _handle_api_error(self, response: requests.Response, context: str) -> None:
        """Parses and logs Google Cloud REST API error response."""
        try:
            error_data = response.json()
            message = error_data.get("error", {}).get("message", response.text)
            code = error_data.get("error", {}).get("code", response.status_code)
            status = error_data.get("error", {}).get("status", "UNKNOWN")
            logging.error(f"{RED}API Error during {context} (HTTP {code} {status}): {message}{RESET}")
        except Exception:
            logging.error(f"{RED}API Error during {context} (HTTP {response.status_code}): {response.text}{RESET}")

    # =========================================================================
    # Step 1: Push Code to Workspace
    # =========================================================================
    def write_file(self, relative_path: str, file_content_bytes: bytes) -> bool:
        """
        Writes/uploads a single file to the Dataform workspace using :writeFile.
        Endpoint: POST /v1beta1/{workspace=projects/*/locations/*/repositories/*/workspaces/*}:writeFile
        """
        url = f"{DATAFORM_API_BASE}/{self.workspace_path}:writeFile"
        b64_content = base64.b64encode(file_content_bytes).decode("utf-8")

        payload = {
            "path": relative_path,
            "contents": b64_content,
        }

        response = self.session.post(url, headers=self._get_headers(), json=payload)
        if response.status_code in (200, 201):
            return True
        else:
            self._handle_api_error(response, f"writeFile for '{relative_path}'")
            return False

    def commit_workspace_changes(
        self,
        author_name: str,
        author_email: str,
        commit_message: str,
        file_paths: Optional[List[str]] = None,
    ) -> bool:
        """
        Commits staged workspace changes into Dataform Git version control.
        Endpoint: POST /v1beta1/{name=projects/*/locations/*/repositories/*/workspaces/*}:commit
        """
        url = f"{DATAFORM_API_BASE}/{self.workspace_path}:commit"
        payload: Dict[str, Any] = {
            "author": {
                "name": author_name,
                "emailAddress": author_email,
            },
            "commitMessage": commit_message,
        }
        if file_paths:
            payload["paths"] = file_paths

        logging.info(f"{BLUE}[STEP 1] Committing workspace changes with message: '{commit_message}'...{RESET}")
        response = self.session.post(url, headers=self._get_headers(), json=payload)
        if response.status_code in (200, 201):
            logging.info(f"{GREEN}✓ Workspace changes successfully committed.{RESET}")
            return True
        else:
            self._handle_api_error(response, "commitWorkspaceChanges")
            return False

    def push_directory(
        self,
        directory_path: Path,
        author_name: str,
        author_email: str,
        commit_message: str,
    ) -> List[str]:
        """
        Recursively discovers Dataform files in the local directory, uploads them,
        and commits the changes.
        """
        logging.info(f"{BOLD}{BLUE}======================================================{RESET}")
        logging.info(f"{BOLD}{BLUE} STEP 1: PUSH CODE TO DATAFORM WORKSPACE              {RESET}")
        logging.info(f"{BOLD}{BLUE}======================================================{RESET}")
        logging.info(f"Workspace Path: {CYAN}{self.workspace_path}{RESET}")
        logging.info(f"Local Source Directory: {CYAN}{directory_path.resolve()}{RESET}")

        files_to_upload: List[Tuple[Path, str]] = []

        # Recursively collect valid files
        for root, dirs, files in os.walk(directory_path):
            dirs[:] = [d for d in dirs if d not in DEFAULT_EXCLUDE_DIRS and not d.startswith(".")]
            root_path = Path(root)

            for file_name in files:
                if file_name in DEFAULT_EXCLUDE_FILES or file_name.startswith("."):
                    continue

                file_path = root_path / file_name
                rel_path = file_path.relative_to(directory_path).as_posix()

                if file_path.suffix in DEFAULT_INCLUDE_EXTENSIONS or file_name in ("dataform.json", "workflow_settings.yaml", "package.json"):
                    files_to_upload.append((file_path, rel_path))

        if not files_to_upload:
            logging.warning(f"{YELLOW}No matching Dataform files found to push in '{directory_path}'.{RESET}")
            return []

        logging.info(f"Found {BOLD}{len(files_to_upload)}{RESET} files to upload to workspace.")

        uploaded_paths: List[str] = []
        for file_path, rel_path in sorted(files_to_upload, key=lambda x: x[1]):
            try:
                content = file_path.read_bytes()
                logging.info(f"  → Uploading {CYAN}{rel_path}{RESET} ({len(content)} bytes)...")
                if self.write_file(rel_path, content):
                    uploaded_paths.append(rel_path)
                else:
                    logging.error(f"{RED}Failed uploading {rel_path}. Aborting push.{RESET}")
                    sys.exit(1)
            except Exception as ex:
                logging.error(f"{RED}Error reading file {file_path}: {ex}{RESET}")
                sys.exit(1)

        logging.info(f"{GREEN}✓ Uploaded {len(uploaded_paths)} files to workspace.{RESET}")

        # Commit changes
        if not self.commit_workspace_changes(author_name, author_email, commit_message, uploaded_paths):
            logging.error(f"{RED}Workspace commit failed.{RESET}")
            sys.exit(1)

        return uploaded_paths

    # =========================================================================
    # Step 2: Compile the Workspace
    # =========================================================================
    def compile_workspace(
        self,
        compilation_vars: Optional[Dict[str, str]] = None,
        default_schema: Optional[str] = None,
        default_location: Optional[str] = None,
        database_suffix: Optional[str] = None,
        schema_suffix: Optional[str] = None,
        table_prefix: Optional[str] = None,
    ) -> str:
        """
        Compiles the Dataform workspace into a SQL DAG.
        Endpoint: POST /v1beta1/{parent=projects/*/locations/*/repositories/*}/compilationResults
        Returns the CompilationResult resource name if successful, otherwise exits with code 1.
        """
        logging.info(f"\n{BOLD}{BLUE}======================================================{RESET}")
        logging.info(f"{BOLD}{BLUE} STEP 2: COMPILE WORKSPACE INTO SQL DAG               {RESET}")
        logging.info(f"{BOLD}{BLUE}======================================================{RESET}")

        url = f"{DATAFORM_API_BASE}/{self.repo_path}/compilationResults"
        payload: Dict[str, Any] = {
            "workspace": self.workspace_path
        }

        code_compilation_config: Dict[str, Any] = {}
        if compilation_vars:
            code_compilation_config["vars"] = compilation_vars
        if default_schema:
            code_compilation_config["defaultSchema"] = default_schema
        if default_location:
            code_compilation_config["defaultLocation"] = default_location
        if database_suffix:
            code_compilation_config["databaseSuffix"] = database_suffix
        if schema_suffix:
            code_compilation_config["schemaSuffix"] = schema_suffix
        if table_prefix:
            code_compilation_config["tablePrefix"] = table_prefix

        if code_compilation_config:
            payload["codeCompilationConfig"] = code_compilation_config

        logging.info(f"Sending compilation request for workspace: {CYAN}{self.workspace_path}{RESET}...")
        if compilation_vars:
            logging.info(f"Compilation Variables (vars):")
            for k, v in sorted(compilation_vars.items()):
                logging.info(f"  • {YELLOW}{k}{RESET} = {CYAN}{v}{RESET}")
        if default_schema:
            logging.info(f"  Default Schema: {CYAN}{default_schema}{RESET}")

        response = self.session.post(url, headers=self._get_headers(), json=payload)

        if response.status_code not in (200, 201):
            self._handle_api_error(response, "createCompilationResult")
            logging.error(f"{RED}Compilation request failed to execute.{RESET}")
            sys.exit(1)

        compilation_data = response.json()
        compilation_name = compilation_data.get("name", "")
        compilation_id = compilation_name.split("/")[-1] if compilation_name else "UNKNOWN"
        errors = compilation_data.get("compilationErrors", [])

        logging.info(f"Compilation Result ID: {BOLD}{CYAN}{compilation_id}{RESET}")
        if "dataformCoreVersion" in compilation_data:
            logging.info(f"Dataform Core Version: {compilation_data['dataformCoreVersion']}")

        # Check for compilation errors
        if errors:
            logging.error(f"\n{BOLD}{RED}❌ COMPILATION FAILED: Found {len(errors)} error(s):{RESET}")
            for idx, err in enumerate(errors, 1):
                err_path = err.get("path", "N/A")
                err_msg = err.get("message", "No message provided")
                err_target = err.get("actionTarget", {})
                target_str = f" [Target: {err_target.get('name', '')}]" if err_target else ""
                logging.error(f"  {RED}{idx}. File: {BOLD}{err_path}{RESET}{RED}{target_str}{RESET}")
                logging.error(f"     Message: {err_msg}")
                if "stack" in err:
                    logging.debug(f"     Stack: {err['stack']}")
            sys.exit(1)

        logging.info(f"{GREEN}✓ Workspace compilation SUCCEEDED with 0 errors.{RESET}")
        return compilation_name

    # =========================================================================
    # Step 3: Trigger Workflow Invocation & Poll
    # =========================================================================
    def trigger_workflow_invocation(
        self,
        compilation_result_name: str,
        service_account: Optional[str] = None,
        tags: Optional[List[str]] = None,
        targets: Optional[List[Dict[str, str]]] = None,
        transitive_dependencies: bool = True,
        transitive_dependents: bool = False,
        full_refresh: bool = False,
    ) -> str:
        """
        Creates a WorkflowInvocation to execute the compiled SQL DAG on BigQuery.
        Endpoint: POST /v1beta1/{parent=projects/*/locations/*/repositories/*}/workflowInvocations
        """
        logging.info(f"\n{BOLD}{BLUE}======================================================{RESET}")
        logging.info(f"{BOLD}{BLUE} STEP 3: TRIGGER EXECUTION ON BIGQUERY               {RESET}")
        logging.info(f"{BOLD}{BLUE}======================================================{RESET}")

        url = f"{DATAFORM_API_BASE}/{self.repo_path}/workflowInvocations"

        sa = service_account or self.service_account

        invocation_config: Dict[str, Any] = {
            "transitiveDependenciesIncluded": transitive_dependencies,
            "transitiveDependentsIncluded": transitive_dependents,
            "fullyRefreshIncrementalTablesEnabled": full_refresh,
        }

        if sa:
            invocation_config["serviceAccount"] = sa
        if tags:
            invocation_config["includedTags"] = tags
        if targets:
            invocation_config["includedTargets"] = targets

        payload = {
            "compilationResult": compilation_result_name,
            "invocationConfig": invocation_config,
        }

        logging.info(f"Triggering execution with configuration:")
        logging.info(f"  Compilation Result: {CYAN}{compilation_result_name.split('/')[-1]}{RESET}")
        if sa:
            logging.info(f"  Service Account: {CYAN}{sa}{RESET}")
        logging.info(f"  Included Tags: {YELLOW}{tags if tags else 'All'}{RESET}")
        logging.info(f"  Transitive Dependencies Included: {transitive_dependencies}")
        logging.info(f"  Fully Refresh Incremental Tables: {full_refresh}")

        response = self.session.post(url, headers=self._get_headers(), json=payload)
        if response.status_code not in (200, 201):
            self._handle_api_error(response, "createWorkflowInvocation")
            logging.error(f"{RED}Workflow invocation creation failed.{RESET}")
            sys.exit(1)

        invocation_data = response.json()
        invocation_name = invocation_data.get("name", "")
        invocation_id = invocation_name.split("/")[-1] if invocation_name else "UNKNOWN"
        logging.info(f"{GREEN}✓ Workflow invocation successfully launched.{RESET}")
        logging.info(f"Invocation ID: {BOLD}{CYAN}{invocation_id}{RESET}")

        return invocation_name

    def poll_workflow_invocation(
        self,
        invocation_name: str,
        poll_interval_seconds: int = 5,
        timeout_seconds: int = 600,
    ) -> bool:
        """
        Polls the workflow invocation state until terminal status (SUCCEEDED, FAILED, CANCELLED).
        Endpoint: GET /v1beta1/{name=projects/*/locations/*/repositories/*/workflowInvocations/*}
        """
        logging.info(f"\n{BOLD}{CYAN}--- Polling Workflow Execution Status ---{RESET}")
        url = f"{DATAFORM_API_BASE}/{invocation_name}"
        start_time = time.time()
        terminal_states = {"SUCCEEDED", "FAILED", "CANCELLED"}

        while True:
            elapsed = int(time.time() - start_time)
            if elapsed > timeout_seconds:
                logging.error(f"{RED}Polling timed out after {timeout_seconds} seconds.{RESET}")
                return False

            response = self.session.get(url, headers=self._get_headers())
            if response.status_code != 200:
                self._handle_api_error(response, "getWorkflowInvocation")
                time.sleep(poll_interval_seconds)
                continue

            data = response.json()
            state = data.get("state", "STATE_UNSPECIFIED")
            timing = data.get("invocationTiming", {})
            start_ts = timing.get("startTime", "")
            end_ts = timing.get("endTime", "")

            # Format state color
            if state == "RUNNING":
                state_formatted = f"{YELLOW}RUNNING ⏳{RESET}"
            elif state == "SUCCEEDED":
                state_formatted = f"{GREEN}{BOLD}SUCCEEDED ✅{RESET}"
            elif state == "FAILED":
                state_formatted = f"{RED}{BOLD}FAILED ❌{RESET}"
            elif state == "CANCELLED":
                state_formatted = f"{RED}CANCELLED ⛔{RESET}"
            else:
                state_formatted = f"{CYAN}{state}{RESET}"

            logging.info(f"[{elapsed:3d}s elapsed] Invocation State: {state_formatted}")

            if state in terminal_states:
                logging.info(f"\n{BOLD}Execution Summary:{RESET}")
                logging.info(f"  Final State: {state}")
                if start_ts:
                    logging.info(f"  Started: {start_ts}")
                if end_ts:
                    logging.info(f"  Finished: {end_ts}")
                logging.info(f"  Total Duration: {elapsed} seconds")

                if state == "SUCCEEDED":
                    logging.info(f"\n{GREEN}{BOLD}======================================================{RESET}")
                    logging.info(f"{GREEN}{BOLD} ✅ DATAFORM CI/CD SIMULATION COMPLETED SUCCESSFULLY  {RESET}")
                    logging.info(f"{GREEN}{BOLD}======================================================{RESET}")
                    return True
                else:
                    logging.error(f"\n{RED}{BOLD}======================================================{RESET}")
                    logging.error(f"{RED}{BOLD} ❌ DATAFORM PIPELINE EXECUTION {state}                {RESET}")
                    logging.error(f"{RED}{BOLD}======================================================{RESET}")
                    return False

            time.sleep(poll_interval_seconds)


def parse_args() -> argparse.Namespace:
    """Parses command-line arguments."""
    parser = argparse.ArgumentParser(
        description="GCP Dataform CI/CD REST API Pipeline Simulator",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    # Core GCP Dataform Identifiers
    parser.add_argument(
        "--project",
        "-p",
        required=True,
        help="GCP Data Processing Project ID hosting the Dataform repository",
    )
    parser.add_argument(
        "--location",
        "-l",
        default="us-central1",
        help="GCP Dataform region / location",
    )
    parser.add_argument(
        "--repository",
        "-r",
        required=True,
        help="Dataform repository ID / name",
    )
    parser.add_argument(
        "--workspace",
        "-w",
        default="dev",
        help="Dataform workspace ID / name",
    )
    parser.add_argument(
        "--directory",
        "-d",
        type=Path,
        default=Path("."),
        help="Local directory containing Dataform files (.sqlx, workflow_settings.yaml, etc.)",
    )

    # Authentication & Service Account Execution
    parser.add_argument(
        "--token",
        "-t",
        default=os.environ.get("DATAFORM_ACCESS_TOKEN"),
        help="OAuth2 Access Token (falls back to ADC via google-auth if not provided)",
    )
    parser.add_argument(
        "--service-account",
        "-s",
        default=os.environ.get("DATAFORM_SERVICE_ACCOUNT"),
        help="Service account email to execute Dataform workflow invocations under",
    )

    # Git Commit Metadata
    parser.add_argument(
        "--author-name",
        default="CI/CD Simulation Runner",
        help="Author name for the workspace Git commit",
    )
    parser.add_argument(
        "--author-email",
        default="cicd-runner@google.com",
        help="Author email for the workspace Git commit",
    )
    parser.add_argument(
        "--commit-message",
        "-m",
        default=f"Automated CI/CD simulation push ({time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())})",
        help="Commit message for workspace changes",
    )

    # Invocation Execution Filters
    parser.add_argument(
        "--tags",
        nargs="*",
        default=[],
        help="Dataform tags to filter execution (e.g. bronze silver gold)",
    )
    parser.add_argument(
        "--no-transitive-dependencies",
        action="store_true",
        help="Disable automatic inclusion of upstream transitive dependencies",
    )
    parser.add_argument(
        "--transitive-dependents",
        action="store_true",
        help="Include downstream transitive dependents during invocation",
    )
    parser.add_argument(
        "--full-refresh",
        action="store_true",
        help="Force full refresh on incremental tables",
    )

    # Compilation Configuration & Variables
    parser.add_argument(
        "--bronze-project",
        help="Compilation variable: bronze_project project ID",
    )
    parser.add_argument(
        "--silver-project",
        help="Compilation variable: silver_project project ID",
    )
    parser.add_argument(
        "--gold-project",
        help="Compilation variable: gold_project project ID",
    )
    parser.add_argument(
        "--bronze-dataset",
        help="Compilation variable: bronze_dataset dataset ID",
    )
    parser.add_argument(
        "--silver-dataset",
        help="Compilation variable: silver_dataset dataset ID",
    )
    parser.add_argument(
        "--gold-dataset",
        help="Compilation variable: gold_dataset dataset ID",
    )
    parser.add_argument(
        "--vars",
        "--compilation-vars",
        "-V",
        nargs="*",
        default=[],
        help="Custom compilation variables in KEY=VALUE format or JSON string (e.g. bronze_project=bronze-502623)",
    )
    parser.add_argument(
        "--default-database",
        help="Default database / project ID for compilation",
    )
    parser.add_argument(
        "--default-schema",
        help="Default dataset / schema for compilation",
    )
    parser.add_argument(
        "--assertion-schema",
        help="Assertion dataset schema for compilation",
    )

    # Polling Control
    parser.add_argument(
        "--poll-interval",
        type=int,
        default=5,
        help="Seconds to wait between invocation status checks",
    )
    parser.add_argument(
        "--poll-timeout",
        type=int,
        default=600,
        help="Max seconds to poll before timing out",
    )
    parser.add_argument(
        "--skip-poll",
        action="store_true",
        help="Trigger execution without waiting for completion",
    )

    return parser.parse_args()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    args = parse_args()

    # Instantiate Dataform API Client
    client = DataformClient(
        project_id=args.project,
        location=args.location,
        repository_id=args.repository,
        workspace_id=args.workspace,
        access_token=args.token,
        service_account=args.service_account,
    )

    # Step 1: Upload and commit files to workspace
    client.push_directory(
        directory_path=args.directory,
        author_name=args.author_name,
        author_email=args.author_email,
        commit_message=args.commit_message,
    )

    # Parse compilation variables
    compilation_vars: Dict[str, str] = {}
    if args.bronze_project:
        compilation_vars["bronze_project"] = args.bronze_project
    if args.silver_project:
        compilation_vars["silver_project"] = args.silver_project
    if args.gold_project:
        compilation_vars["gold_project"] = args.gold_project
    if args.bronze_dataset:
        compilation_vars["bronze_dataset"] = args.bronze_dataset
    if args.silver_dataset:
        compilation_vars["silver_dataset"] = args.silver_dataset
    if args.gold_dataset:
        compilation_vars["gold_dataset"] = args.gold_dataset

    for var_entry in args.vars:
        if not var_entry:
            continue
        var_str = var_entry.strip()
        if var_str.startswith("{") and var_str.endswith("}"):
            try:
                parsed_json = json.loads(var_str)
                if isinstance(parsed_json, dict):
                    compilation_vars.update({str(k): str(v) for k, v in parsed_json.items()})
            except Exception as e:
                logging.warning(f"Could not parse JSON vars '{var_str}': {e}")
        elif "=" in var_str:
            key, val = var_str.split("=", 1)
            compilation_vars[key.strip()] = val.strip()

    # Step 2: Compile the workspace into SQL DAG
    compilation_name = client.compile_workspace(
        compilation_vars=compilation_vars if compilation_vars else None,
        default_schema=args.default_schema
    )

    # Step 3: Trigger Workflow Invocation on BigQuery
    invocation_name = client.trigger_workflow_invocation(
        compilation_result_name=compilation_name,
        service_account=args.service_account,
        tags=args.tags,
        transitive_dependencies=not args.no_transitive_dependencies,
        transitive_dependents=args.transitive_dependents,
        full_refresh=args.full_refresh,
    )

    # Step 3 (cont): Poll execution until completion
    if not args.skip_poll:
        success = client.poll_workflow_invocation(
            invocation_name=invocation_name,
            poll_interval_seconds=args.poll_interval,
            timeout_seconds=args.poll_timeout,
        )
        if not success:
            sys.exit(1)


if __name__ == "__main__":
    main()
