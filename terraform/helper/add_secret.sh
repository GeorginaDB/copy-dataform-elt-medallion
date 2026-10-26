#!/bin/bash

# 1. Safety Check: Ensure the key file exists
if [[ ! -f "$KEY_FILE" ]]; then
    echo "Error: Cannot find $KEY_FILE"
    exit 1
fi

echo "Deploying to Project: $PROJECT_ID"
echo "Target Secret ID: $SECRET_ID"

# 2. Base64 encode the private key (tr removes hidden newlines)
SECRET_DATA=$(cat "$KEY_FILE" | base64 | tr -d '\n\r')

# 3. Execute the API call and capture the HTTP status code
echo "Adding secret version..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "{\"payload\": {\"data\": \"${SECRET_DATA}\"}}" \
  "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${SECRET_ID}:addVersion")

# 4. Handle the response gracefully
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    echo "Success! Secret version added."
else
    echo "Failed to add secret version. HTTP Status: $HTTP_STATUS"
    echo "Error Details: $BODY"
    exit 1
fi