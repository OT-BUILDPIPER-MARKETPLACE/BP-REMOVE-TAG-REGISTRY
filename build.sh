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
REPOSITORY_NAME="${BUILD_REPOSITORY_URL#*.amazonaws.com/}"
AWS_REGION=$(echo "$BUILD_REPOSITORY_URL" | cut -d'.' -f4)
ENV_MASTER=$(jq -r '.environment.environment_master' "$JSON_FILE")
TASK_STATUS=0

# ---------------------------------------------------------------
# 1. Initialization
# ---------------------------------------------------------------
logInfoMessage "> Starting step: remove_tag_registry"
logInfoMessage "> Target image: ${IMAGE}"
logInfoMessage "> Repository: ${REPOSITORY_NAME}"
logInfoMessage "> AWS Region: ${AWS_REGION}"
logInfoMessage "> Environment: ${ENV_MASTER}"

add_event "INITIALIZATION" "Successful" \
    "Remove Tag Registry step initialized" \
    "Image: ${IMAGE} | Region: ${AWS_REGION} | Env: ${ENV_MASTER}"

if [ -n "$SLEEP_DURATION" ] && [ "$SLEEP_DURATION" -gt 0 ] 2>/dev/null; then
    logInfoMessage "> Sleeping for ${SLEEP_DURATION} second(s)..."
    sleep "$SLEEP_DURATION"
fi

# ---------------------------------------------------------------
# 2. Input Validation
# ---------------------------------------------------------------
logInfoMessage "> Validating inputs..."

if [ -z "$REPOSITORY_NAME" ] || [ -z "$BUILD_REPOSITORY_TAG" ]; then
    logErrorMessage "> REPOSITORY_NAME or BUILD_REPOSITORY_TAG is not set — cannot proceed"
    add_event "INPUT_VALIDATION" "Failed" \
        "Required image metadata is missing" \
        "Repository: ${REPOSITORY_NAME:-<unset>} | Tag: ${BUILD_REPOSITORY_TAG:-<unset>}"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

if ! command -v aws > /dev/null 2>&1; then
    logErrorMessage "> AWS CLI is not installed — cannot proceed"
    add_event "INPUT_VALIDATION" "Failed" \
        "AWS CLI not found in environment" \
        "Install awscli before running this step"
    saveTaskStatus 1 "${ACTIVITY_SUB_TASK_CODE}"
    exit 1
fi

add_event "INPUT_VALIDATION" "Successful" \
    "All required inputs validated" \
    "Repository: ${REPOSITORY_NAME} | Tag: ${BUILD_REPOSITORY_TAG} | Region: ${AWS_REGION}"

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
printf '| %-28s | %-48s |\n' "Repository" "${REPOSITORY_NAME}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Tag" "${BUILD_REPOSITORY_TAG}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "AWS Region" "${AWS_REGION}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Environment" "${ENV_MASTER}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Delete Tag" "${DELETE_TAG:-no}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
printf '| %-28s | %-48s |\n' "Assume Role" "${ASSUME_ROLE:-false}"
printf '+%-30s+%-50s+\n' '------------------------------' '--------------------------------------------------'
echo ""

# ---------------------------------------------------------------
# 5. IAM Role Assumption (optional)
# ---------------------------------------------------------------
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

# ---------------------------------------------------------------
# 6. ECR Repository Validation
# ---------------------------------------------------------------
logInfoMessage "> Verifying ECR repository exists: ${REPOSITORY_NAME}..."

ECR_CHECK_OPTS="--repository-names \"${REPOSITORY_NAME}\" --region \"${AWS_REGION}\""
[ -n "$PROFILE" ] && ECR_CHECK_OPTS+=" --profile \"${PROFILE}\""

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

# ---------------------------------------------------------------
# 7. Image Tag Existence Check
# ---------------------------------------------------------------
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

# ---------------------------------------------------------------
# 8. Image Tag Deletion
# ---------------------------------------------------------------
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

# ---------------------------------------------------------------
# 9. Final Status
# ---------------------------------------------------------------
logInfoMessage "> Remove Tag Registry step completed successfully"
saveTaskStatus 0 "${ACTIVITY_SUB_TASK_CODE}"
exit 0
