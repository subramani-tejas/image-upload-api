data "aws_region" "current" {}

# IAM execution role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# S3 & CORS
resource "aws_s3_bucket" "images" {
  bucket = "user-images-local"
}

resource "aws_s3_bucket_cors_configuration" "images_cors" {
  bucket = aws_s3_bucket.images.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag"]
  }
}

# dynamoDB table
resource "aws_dynamodb_table" "metadata" {
  name         = "ImageMetadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
}

# lambda packaging
locals {
  lambdas = toset([
    "generate_upload_url",
    "s3_metadata_processor",
    "list_images",
    "view_image",
    "delete_image"
  ])
}

data "archive_file" "lambda_zip" {
  for_each    = local.lambdas
  type        = "zip"
  source_file = "${path.module}/../${each.key}.py"
  output_path = "${path.module}/.terraform/tmp/${each.key}.zip"
}

# lambda functions
resource "aws_lambda_function" "generate_upload_url" {
  function_name    = "GenerateUploadUrl"
  runtime          = "python3.9"
  handler          = "generate_upload_url.lambda_handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.lambda_zip["generate_upload_url"].output_path
  source_code_hash = data.archive_file.lambda_zip["generate_upload_url"].output_base64sha256
  environment {
    variables = { BUCKET_NAME = aws_s3_bucket.images.id }
  }
}

resource "aws_lambda_function" "s3_metadata_processor" {
  function_name    = "S3MetadataProcessor"
  runtime          = "python3.9"
  handler          = "s3_metadata_processor.lambda_handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.lambda_zip["s3_metadata_processor"].output_path
  source_code_hash = data.archive_file.lambda_zip["s3_metadata_processor"].output_base64sha256
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.metadata.name }
  }
}

resource "aws_lambda_function" "list_images" {
  function_name    = "ListImages"
  runtime          = "python3.9"
  handler          = "list_images.lambda_handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.lambda_zip["list_images"].output_path
  source_code_hash = data.archive_file.lambda_zip["list_images"].output_base64sha256
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.metadata.name }
  }
}

resource "aws_lambda_function" "view_image" {
  function_name    = "ViewImage"
  runtime          = "python3.9"
  handler          = "view_image.lambda_handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.lambda_zip["view_image"].output_path
  source_code_hash = data.archive_file.lambda_zip["view_image"].output_base64sha256
  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.metadata.name
      BUCKET_NAME = aws_s3_bucket.images.id
    }
  }
}

resource "aws_lambda_function" "delete_image" {
  function_name    = "DeleteImage"
  runtime          = "python3.9"
  handler          = "delete_image.lambda_handler"
  role             = aws_iam_role.lambda_exec.arn
  filename         = data.archive_file.lambda_zip["delete_image"].output_path
  source_code_hash = data.archive_file.lambda_zip["delete_image"].output_base64sha256
  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.metadata.name
      BUCKET_NAME = aws_s3_bucket.images.id
    }
  }
}

# S3 event notification
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_metadata_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.images.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.images.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_metadata_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_lambda_permission.s3_invoke]
}

# API-Gateway
resource "aws_api_gateway_rest_api" "api" {
  name = "ImageServiceAPI"
}

# APIs
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_resource" "user_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.users.id
  path_part   = "{user_id}"
}

resource "aws_api_gateway_resource" "images" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.user_id.id
  path_part   = "images"
}

resource "aws_api_gateway_resource" "upload_url" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.images.id
  path_part   = "upload-url"
}

resource "aws_api_gateway_resource" "image_id" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.images.id
  path_part   = "{image_id}"
}

# exploded module logic for direct placement in main.tf
resource "aws_api_gateway_method" "endpoints" {
  for_each      = { for k, v in local.api_endpoints : k => v }
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = each.value.resource_id
  http_method   = each.value.http_method
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "endpoints" {
  for_each                = aws_api_gateway_method.endpoints
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = each.value.resource_id
  http_method             = each.value.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = local.api_endpoints[each.key].lambda_arn_invoke
}

resource "aws_lambda_permission" "apigw" {
  for_each      = { for k, v in local.api_endpoints : k => v }
  statement_id  = "AllowAPIGatewayInvoke_${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

locals {
  api_endpoints = {
    upload_url = { resource_id = aws_api_gateway_resource.upload_url.id, http_method = "POST", lambda_arn_invoke = aws_lambda_function.generate_upload_url.invoke_arn, lambda_name = aws_lambda_function.generate_upload_url.function_name }
    list       = { resource_id = aws_api_gateway_resource.images.id, http_method = "GET", lambda_arn_invoke = aws_lambda_function.list_images.invoke_arn, lambda_name = aws_lambda_function.list_images.function_name }
    view       = { resource_id = aws_api_gateway_resource.image_id.id, http_method = "GET", lambda_arn_invoke = aws_lambda_function.view_image.invoke_arn, lambda_name = aws_lambda_function.view_image.function_name }
    delete     = { resource_id = aws_api_gateway_resource.image_id.id, http_method = "DELETE", lambda_arn_invoke = aws_lambda_function.delete_image.invoke_arn, lambda_name = aws_lambda_function.delete_image.function_name }
  }
}

# API deployment & stage
resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  depends_on  = [aws_api_gateway_integration.endpoints]
}

resource "aws_api_gateway_stage" "local" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "local"
}

output "upload_url" {
  value = "http://localhost:4566/restapis/${aws_api_gateway_rest_api.api.id}/local/_user_request_/users/usr_9981/images/upload-url"
}