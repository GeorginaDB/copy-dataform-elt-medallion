#!/bin/bash
# Script to compile Dataform Release Configurations 

API_URL="https://dataform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/repositories/${REPOSITORY}"

# ACCESS_TOKEN is now passed as an environment variable from Terraform

compile_release() {
  local release_config_id=$1
  local release_config_path="projects/${PROJECT_ID}/locations/${REGION}/repositories/${REPOSITORY}/releaseConfigs/${release_config_id}"
  
  echo "Step 1: Fetching current config to get required 'gitCommitish'..."
  # Fetch the existing release configuration details
  current_config=$(curl -s -X GET \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${API_URL}/releaseConfigs/${release_config_id}")
    
  # Extract the git branch/commit it uses
  git_commitish=$(echo "$current_config" | jq -r '.gitCommitish')
  
  if [ "$git_commitish" == "null" ] || [ -z "$git_commitish" ]; then
    echo "Error fetching gitCommitish: $current_config"
    return 1
  fi
  
  echo "Step 2: Compiling Release Config: ${release_config_id} (Branch: ${git_commitish})..."
  # Create the compilation result
  response=$(curl -s -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"releaseConfig\": \"${release_config_path}\"}" \
    "${API_URL}/compilationResults")
    
  compilation_name=$(echo "$response" | jq -r '.name')
  
  if [ "$compilation_name" == "null" ] || [ -z "$compilation_name" ]; then
    echo "Error generating compilation result: $response"
    return 1
  fi
  
  echo "Step 3: Assigning compilation result as 'live' for ${release_config_id}..."
  # Patch the release config, explicitly passing the required gitCommitish
  curl -s -X PATCH \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"gitCommitish\": \"${git_commitish}\",
      \"releaseCompilationResult\": \"${compilation_name}\"
    }" \
    "${API_URL}/releaseConfigs/${release_config_id}?updateMask=releaseCompilationResult"
    
  echo -e "\nRelease config ${release_config_id} is now LIVE.\n"
}

compile_release ${RELEASE_ID}

echo "All release configurations compiled and updated successfully."