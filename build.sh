#!/bin/bash

# ---------------------------------------------------------------
# NOTE: ACTIVITY_SUB_TASK_CODE is managed by the BuildPiper
#       environment. Do NOT override it here to ensure events
#       appear correctly in the UI.
# ---------------------------------------------------------------

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh

if [ "$DEBUG" = true ]; then
    set -x
fi

# ---------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------
JSON_FILE="/bp/data/environment_build"
BUILD_REPOSITORY_URL=$(getComponentName)
BUILD_REPOSITORY_TAG=$(getRepositoryTag)
IMAGE="${BUILD_REPOSITORY_URL}:${BUILD_REPOSITORY_TAG}"
ENV_MASTER=$(jq -r '.environment.environment_master' "$JSON_FILE")
TASK_STATUS=0

# ---------------------------------------------------------------
# 1. Initialization
# ---------------------------------------------------------------
logInfoMessage "> Starting step: remove_tag_registry"
logInfoMessage "> Target image: ${IMAGE}"
logInfoMessage "> Environment: ${ENV_MASTER}"

add_event "INITIALIZATION" "Successful" \
    "Remove Tag Registry step initialized" \
    "Image: ${IMAGE} | Env: ${ENV_MASTER}"

if [ -n "$SLEEP_DURATION" ] && [ "$SLEEP_DURATION" -gt 0 ] 2>/dev/null; then
    logInfoMessage "> Sleeping for ${SLEEP_DURATION} second(s)..."
    sleep "$SLEEP_DURATION"
fi

# ---------------------------------------------------------------
# 2. Input Validation
# ---------------------------------------------------------------
logInfoMessage "> Validating inputs..."

if [ -z "$BUILD_REPOSITORY_URL" ] || [ -z "$BUILD_REPOSITORY_TAG" ]; then
    logErrorMessage "> BUILD_REPOSITORY_URL or BUILD_REPOSITORY_TAG is not set — cannot proceed"
    add_event "INPUT_VALIDATION" "Failed" \
        "Required image metadata is missing" \
        "URL: ${BUILD_REPOSITORY_URL:-<unset>} | Tag: ${BUILD_REPOSITORY_TAG:-<unset>}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

# Detect registry type based on URL
if [[ "$BUILD_REPOSITORY_URL" == *".amazonaws.com"* ]]; then
    REGISTRY_TYPE="ecr"
    REPOSITORY_NAME="${BUILD_REPOSITORY_URL#*.amazonaws.com/}"
    AWS_REGION=$(echo "$BUILD_REPOSITORY_URL" | cut -d'.' -f4)
else
    REGISTRY_TYPE="v2"
    REGISTRY_HOST=$(echo "$BUILD_REPOSITORY_URL" | cut -d'/' -f1)
    REPOSITORY_NAME=$(echo "$BUILD_REPOSITORY_URL" | cut -d'/' -f2-)
fi

# Check AWS CLI only if it is ECR registry
if [[ "$REGISTRY_TYPE" == "ecr" ]]; then
    if ! command -v aws > /dev/null 2>&1; then
        logErrorMessage "> AWS CLI is not installed — cannot proceed with AWS ECR"
        add_event "INPUT_VALIDATION" "Failed" \
            "AWS CLI not found in environment" \
            "Install awscli before running this step with AWS ECR"
        saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
        exit 1
    fi
fi

add_event "INPUT_VALIDATION" "Successful" \
    "All required inputs validated" \
    "Type: ${REGISTRY_TYPE} | Repository: ${REPOSITORY_NAME} | Tag: ${BUILD_REPOSITORY_TAG}"

# ---------------------------------------------------------------
# 3. Environment Safety Check
# ---------------------------------------------------------------
logInfoMessage "> Checking environment safety: ${ENV_MASTER}"

if [[ "$ENV_MASTER" == "prod" ]]; then
    logErrorMessage "> Image deletion is NOT allowed in the PROD environment"
    add_event "ENVIRONMENT_VALIDATION" "Failed" \
        "Image deletion blocked — PROD environment detected" \
        "Environment: ${ENV_MASTER} | Image: ${IMAGE}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

logInfoMessage "> Environment validated — deletion allowed in: ${ENV_MASTER}"
add_event "ENVIRONMENT_VALIDATION" "Successful" \
    "Environment validated — deletion allowed" \
    "Environment: ${ENV_MASTER}"

# ---------------------------------------------------------------
# 4. Execution Summary
# ---------------------------------------------------------------
echo ""
echo "> Remove Tag Registry Execution Summary"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Parameter" "Value"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Registry Type" "${REGISTRY_TYPE}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
if [[ "$REGISTRY_TYPE" == "ecr" ]]; then
    printf '| %-28s | %-48s |\n' "Repository" "${REPOSITORY_NAME}"
    printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
    printf '| %-28s | %-48s |\n' "AWS Region" "${AWS_REGION}"
    printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
else
    printf '| %-28s | %-48s |\n' "Registry Host" "${REGISTRY_HOST}"
    printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
    printf '| %-28s | %-48s |\n' "Repository" "${REPOSITORY_NAME}"
    printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
fi
printf '| %-28s | %-48s |\n' "Tag" "${BUILD_REPOSITORY_TAG}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Environment" "${ENV_MASTER}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Delete Tag" "${DELETE_TAG:-no}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Assume Role" "${ASSUME_ROLE:-false}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
echo ""

# ---------------------------------------------------------------
# 5. Registry Actions Execution
# ---------------------------------------------------------------
if [[ "$REGISTRY_TYPE" == "ecr" ]]; then
    # ===============================================================
    # AWS ECR Registry Flow
    # ===============================================================
    
    # IAM Role Assumption (optional)
    if [ "${ASSUME_ROLE}" == "true" ]; then
        logInfoMessage "> Assuming IAM role: arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

        if [ -z "$ACCOUNT_ID" ] || [ -z "$ROLE_NAME" ]; then
            logErrorMessage "> ACCOUNT_ID or ROLE_NAME is not set — required when ASSUME_ROLE=true"
            add_event "IAM_ROLE_ASSUMPTION" "Failed" \
                "Missing ACCOUNT_ID or ROLE_NAME for role assumption" \
                "ASSUME_ROLE=true but credentials are missing"
            saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
            exit 1
        fi

        ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
        getAssumeRole "$ROLE_ARN"

        logInfoMessage "> IAM role assumed successfully: ${ROLE_ARN}"
        add_event "IAM_ROLE_ASSUMPTION" "Successful" \
            "IAM role assumed successfully" \
            "Role ARN: ${ROLE_ARN}"
    fi

    # ECR Repository Validation
    logInfoMessage "> Verifying ECR repository exists: ${REPOSITORY_NAME}..."

    if [ -n "$PROFILE" ]; then
        aws ecr describe-repositories \
            --repository-names "$REPOSITORY_NAME" \
            --region "$AWS_REGION" \
            --profile "$PROFILE" > /dev/null 2>&1
    else
        aws ecr describe-repositories \
            --repository-names "$REPOSITORY_NAME" \
            --region "$AWS_REGION" > /dev/null 2>&1
    fi

    if [ $? -ne 0 ]; then
        logErrorMessage "> ECR repository not found: ${REPOSITORY_NAME} in region ${AWS_REGION}"
        add_event "ECR_REPOSITORY_CHECK" "Failed" \
            "ECR repository not found" \
            "Repository: ${REPOSITORY_NAME} | Region: ${AWS_REGION}"
        saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
        exit 1
    fi

    logInfoMessage "> ECR repository confirmed: ${REPOSITORY_NAME}"
    add_event "ECR_REPOSITORY_CHECK" "Successful" \
        "ECR repository verified" \
        "Repository: ${REPOSITORY_NAME} | Region: ${AWS_REGION}"

    # Image Tag Existence Check
    logInfoMessage "> Checking if tag '${BUILD_REPOSITORY_TAG}' exists in repository..."

    if [ -n "$PROFILE" ]; then
        IMAGE_EXISTS=$(aws ecr describe-images \
            --repository-name "$REPOSITORY_NAME" \
            --image-ids imageTag="$BUILD_REPOSITORY_TAG" \
            --region "$AWS_REGION" \
            --query 'imageDetails[0].imageTags[0]' \
            --output text \
            --profile "$PROFILE" 2>/dev/null || true)
    else
        IMAGE_EXISTS=$(aws ecr describe-images \
            --repository-name "$REPOSITORY_NAME" \
            --image-ids imageTag="$BUILD_REPOSITORY_TAG" \
            --region "$AWS_REGION" \
            --query 'imageDetails[0].imageTags[0]' \
            --output text 2>/dev/null || true)
    fi

    if [[ "$IMAGE_EXISTS" == "None" || -z "$IMAGE_EXISTS" ]]; then
        logErrorMessage "> Tag '${BUILD_REPOSITORY_TAG}' does not exist in repository '${REPOSITORY_NAME}'"
        add_event "IMAGE_EXISTENCE_CHECK" "Failed" \
            "Image tag not found in ECR repository" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME}"
        saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
        exit 1
    fi

    logInfoMessage "> Tag confirmed in repository: ${BUILD_REPOSITORY_TAG}"
    add_event "IMAGE_EXISTENCE_CHECK" "Successful" \
        "Image tag exists in ECR repository" \
        "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME}"

    # Image Tag Deletion
    if [[ "$DELETE_TAG" == "yes" ]]; then
        logWarningMessage "> DELETE_TAG=yes — proceeding to delete tag: ${BUILD_REPOSITORY_TAG}"
        logWarningMessage "> Repository: ${REPOSITORY_NAME} | Environment: ${ENV_MASTER}"

        add_event "IMAGE_DELETION_START" "Successful" \
            "Starting image tag deletion" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME}"

        if [ -n "$PROFILE" ]; then
            DELETE_OUTPUT=$(aws ecr batch-delete-image \
                --repository-name "$REPOSITORY_NAME" \
                --image-ids imageTag="$BUILD_REPOSITORY_TAG" \
                --region "$AWS_REGION" \
                --output json \
                --profile "$PROFILE")
        else
            DELETE_OUTPUT=$(aws ecr batch-delete-image \
                --repository-name "$REPOSITORY_NAME" \
                --image-ids imageTag="$BUILD_REPOSITORY_TAG" \
                --region "$AWS_REGION" \
                --output json)
        fi

        FAIL_COUNT=$(echo "$DELETE_OUTPUT" | jq '.failures | length' 2>/dev/null || echo "0")
        if [[ "$FAIL_COUNT" -gt 0 ]]; then
            logErrorMessage "> Failed to delete image tag '${BUILD_REPOSITORY_TAG}' (failures: ${FAIL_COUNT})"
            logErrorMessage "> AWS response: ${DELETE_OUTPUT}"
            add_event "IMAGE_DELETION_RESULT" "Failed" \
                "Image tag deletion failed" \
                "Tag: ${BUILD_REPOSITORY_TAG} | Failures: ${FAIL_COUNT} | Check AWS response"
            saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
            exit 1
        fi

        logInfoMessage "> Tag '${BUILD_REPOSITORY_TAG}' deleted successfully from '${REPOSITORY_NAME}'"
        add_event "IMAGE_DELETION_RESULT" "Successful" \
            "Image tag deleted successfully" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME}"
    else
        logWarningMessage "> DELETE_TAG is not set to 'yes' — skipping deletion of tag '${BUILD_REPOSITORY_TAG}'"
        add_event "IMAGE_DELETION_RESULT" "Successful" \
            "Image tag deletion skipped — DELETE_TAG is not 'yes'" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Set DELETE_TAG=yes to enable deletion"
    fi

else
    # ===============================================================
    # Standard Docker Registry V2 Flow (Harbor, Nexus, Self-hosted)
    # ===============================================================
    logInfoMessage "> Fetching credentials for registry: ${REGISTRY_HOST}..."

    # Use Python script to safely parse and decrypt the credentials matching REGISTRY_HOST
    export FERNET_KEY
    export TARGET_HOST="${REGISTRY_HOST}"
    
    CREDENTIALS=$(python3 - <<'PY'
import json
import os
from cryptography.fernet import Fernet

fernet_key = os.environ.get("FERNET_KEY")
target_host = os.environ.get("TARGET_HOST")

try:
    with open("/bp/data/environment_build") as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR: Failed to read build JSON: {e}")
    exit(1)

registries = data.get("registry", [])
if isinstance(registries, dict):
    registries = [registries]

found = False
for reg in registries:
    url = reg.get("url", "")
    norm_url = url.replace("https://", "").replace("http://", "").rstrip("/")
    if norm_url == target_host:
        try:
            f_obj = Fernet(fernet_key.encode())
            user = f_obj.decrypt(reg["username"].encode()).decode()
            password = f_obj.decrypt(reg["password"].encode()).decode()
            print(f"{user}\n{password}")
            found = True
            break
        except Exception as e:
            print(f"ERROR: Decryption failed: {e}")
            exit(1)

if not found:
    print(f"ERROR: Registry credentials for {target_host} not found in build data")
    exit(1)
PY
)
    if [[ $? -ne 0 || "$CREDENTIALS" == ERROR:* ]]; then
        logErrorMessage "> Registry credential error: ${CREDENTIALS}"
        add_event "REGISTRY_CREDENTIALS" "Failed" \
            "Failed to retrieve registry credentials" \
            "Error: ${CREDENTIALS}"
        saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
        exit 1
    fi

    REG_USER=$(echo "$CREDENTIALS" | sed -n '1p')
    REG_PASS=$(echo "$CREDENTIALS" | sed -n '2p')

    logInfoMessage "> Successfully retrieved credentials for user: ${REG_USER}"

    # Challenge the registry to check auth type (Bearer vs Basic)
    # Use GET request with header dump instead of HEAD request, as HEAD is disallowed on some registries
    logInfoMessage "> Querying registry for authentication challenge: https://${REGISTRY_HOST}/v2/${REPOSITORY_NAME}/manifests/${BUILD_REPOSITORY_TAG}"
    
    CHALLENGE=$(curl -s -D - -o /tmp/challenge_body.json -u "${REG_USER}:${REG_PASS}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://${REGISTRY_HOST}/v2/${REPOSITORY_NAME}/manifests/${BUILD_REPOSITORY_TAG}")

    HTTP_STATUS=$(echo "$CHALLENGE" | grep -i "HTTP/" | head -n 1 | awk '{print $2}')
    logInfoMessage "> Registry status response for manifest query: ${HTTP_STATUS}"

    if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "401" ]]; then
        logWarningMessage "> Registry challenge returned unexpected status: ${HTTP_STATUS}"
        if [ -f /tmp/challenge_body.json ]; then
            logWarningMessage "> Challenge response: $(cat /tmp/challenge_body.json)"
        fi
    fi

    if echo "$CHALLENGE" | grep -iq "Www-Authenticate: Bearer"; then
        logInfoMessage "> Bearer token authentication challenge detected"
        WWW_AUTH=$(echo "$CHALLENGE" | grep -i "Www-Authenticate:" | head -n 1)
        REALM=$(echo "$WWW_AUTH" | sed -n 's/.*realm="\(https[^"]*\)".*/\1/p')
        SERVICE=$(echo "$WWW_AUTH" | sed -n 's/.*service="\(#[^"]*\|[^"]*\)".*/\1/p')
        SCOPE="repository:${REPOSITORY_NAME}:pull,push,*"

        logInfoMessage "> Requesting registry bearer token from: ${REALM}"
        TOKEN_RESPONSE=$(curl -s -u "${REG_USER}:${REG_PASS}" "${REALM}?service=${SERVICE}&scope=${SCOPE}")
        TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .access_token // empty')

        if [ -n "$TOKEN" ]; then
            logInfoMessage "> Bearer token successfully obtained"
            AUTH_HEADER="Authorization: Bearer ${TOKEN}"
        else
            logWarningMessage "> Failed to obtain Bearer token, falling back to Basic authentication"
            AUTH_HEADER="Authorization: Basic $(echo -n "${REG_USER}:${REG_PASS}" | base64 | tr -d '\n')"
        fi
    else
        logInfoMessage "> Standard Basic authentication detected"
        AUTH_HEADER="Authorization: Basic $(echo -n "${REG_USER}:${REG_PASS}" | base64 | tr -d '\n')"
    fi

    # Image Tag Existence Check (V2 Registry)
    logInfoMessage "> Checking if tag '${BUILD_REPOSITORY_TAG}' exists in repository '${REPOSITORY_NAME}'..."
    
    MANIFEST_RESP=$(curl -s -D - -o /tmp/manifest_body.json \
        -H "${AUTH_HEADER}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://${REGISTRY_HOST}/v2/${REPOSITORY_NAME}/manifests/${BUILD_REPOSITORY_TAG}")

    DIGEST=$(echo "$MANIFEST_RESP" | grep -i "Docker-Content-Digest" | head -n 1 | awk '{print $2}' | tr -d '\r\n')

    if [ -z "$DIGEST" ]; then
        logErrorMessage "> Tag '${BUILD_REPOSITORY_TAG}' not found or Digest could not be retrieved from ${REGISTRY_HOST}"
        if [ -f /tmp/manifest_body.json ]; then
            logErrorMessage "> Registry response body: $(cat /tmp/manifest_body.json)"
        fi
        logErrorMessage "> Registry response headers: "
        echo "$MANIFEST_RESP" | head -n 25
        
        add_event "IMAGE_EXISTENCE_CHECK" "Failed" \
            "Image tag not found in registry" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME} | Registry: ${REGISTRY_HOST}"
        saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
        exit 1
    fi

    logInfoMessage "> Tag confirmed in repository: ${BUILD_REPOSITORY_TAG} (Digest: ${DIGEST})"
    add_event "IMAGE_EXISTENCE_CHECK" "Successful" \
        "Image tag exists in registry" \
        "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME} | Digest: ${DIGEST}"

    # Image Tag Deletion (V2 Registry)
    if [[ "$DELETE_TAG" == "yes" ]]; then
        logWarningMessage "> DELETE_TAG=yes — proceeding to delete tag: ${BUILD_REPOSITORY_TAG}"
        add_event "IMAGE_DELETION_START" "Successful" \
            "Starting image tag deletion" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME} | Registry: ${REGISTRY_HOST}"

        DELETE_HTTP_CODE=$(curl -s -o /tmp/registry_delete_response.json -w "%{http_code}" -X DELETE \
            -H "${AUTH_HEADER}" \
            "https://${REGISTRY_HOST}/v2/${REPOSITORY_NAME}/manifests/${DIGEST}")

        logInfoMessage "> Delete response HTTP code: ${DELETE_HTTP_CODE}"

        if [[ "$DELETE_HTTP_CODE" == "200" || "$DELETE_HTTP_CODE" == "202" || "$DELETE_HTTP_CODE" == "204" ]]; then
            logInfoMessage "> Tag '${BUILD_REPOSITORY_TAG}' deleted successfully from '${REPOSITORY_NAME}'"
            add_event "IMAGE_DELETION_RESULT" "Successful" \
                "Image tag deleted successfully" \
                "Tag: ${BUILD_REPOSITORY_TAG} | Repository: ${REPOSITORY_NAME} | Registry: ${REGISTRY_HOST}"
        else
            logErrorMessage "> Failed to delete image tag '${BUILD_REPOSITORY_TAG}' (HTTP ${DELETE_HTTP_CODE})"
            if [ -f /tmp/registry_delete_response.json ]; then
                logErrorMessage "> Registry response details: $(cat /tmp/registry_delete_response.json)"
            fi
            add_event "IMAGE_DELETION_RESULT" "Failed" \
                "Image tag deletion failed" \
                "Tag: ${BUILD_REPOSITORY_TAG} | HTTP Code: ${DELETE_HTTP_CODE} | Registry: ${REGISTRY_HOST}"
            saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
            exit 1
        fi
    else
        logWarningMessage "> DELETE_TAG is not set to 'yes' — skipping deletion of tag '${BUILD_REPOSITORY_TAG}'"
        add_event "IMAGE_DELETION_RESULT" "Successful" \
            "Image tag deletion skipped — DELETE_TAG is not 'yes'" \
            "Tag: ${BUILD_REPOSITORY_TAG} | Set DELETE_TAG=yes to enable deletion"
    fi
fi

# ---------------------------------------------------------------
# 9. Final Status
# ---------------------------------------------------------------
logInfoMessage "> Remove Tag Registry step completed successfully"
saveTaskStatus 0 "${ACTIVITY_SUB_TASK_CODE}"
exit 0
