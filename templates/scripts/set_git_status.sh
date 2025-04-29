#!/bin/bash

# Script to detect GitHub repo type and set commit/PR status using the GitHub API
# Reads GITHUB_TOKEN and GIT_REF from the environment (expected to be mounted from K8s secret)

# --- Configuration ---
# GITHUB_TOKEN and GIT_REF are expected to be in the environment variables

# --- Functions ---
function check_prereqs() {
  if ! command -v curl &> /dev/null; then
    echo "Error: 'curl' command not found." >&2
    exit 1
  fi
  if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' command not found." >&2
    exit 1
  fi
}

function github_api_request() {
  local api_url="$1"
  local http_method="${2:-GET}" # Default to GET
  local request_body="$3"
  local curl_opts=("-sSLf")

  # Add Authorization header if token is set
  if [[ -n "$GITHUB_TOKEN" ]]; then
    curl_opts+=("-H" "Authorization: token $GITHUB_TOKEN")
  else
    echo "Warning: GITHUB_TOKEN environment variable not set. Making unauthenticated request (check secret mount)." >&2
    curl_opts+=("-H" "User-Agent: ArgoWorkflow-ProjectTypeDetector")
  fi

  # Add standard Accept header
  curl_opts+=("-H" "Accept: application/vnd.github.v3+json")

  if [[ "$http_method" == "POST" ]] || [[ "$http_method" == "PATCH" ]] || [[ "$http_method" == "PUT" ]]; then
    curl_opts+=("-X" "$http_method")
    if [[ -n "$request_body" ]]; then
      curl_opts+=("-H" "Content-Type: application/json")
      curl_opts+=("-d" "$request_body")
    fi
  fi

  echo "Making $http_method request to '$api_url'..." >&2

  if ! api_response=$(curl "${curl_opts[@]}" "$api_url" 2> >(cat >&2)); then
    echo "Error: curl command failed to make request to '$api_url'." >&2
    if ! [[ -n "$GITHUB_TOKEN" ]]; then
      echo "Hint: Was the GITHUB_TOKEN secret mounted correctly?" >&2
    fi
    echo "Hint: Check repository name, permissions, and network connectivity from the pod." >&2
    return 1
  fi

  # Basic JSON validity check
  if ! jq -e . >/dev/null 2>&1 <<< "$api_response"; then
    echo "Error: Invalid JSON received from GitHub API at '$api_url'." >&2
    echo "Response: $api_response" >&2
    return 1
  fi

  echo "$api_response" # Output the JSON response
  return 0
}

function detect_project_type() {
  local repo_full_name="$1"
  local detected_type="unknown"
  local api_url="https://api.github.com/repos/${repo_full_name}/contents/?ref=${GIT_REF}"

  local response=$(github_api_request "$api_url")
  local api_status=$?

  if [[ $api_status -ne 0 ]]; then
    echo "Failed to fetch repository contents for '$repo_full_name'." >&2
    return 1
  fi

  local file_list=$(echo "$response" | jq -r '.[] | select(. != null) | if .type == "dir" then .name + "/" else .name end')

  if [[ -z "$file_list" ]]; then
    echo "Warning: Repository root seems empty or could not parse file list." >&2
  else
    # --- Detection Logic (Priority Order) ---
    if echo "$file_list" | grep -q -E '\.sln$|\.csproj$'; then
      detected_type="dotnet"
    elif echo "$file_list" | grep -q '^package\.json$'; then
      detected_type="nodejs"
    elif echo "$file_list" | grep -q '^build\.sbt$'; then
      detected_type="scala"
    elif echo "$file_list" | grep -q '^\.jfrog/$'; then
      detected_type="jfrog"
    fi
  fi

  echo "$detected_type"
  return 0
}

function set_commit_status() {
  local repo_full_name="$1"
  local commit_sha="$2"
  local state="$3"        # "pending", "success", "error", "failure"
  local target_url="$4"    # URL to associate with the status
  local description="$5"  # Short description of the status
  local context="$6"      # Context for the status (e.g., "argo-workflow")

  local api_url="https://api.github.com/repos/${repo_full_name}/statuses/$commit_sha"
  local request_body="{\"state\":\"$state\",\"target_url\":\"$target_url\",\"description\":\"$description\",\"context\":\"$context\"}"

  github_api_request "$api_url" "POST" "$request_body"
  local status_code=$?

  if [[ $status_code -ne 0 ]]; then
    echo "Failed to set commit status for $repo_full_name:$commit_sha." >&2
    return 1
  else
    echo "Successfully set commit status '$state' for $repo_full_name:$commit_sha (context: $context)." >&2
    return 0
  fi
}

# --- Main Script Logic ---
check_prereqs

# Check for required environment variables
if [[ -z "$REPO_FULL_NAME" ]]; then
  echo "Error: REPO_FULL_NAME environment variable not set." >&2
  exit 1
fi

if [[ -z "$GIT_REF" ]]; then
  echo "Error: GIT_REF environment variable not set." >&2
  exit 1
fi

# Basic validation for OWNER/REPO format
if ! [[ "$REPO_FULL_NAME" =~ ^[^/]+/[^/]+$ ]]; then
   echo "Error: Repository name '$REPO_FULL_NAME' must be in OWNER/REPOSITORY_NAME format." >&2
   exit 1
fi

# --- Example Usage ---

# 1. Detect Project Type
project_type=$(detect_project_type "$REPO_FULL_NAME")
detect_exit_code=$?

if [[ $detect_exit_code -ne 0 ]]; then
  echo "Failed to determine project type for $REPO_FULL_NAME." >&2
  exit 1
fi

echo "Detected project type: $project_type" >&2

output_name="default-output"
case "$project_type" in
  "dotnet")
    output_name="dotnet-workflow-template" ;;
  "nodejs")
    output_name="nodejs-workflow-template" ;;
  "scala")
    output_name="scala-workflow-template" ;;
  "jfrog")
    output_name="jfrog-workflow-template" ;;
  "unknown")
    output_name="unknown-project-type-handler" ;;
  *)
    echo "Internal Error: Unhandled project type '$project_type'" >&2
    exit 1 ;;
esac

echo "Project type output for Argo: $output_name"

# 2. Set Commit Status (Example - you'll likely call this from a different step)
# To use this, you'd need to pass the commit SHA, status, etc. as environment variables
# or arguments to this script when calling it for the status update.

# Example of how you might call the set_commit_status function
# (Assuming you have COMMIT_SHA, STATUS_STATE, TARGET_URL, STATUS_DESCRIPTION, STATUS_CONTEXT in your environment)
if [[ -n "$COMMIT_SHA" ]]; then
  echo "Attempting to set commit status..." >&2
  set_commit_status "$REPO_FULL_NAME" "$COMMIT_SHA" "$STATUS_STATE" "$TARGET_URL" "$STATUS_DESCRIPTION" "$CONTEXT"
  status_exit_code=$?
  if [[ $status_exit_code -ne 0 ]]; then
    echo "Failed to set commit status." >&2
    # Optionally exit with an error code
    # exit 1
  fi
fi

exit 0