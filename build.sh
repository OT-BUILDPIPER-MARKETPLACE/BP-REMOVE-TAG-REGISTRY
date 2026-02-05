#!/bin/bash

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh

BUILD_REPOSITORY_URL=`getComponentName`
BUILD_REPOSITORY_TAG=`getRepositoryTag`
IMAGE="${BUILD_REPOSITORY_URL}:${BUILD_REPOSITORY_TAG}"
REPOSITORY_NAME="${BUILD_REPOSITORY_URL#*.amazonaws.com/}"
AWS_REGION=$(echo "$BUILD_REPOSITORY_URL" | cut -d'.' -f4)


sleep  $SLEEP_DURATION

if [[ -z "$REPOSITORY_NAME" || -z "$BUILD_REPOSITORY_TAG" ]]; then
  logErrorMessage "Usage $REPOSITORY_NAME $BUILD_REPOSITORY_TAG"
  exit 1
fi

if [ "${ASSUME_ROLE}" == "true" ]; then
    if [ -z "$ACCOUNT_ID" ] || [ -z "$ROLE_NAME" ]; then
          logErrorMessage "Error: ACCOUNT_ID and ROLE_NAME must be set as environment variables when ASSUME_ROLE=true"
          exit 1
    fi
      ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
      getAssumeRole "$ROLE_ARN"
else
    logInfoMessage "ASSUME_ROLE is not set to 'true', skipping role assumption"
fi


if ! command -v aws >/dev/null 2>&1; then
logErrorMessage "AWS CLI is not installed."
  exit 1
fi

logInfoMessage "----------------------------------"
logInfoMessage "Repository : $REPOSITORY_NAME"
logInfoMessage "Tag        : $BUILD_REPOSITORY_TAG"
logInfoMessage "Region     : $AWS_REGION"
logInfoMessage "----------------------------------"


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
        exit 1
    fi
fi

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
  exit 1
fi

logInfoMessage "Tag found. Proceeding with deletion"

if [ -n "$PROFILE" ]; then
    logInfoMessage "AWS PROFILE: $PROFILE"
    logInfoMessage "aws ecr batch-delete-image --repository-name $REPOSITORY_NAME --image-ids imageTag=$BUILD_REPOSITORY_TAG --region $AWS_REGION --profile $PROFILE"
    DELETE_OUTPUT=$(aws ecr batch-delete-image --repository-name "$REPOSITORY_NAME" --image-ids imageTag="$BUILD_REPOSITORY_TAG" --region "$AWS_REGION" --output json --profile $PROFILE)
else
    logInfoMessage "aws ecr batch-delete-image --repository-name $REPOSITORY_NAME --image-ids imageTag=$BUILD_REPOSITORY_TAG --region $AWS_REGION"
    DELETE_OUTPUT=$(aws ecr batch-delete-image --repository-name "$REPOSITORY_NAME" --image-ids imageTag="$BUILD_REPOSITORY_TAG" --region "$AWS_REGION" --output json --profile $PROFILE)
fi

if echo "$DELETE_OUTPUT" | grep -q "failures"; then
  FAIL_COUNT=$(echo "$DELETE_OUTPUT" | jq '.failures | length')
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    logErrorMessage "Failed to delete image tag."
    logErrorMessage "$DELETE_OUTPUT"
    exit 1
  fi
fi

logInfoMessage "SUCCESS: Tag '$BUILD_REPOSITORY_TAG' deleted from '$REPOSITORY_NAME'."
TASK_STATUS=$?
saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
