#!/bin/bash

# Script to detect GitHub repo type using the GitHub API
# Reads GITHUB_TOKEN from the environment (expected to be mounted from a K8s secret)

# --- Configuration ---
# GITHUB_TOKEN is expected to be in the environment variables

# --- Functions ---
function check_prereqs() {
    # Optional: Could remove these if the container image is guaranteed to have them
    if ! command -v curl &> /dev/null; then
        echo "Error: 'curl' command not found." >&2
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        echo "Error: 'jq' command not found." >&2
        exit 1
    fi
}

function detect_project_type() {
    local repo_full_name="$1"
    local git_ref="${GIT_REF}"
    local detected_type="unknown"
    local api_url="https://api.github.com/repos/${repo_full_name}/contents/?ref=${git_ref}"
    local curl_opts=("-sSLf") # Silent, follow redirects, show errors, FAIL on >= 400

    # Add Authorization header if token is set
    if [[ -n "$GITHUB_TOKEN" ]]; then
        curl_opts+=("-H" "Authorization: token $GITHUB_TOKEN")
    else
         echo "Warning: GITHUB_TOKEN environment variable not set. Making unauthenticated request (check secret mount)." >&2
         # Add a User-Agent header, good practice for APIs
         curl_opts+=("-H" "User-Agent: ArgoWorkflow-ProjectTypeDetector")
    fi

    # Add standard Accept header
    curl_opts+=("-H" "Accept: application/vnd.github.v3+json")

    echo "Fetching root directory listing for '$repo_full_name' from GitHub API..." >&2

    # Make the API call using process substitution to capture output without temp file
    # Capture curl's stdout (JSON) and stderr separately
    # Check curl's exit status ($?)
    if ! api_response=$(curl "${curl_opts[@]}" "$api_url" 2> >(cat >&2)); then
         # Curl failed (exit code non-zero), error messages already went to stderr
         echo "Error: curl command failed to fetch data from GitHub API for $repo_full_name." >&2
         # Attempt to provide more context based on common issues
         if ! [[ -n "$GITHUB_TOKEN" ]]; then
            echo "Hint: Was the GITHUB_TOKEN secret mounted correctly?" >&2
         fi
         echo "Hint: Check repository name ('$repo_full_name'), permissions, and network connectivity from the pod." >&2
         return 1 # Indicate failure
    fi


    # --- If curl succeeded (exit code 0, HTTP might still be non-200 but curl didn't fail with -f) ---
    # Normally -f handles this, but if API returns non-200 JSON error, jq might fail.
    # Check if response is valid JSON before parsing filename list
     if ! jq -e . >/dev/null 2>&1 <<< "$api_response"; then
       echo "Error: Invalid JSON received from GitHub API." >&2
       echo "Response: $api_response" >&2
       return 1
     fi

    # Parse the JSON response to get filenames and types (file/dir)
    file_list=$(echo "$api_response" | jq -r '.[] | select(. != null) | if .type == "dir" then .name + "/" else .name end')

    if [[ -z "$file_list" ]]; then
        echo "Warning: Repository root seems empty or could not parse file list." >&2
        # Keep detected_type as "unknown"
    else
      # --- Detection Logic (Priority Order) ---
      # 1. DotNet
      if echo "$file_list" | grep -q -E '\.sln$'; then
          detected_type="dotnet"
      elif echo "$file_list" | grep -q -E '\.csproj$'; then
          detected_type="dotnet"
      # 2. Node.js
      elif echo "$file_list" | grep -q '^package\.json$'; then
          detected_type="nodejs"
      # 3. Scala
      elif echo "$file_list" | grep -q '^build\.sbt$'; then
          detected_type="scala"
      # 4. JFrog
      elif echo "$file_list" | grep -q '^\.jfrog/$'; then
          detected_type="jfrog"
      fi
    fi

    # Return the detected type (this goes to function caller, not stdout yet)
    echo "$detected_type"
    return 0 # Indicate success
}

# --- Main Script Logic ---
check_prereqs

# Check for input argument (passed via environment variable in Argo)
if [[ -z "$REPO_FULL_NAME" ]]; then
    echo "Error: REPO_FULL_NAME environment variable not set." >&2
    exit 1
fi

# Basic validation for OWNER/REPO format
if ! [[ "$REPO_FULL_NAME" =~ ^[^/]+/[^/]+$ ]]; then
   echo "Error: Repository name '$REPO_FULL_NAME' must be in OWNER/REPOSITORY_NAME format." >&2
   exit 1
fi

# Call detection function
# Capture the function's stdout (the detected type)
project_type=$(detect_project_type "$REPO_FULL_NAME")
detect_exit_code=$?

# Exit if detection failed
if [[ $detect_exit_code -ne 0 ]]; then
    echo "Failed to determine project type for $REPO_FULL_NAME." >&2
    exit 1
fi

echo "Detected project type: $project_type" >&2

# Case statement to determine the final output name
output_name="default-output" # Default if type is unknown
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
        output_name="unknown-project-type-handler" ;; # Handler for unknown
    *)
        echo "Internal Error: Unhandled project type '$project_type'" >&2
        exit 1 ;; # Exit on truly unexpected type
esac

# Final output to STDOUT - this is captured by Argo
echo "$output_name"

exit 0
