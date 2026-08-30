#!/bin/bash
set -e

BUCKET_NAME="user-images-local"
TABLE_NAME="ImageMetadata"
REGION="us-east-1"
STAGE="local"

if awslocal s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    echo "Bucket $BUCKET_NAME already exists."
else
    echo "===== Creating S3 Bucket =====tjs"
    awslocal s3 mb "s3://$BUCKET_NAME" --region "$REGION"
fi

if awslocal dynamodb describe-table --table-name "$TABLE_NAME" 2>/dev/null; then
    echo "Table $TABLE_NAME already exists."
else
    echo "===== Creating DynamoDB Table =====tjs"
    awslocal dynamodb create-table \
        --table-name "$TABLE_NAME" \
        --attribute-definitions \
            AttributeName=PK,AttributeType=S \
            AttributeName=SK,AttributeType=S \
        --key-schema \
            AttributeName=PK,KeyType=HASH \
            AttributeName=SK,KeyType=RANGE \
        --billing-mode PAY_PER_REQUEST \
        --region "$REGION"
fi

echo "===== Zipping & Deploying Lambdas =====tjs"
cd /tmp/src
zip -q -r /tmp/generate_upload_url.zip generate_upload_url.py
zip -q -r /tmp/s3_metadata_processor.zip s3_metadata_processor.py

awslocal lambda create-function \
    --function-name GenerateUploadUrl \
    --runtime python3.9 \
    --handler generate_upload_url.lambda_handler \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --zip-file fileb:///tmp/generate_upload_url.zip \
    --environment "Variables={BUCKET_NAME=$BUCKET_NAME}" \
    --region "$REGION" 2>/dev/null || awslocal lambda update-function-code --function-name GenerateUploadUrl --zip-file fileb:///tmp/generate_upload_url.zip

awslocal lambda create-function \
    --function-name S3MetadataProcessor \
    --runtime python3.9 \
    --handler s3_metadata_processor.lambda_handler \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --zip-file fileb:///tmp/s3_metadata_processor.zip \
    --environment "Variables={TABLE_NAME=$TABLE_NAME}" \
    --region "$REGION" 2>/dev/null || awslocal lambda update-function-code --function-name S3MetadataProcessor --zip-file fileb:///tmp/s3_metadata_processor.zip

zip -q -r /tmp/list_images.zip list_images.py

awslocal lambda create-function \
    --function-name ListImages \
    --runtime python3.9 \
    --handler list_images.lambda_handler \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --zip-file fileb:///tmp/list_images.zip \
    --environment "Variables={TABLE_NAME=$TABLE_NAME}" \
    --region "$REGION" 2>/dev/null || awslocal lambda update-function-code --function-name ListImages --zip-file fileb:///tmp/list_images.zip

zip -q -r /tmp/view_image.zip view_image.py

awslocal lambda create-function \
    --function-name ViewImage \
    --runtime python3.9 \
    --handler view_image.lambda_handler \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --zip-file fileb:///tmp/view_image.zip \
    --environment "Variables={TABLE_NAME=$TABLE_NAME, BUCKET_NAME=$BUCKET_NAME}" \
    --region "$REGION" 2>/dev/null || awslocal lambda update-function-code --function-name ViewImage --zip-file fileb:///tmp/view_image.zip

zip -q -r /tmp/delete_image.zip delete_image.py

awslocal lambda create-function \
    --function-name DeleteImage \
    --runtime python3.9 \
    --handler delete_image.lambda_handler \
    --role arn:aws:iam::000000000000:role/lambda-role \
    --zip-file fileb:///tmp/delete_image.zip \
    --environment "Variables={TABLE_NAME=$TABLE_NAME, BUCKET_NAME=$BUCKET_NAME}" \
    --region "$REGION" 2>/dev/null || awslocal lambda update-function-code --function-name DeleteImage --zip-file fileb:///tmp/delete_image.zip

echo "===== Setting up S3 Event Notification =====tjs"
PROCESSOR_LAMBDA_ARN=$(awslocal lambda get-function --function-name S3MetadataProcessor --query 'Configuration.FunctionArn' --output text)

awslocal lambda wait function-active-v2 --function-name S3MetadataProcessor

awslocal lambda add-permission \
    --function-name S3MetadataProcessor \
    --statement-id s3invoke \
    --action "lambda:InvokeFunction" \
    --principal s3.amazonaws.com \
    --source-arn "arn:aws:s3:::$BUCKET_NAME" 2>/dev/null || true

awslocal s3api put-bucket-notification-configuration \
    --bucket "$BUCKET_NAME" \
    --notification-configuration '{
        "LambdaFunctionConfigurations": [
            {
                "LambdaFunctionArn": "'"$PROCESSOR_LAMBDA_ARN"'",
                "Events": ["s3:ObjectCreated:*"]
            }
        ]
    }'

echo "===== Setting up API Gateway =====tjs"
API_ID=$(awslocal apigateway create-rest-api --name "ImageServiceAPI" --query 'id' --output text)
PARENT_ID=$(awslocal apigateway get-resources --rest-api-id "$API_ID" --query 'items[?path==`/`].id' --output text)

# /users
USERS_RES_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$PARENT_ID" --path-part "users" --query 'id' --output text)

# /users/{user_id}
USER_ID_RES_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$USERS_RES_ID" --path-part "{user_id}" --query 'id' --output text)

# /users/{user_id}/images
IMAGES_RES_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$USER_ID_RES_ID" --path-part "images" --query 'id' --output text)

# /users/{user_id}/images/upload-url
UPLOAD_URL_RES_ID=$(awslocal apigateway create-resource --rest-api-id "$API_ID" --parent-id "$IMAGES_RES_ID" --path-part "upload-url" --query 'id' --output text)

# POST on /users/{user_id}/images/upload-url
awslocal apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$UPLOAD_URL_RES_ID" \
    --http-method POST \
    --authorization-type NONE

# integrate with GenerateUploadUrl
LAMBDA_ARN=$(awslocal lambda get-function --function-name GenerateUploadUrl --query 'Configuration.FunctionArn' --output text)
awslocal apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$UPLOAD_URL_RES_ID" \
    --http-method POST \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LAMBDA_ARN/invocations"

# GET on /users/{user_id}/images
awslocal apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$IMAGES_RES_ID" \
    --http-method GET \
    --authorization-type NONE

# integrate with ListImages
LIST_LAMBDA_ARN=$(awslocal lambda get-function --function-name ListImages --query 'Configuration.FunctionArn' --output text)

awslocal apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$IMAGES_RES_ID" \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$LIST_LAMBDA_ARN/invocations"

# /users/{user_id}/images/{image_id}
IMAGE_ID_RES_ID=$(awslocal apigateway create-resource \
    --rest-api-id "$API_ID" \
    --parent-id "$IMAGES_RES_ID" \
    --path-part "{image_id}" \
    --query 'id' --output text)

# GET on /users/{user_id}/images/{image_id}
awslocal apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$IMAGE_ID_RES_ID" \
    --http-method GET \
    --authorization-type NONE

VIEW_LAMBDA_ARN=$(awslocal lambda get-function --function-name ViewImage --query 'Configuration.FunctionArn' --output text)

awslocal apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$IMAGE_ID_RES_ID" \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$VIEW_LAMBDA_ARN/invocations"

# DELETE on /users/{user_id}/images/{image_id}
awslocal apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$IMAGE_ID_RES_ID" \
    --http-method DELETE \
    --authorization-type NONE

DELETE_LAMBDA_ARN=$(awslocal lambda get-function --function-name DeleteImage --query 'Configuration.FunctionArn' --output text)

awslocal apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$IMAGE_ID_RES_ID" \
    --http-method DELETE \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$DELETE_LAMBDA_ARN/invocations"

awslocal apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$STAGE"

echo "===================================================="
echo "API ready"
echo "$API_ID"
echo "http://localhost:4566/restapis/$API_ID/$STAGE/_user_request_/users/{user_id}/images/upload-url"
echo "===================================================="