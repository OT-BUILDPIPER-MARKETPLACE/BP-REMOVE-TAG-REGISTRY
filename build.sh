#!/bin/bash

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh

BUILD_REPOSITORY_URL=`getComponentName`
BUILD_REPOSITORY_TAG=`getRepositoryTag`
JSON_FILE="/bp/data/environment_build"
IMAGE="${BUILD_REPOSITORY_URL}:${BUILD_REPOSITORY_TAG}"
REPOSITORY_NAME="${BUILD_REPOSITORY_URL#*.amazonaws.com/}"
AWS_REGION=$(echo "$BUILD_REPOSITORY_URL" | cut -d'.' -f4)
ENV_MASTER=$(jq -r '.environment.environment_master' "$JSON_FILE")

sleep  $SLEEP_DURATION

if [[ "$ENV_MASTER" == "prod" ]]; then
  logErrorMessage "Image deletion is not allowed in the PROD environment."
  add_event "ENVIRONMENT VALIDATION" "Failed" \
        "Image deletion blocked in PROD" \
        "Environment: $ENV_MASTER"
  TASK_STATUS=1
  saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
  exit 1
fi

add_event "ENVIRONMENT VALIDATION" "Successful" \
      "Environment validated for deletion" \
      "Environment: $ENV_MASTER"

add_event "INITIALIZATION" "Successful" \
      "Task initialization completed" \
      "Target Image: $IMAGE"

if [[ -z "$REPOSITORY_NAME" || -z "$BUILD_REPOSITORY_TAG" ]]; then
  logErrorMessage "Usage $REPOSITORY_NAME $BUILD_REPOSITORY_TAG"
  exit 1
fi

if [ "${ASSUME_ROLE}" == "true" ]; then
    if [ -z "$ACCOUNT_ID" ] || [ -z "$ROLE_NAME" ]; then
          logErrorMessage "Error: ACCOUNT_ID and ROLE_NAME must be set as environment variables when ASSUME_ROLE=true"
          add_event "AWS ROLE ASSUMPTION" "Failed" \
                "Missing ACCOUNT_ID or ROLE_NAME" \
                "ASSUME_ROLE is true but credentials missing"
          exit 1
    fi
      ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
      getAssumeRole "$ROLE_ARN"
      add_event "AWS ROLE ASSUMPTION" "Successful" \
            "Successfully assumed AWS role" \
            "Role ARN: $ROLE_ARN"
else
    logInfoMessage "ASSUME_ROLE is not set to 'true', skipping role assumption"
fi


if ! command -v aws >/dev/null 2>&1; then
logErrorMessage "AWS CLI is not installed."
  exit 1
fi

logInfoMessage "------------------------------------------"
logInfoMessage "Repository  : $REPOSITORY_NAME"
logInfoMessage "Tag         : $BUILD_REPOSITORY_TAG"
logInfoMessage "Region      : $AWS_REGION"
logInfoMessage "Environment : $ENV_MASTER"
logInfoMessage "-------------------------------------------"


if [ -n "$PROFILE" ]; then
    logInfoMessage "AWS PROFILE: $PROFILE"
    logInfoMessage "aws ecr describe-repositories --repository-names $REPOSITORY_NAME --region $AWS_REGION --profile $PROFILE"

    if ! aws ecr describe-repositories \
        --repository-names "$REPOSITORY_NAME" \
        --region "$AWS_REGION" \
        --profile "$PROFILE" >/dev/null 2>&1; then
        logErrorMessage "Repository '$REPOSITORY_NAME' not found."
        exit 1
    fi
else
    logInfoMessage "aws ecr describe-repositories --repository-names $REPOSITORY_NAME --region $AWS_REGION"

    if ! aws ecr describe-repositories \
        --repository-names "$REPOSITORY_NAME" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        logErrorMessage "Repository '$REPOSITORY_NAME' not found."
        add_event "ECR REPOSITORY CHECK" "Failed" \
              "Repository not found" \
              "Repository: $REPOSITORY_NAME"
        exit 1
    fi
fi

add_event "ECR REPOSITORY CHECK" "Successful" \
      "ECR repository found" \
      "Repository: $REPOSITORY_NAME"

if [ -n "$PROFILE" ]; then
    logInfoMessage "AWS PROFILE: $PROFILE"
    logInfoMessage "aws ecr describe-images --repository-name $REPOSITORY_NAME --image-ids imageTag=$BUILD_REPOSITORY_TAG --region $AWS_REGION --query 'imageDetails[0].imageTags[0]' --profile $PROFILE"
    IMAGE_EXISTS=$(aws ecr describe-images --repository-name "$REPOSITORY_NAME" --image-ids imageTag="$BUILD_REPOSITORY_TAG" --region "$AWS_REGION" --query 'imageDetails[0].imageTags[0]' --output text --profile $PROFILE 2>/dev/null || true )
else
    logInfoMessage "aws ecr batch-delete-image --repository-name $REPOSITORY_NAME --image-ids imageTag=$BUILD_REPOSITORY_TAG --region $AWS_REGION"
    IMAGE_EXISTS=$(aws ecr describe-images --repository-name "$REPOSITORY_NAME" --image-ids imageTag="$BUILD_REPOSITORY_TAG" --region "$AWS_REGION" --query 'imageDetails[0].imageTags[0]' --output text 2>/dev/null || true)
fi



if [[ "$IMAGE_EXISTS" == "None" || -z "$IMAGE_EXISTS" ]]; then
  logErrorMessage "Tag '$BUILD_REPOSITORY_TAG' does not exist in repository '$REPOSITORY_NAME'."
  add_event "IMAGE EXISTENCE CHECK" "Failed" \
        "Image tag not found" \
        "Tag: $BUILD_REPOSITORY_TAG in $REPOSITORY_NAME"
  exit 1
fi

add_event "IMAGE EXISTENCE CHECK" "Successful" \
      "Image tag found" \
      "Tag: $BUILD_REPOSITORY_TAG in $REPOSITORY_NAME"

logInfoMessage "Tag found. Proceeding with deletion"

if [[ "$DELETE_TAG" == "yes" ]]; then
    logWarningMessage "-----------------------------------------------------------------------------------------------"
    logWarningMessage "                                                                                           ----"
    logWarningMessage "DELETE_TAG is yes deleting tag $BUILD_REPOSITORY_TAG from repository $REPOSITORY_NAME"
    logWarningMessage "                                                                                           ----"
    logWarningMessage "Do NOT use this step in the PROD environment."
    logWarningMessage "                                                                                           ----"
    logWarningMessage "-----------------------------------------------------------------------------------------------"


  if [ -n "$PROFILE" ]; then
      logInfoMessage "AWS PROFILE: $PROFILE"
      logInfoMessage "aws ecr batch-delete-image --repository-name $REPOSITORY_NAME --image-ids imageTag=$BUILD_REPOSITORY_TAG --region $AWS_REGION --profile $PROFILE"

      DELETE_OUTPUT=$(aws ecr batch-delete-image \
        --repository-name "$REPOSITORY_NAME" \
        --image-ids imageTag="$BUILD_REPOSITORY_TAG" \
        --region "$AWS_REGION" \
        --output json \
        --profile "$PROFILE")
  else
      logInfoMessage "aws ecr batch-delete-image --repository-name $REPOSITORY_NAME --image-ids imageTag=$BUILD_REPOSITORY_TAG --region $AWS_REGION"

      DELETE_OUTPUT=$(aws ecr batch-delete-image \
        --repository-name "$REPOSITORY_NAME" \
        --image-ids imageTag="$BUILD_REPOSITORY_TAG" \
        --region "$AWS_REGION" \
        --output json)
  fi

  if echo "$DELETE_OUTPUT" | grep -q "failures"; then
    FAIL_COUNT=$(echo "$DELETE_OUTPUT" | jq '.failures | length')
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
      logErrorMessage "Failed to delete image tag."
      logErrorMessage "$DELETE_OUTPUT"
      add_event "IMAGE DELETION" "Failed" \
            "Failed to delete image tag" \
            "AWS Error: $DELETE_OUTPUT"
      exit 1
    fi
  fi
  add_event "IMAGE DELETION" "Successful" \
        "Image tag deleted successfully" \
        "Tag $BUILD_REPOSITORY_TAG removed from $REPOSITORY_NAME"
logInfoMessage "SUCCESS: Tag '$BUILD_REPOSITORY_TAG' deleted from '$REPOSITORY_NAME'."
else
    logWarningMessage "-------------------------------------------------------------------------------------------------------------------"
    logWarningMessage "                                                                                                               ----"
    logWarningMessage "Skipping deletion of tag $BUILD_REPOSITORY_TAG from repository $REPOSITORY_NAME DELETE_TAG is not set yes"
    logWarningMessage "                                                                                                               ----"
    logWarningMessage "-------------------------------------------------------------------------------------------------------------------"
fi

TASK_STATUS=$?
saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
add_event "TASK EXECUTION" "Successful" \
      "Tag removal task completed" \
      "Processed image: $IMAGE"
