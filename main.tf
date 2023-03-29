terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-1"
}

# Variables

# SES Email Variable
variable "user_email" {
  description = "Email address to be used for reminder"
  type = string

  default = "pgg6@njit.edu"

  validation {
    condition     = can(regex("@", var.user_email))
    error_message = "Email address must contain an @ symbol"
  }
}

# This will initialize a variable that contains a list of the Web files needed
variable "S3_files_to_upload" {
  type = list(string)
  default = [
    "serverless_frontend/index.html",
    "serverless_frontend/main.css",
    "serverless_frontend/serverless.js",
    "serverless_frontend/whiskers.png"
  ]
}

# Locals values are useful in situations where variables repeat multiple times. 
locals {
    # Common Tags to be assigned
    common_tags = {
        Terraform   = "True"
        Environment = "Dev"
    }
}

### IAM Roles for Lambda & State Machine ###

resource "aws_iam_role" "lambda_role" {
  name = "Lambda_Serverless_Reminder_App_Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  path = "/"

  tags = {
    Environment = "Production"
  }

  inline_policy {
    name = "cloudwatchlogs"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = "arn:aws:logs:*:*:*"
        }
      ]
    })
  }

  inline_policy {
    name = "snsandsespermissions"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "ses:*",
            "sns:*",
            "states:*"
          ]
          Resource = "*"
        }
      ]
    })
  }
}

resource "aws_iam_role" "state_machine_role" {
  name = "StateMachine_Serverless_Reminder_App_Role"
  assume_role_policy = jsonencode({
    Statement = [{
      Action = ["sts:AssumeRole"]
      Effect = "Allow"
      Principal = {
        Service = ["states.amazonaws.com"]
      }
    }]
    Version = "2012-10-17"
  })

  path = "/"

  # CloudWatch Logs Policy
  inline_policy {
    name = "cloudwatchlogs"
    policy = jsonencode({
      Version = "2012-10-17",
      Statement = [{
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      }]
    })
  }

  # Invoke Lambda and Send SNS Policy
  inline_policy {
    name = "invokelambdasandsendSNS"
    policy = jsonencode({
      Version = "2012-10-17",
      Statement = [{
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "sns:*"
        ]
        Resource = "*"
      }]
    })
  }
}


### SES Setup ###

resource "aws_ses_email_identity" "SES-Setup" {
  email = var.user_email
}

### Lambda ###

# Lambda - Create Email Reminder

data "archive_file" "Lambda-Zip-Email-Reminder" {
  type = "zip"
  source_dir  = "${path.module}/Email_Script/"
  output_path = "${path.module}/Email_Script/lambda_email_reminder.zip"
}

resource "aws_lambda_function" "Lambda-Email-Reminder" {
  filename      = "${path.module}/Email_Script/lambda_email_reminder.zip"
  function_name = "lambda_email_reminder"
  role = aws_iam_role.lambda_role.arn
  handler       = "index.test"

  source_code_hash = data.archive_file.Lambda-Zip-Email-Reminder.output_base64sha256

  runtime = "python3.9"

  environment {
    variables = {
        FROM_EMAIL_ADDRESS = "${var.user_email}"
    }
  }

  depends_on = [
    data.archive_file.Lambda-Zip-Email-Reminder
  ]
  tags = local.common_tags
}

# Lambda - API 
data "archive_file" "Lambda-Zip-API" {
  type = "zip"
  source_dir  = "${path.module}/API_Script/"
  output_path = "${path.module}/API_Script/lambda_api.zip"
}

resource "aws_lambda_function" "Lambda-API" {
  
  filename      = "${path.module}/API_Script/lambda_api.zip"
  function_name = "api_lambda"
  role          = aws_iam_role.lambda_role.arn
  handler       = "index.test"

  source_code_hash = data.archive_file.Lambda-Zip-Email-Reminder.output_base64sha256

  runtime = "python3.9"

  environment {
    variables = {
        SM_ARN = aws_sfn_state_machine.sfn_state_machine.arn
    }
  }
  depends_on = [
    data.archive_file.Lambda-Zip-API
  ]
  tags = local.common_tags
}

resource "aws_lambda_permission" "allow_apigw_invoke_lambda" {
  statement_id  = "AllowAPIGatewayInvokeLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.Lambda-API.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = aws_api_gateway_deployment.petcuddleotron_deployment.execution_arn
}

### State Machine ### 

# Create a CW Log Group for Logs

resource "aws_cloudwatch_log_group" "Pet-CuddleOTron-Log-Group" {
  name = "PetCuddleOTron-Logs"

  tags = local.common_tags
}

# State Machine - Create 
resource "aws_sfn_state_machine" "sfn_state_machine" {
  name     = "PetCuddleOtron"

  role_arn = aws_iam_role.state_machine_role.arn
  logging_configuration {
    #log_destination = aws_cloudwatch_log_group.Pet-CuddleOTron-Log-Group.arn
    log_destination = "arn:aws:logs:*:*:log-group:${aws_cloudwatch_log_group.Pet-CuddleOTron-Log-Group.name}:*"
    include_execution_data = true
    level = "ALL"
  }

  definition = <<EOF
{
  "Comment": "Pet Cuddle-o-Tron - using Lambda for email.",
  "StartAt": "Timer",
  "States": {
    "Timer": {
      "Type": "Wait",
      "SecondsPath": "$.waitSeconds",
      "Next": "Email"
    },
    "Email": {
      "Type" : "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${aws_lambda_function.Lambda-Email-Reminder.arn}",
        "Payload": {
          "Input.$": "$"
        }
      },
      "Next": "NextState"
    },
    "NextState": {
      "Type": "Pass",
      "End": true
    }
  }
}
EOF
}

### API GW ###

# Create API GW
resource "aws_api_gateway_rest_api" "Reminder_App_API" {
  name = "petcuddleotron"
  description = "API for Serverless Reminder App Pet-Cuddle-O-Tron"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = local.common_tags
}

resource "aws_api_gateway_resource" "Reminder_App_Resource" {
  rest_api_id = aws_api_gateway_rest_api.Reminder_App_API.id
  parent_id   = aws_api_gateway_rest_api.Reminder_App_API.root_resource_id
  path_part   = "petcuddleotron"
}
# API - POST Method
resource "aws_api_gateway_method" "Reminder_App_method_post" {
  rest_api_id   = aws_api_gateway_rest_api.Reminder_App_API.id
  resource_id   = aws_api_gateway_resource.Reminder_App_Resource.id
  http_method   = "POST"
  authorization = "NONE"
}
# API - Options Method
resource "aws_api_gateway_method" "options" {
  rest_api_id   = aws_api_gateway_rest_api.Reminder_App_API.id
  resource_id   = aws_api_gateway_resource.Reminder_App_Resource.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

# API - Response 
resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.Reminder_App_API.id
  resource_id = aws_api_gateway_resource.Reminder_App_Resource.id
  http_method = aws_api_gateway_method.Reminder_App_method_post.http_method
  status_code = "200"
}

resource "aws_api_gateway_method_response" "options" {
  rest_api_id = aws_api_gateway_rest_api.Reminder_App_API.id
  resource_id = aws_api_gateway_resource.Reminder_App_Resource.id
  http_method = aws_api_gateway_method.options.http_method
  status_code = "200"

  response_models = {
    "application/json" = "Empty"
  }
}

# API - Integration
resource "aws_api_gateway_integration" "Reminder_App_post" {
  rest_api_id = aws_api_gateway_rest_api.Reminder_App_API.id
  resource_id = aws_api_gateway_resource.Reminder_App_Resource.id
  http_method = aws_api_gateway_method.Reminder_App_method_post.http_method
  integration_http_method = "POST"
  type        = "AWS_PROXY"
  uri         = aws_lambda_function.Lambda-API.invoke_arn
}

# resource "aws_api_gateway_integration_response" "options" {
#   rest_api_id = aws_api_gateway_rest_api.Reminder_App_API.id
#   resource_id = aws_api_gateway_resource.Reminder_App_Resource.id
#   http_method = aws_api_gateway_method.Reminder_App_method_post.http_method
#   status_code = "200"

# response_parameters = {
#   "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
#   "method.response.header.Access-Control-Allow-Methods" = "method.response.header.Access-Control-Allow-Methods"
#   "method.response.header.Access-Control-Allow-Methods" = "'GET, POST, OPTIONS'"
#   "method.response.header.Access-Control-Allow-Methods" = "GET, POST, OPTIONS"
#   "method.response.header.Access-Control-Allow-Origin"  = "'*'"
# }

# }


# API - Deployment 
resource "aws_api_gateway_deployment" "petcuddleotron_deployment" {
    rest_api_id = aws_api_gateway_rest_api.Reminder_App_API.id
    stage_name  = "prod"

    depends_on  = [
    aws_api_gateway_rest_api.Reminder_App_API,
    aws_api_gateway_method.Reminder_App_method_post,
    aws_api_gateway_integration.Reminder_App_post
  ]

}


### S3 ###

# S3 - Create 
resource "random_pet" "bucket_name" {
  length    = 3
  separator = "-"
}

resource "aws_s3_bucket" "reminder-app-bucket" {
    bucket = "${random_pet.bucket_name.id}-app-bucket"
    tags = local.common_tags
}

# S3 - Website Config
resource "aws_s3_bucket_website_configuration" "reminder-app-web-config" {
  bucket = aws_s3_bucket.reminder-app-bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# S3 - Bucket Policy
resource "aws_s3_bucket_policy" "reminder-app-allow-read-policy" {
  bucket = aws_s3_bucket.reminder-app-bucket.id
  policy = <<EOF
    {
    "Version":"2012-10-17",
    "Statement":[
      {
        "Sid":"PublicRead",
        "Effect":"Allow",
        "Principal": "*",
        "Action":["s3:GetObject"],
        "Resource":["${aws_s3_bucket.reminder-app-bucket.arn}/*"]
      }
    ]
  }
  EOF
}


locals {
  S3_files_to_upload = {
    "main.css" = { path = "${path.module}/serverless_frontend/main.css", content_type = "text/css" },
    "index.html" = { path = "${path.module}/serverless_frontend/index.html", content_type = "text/html" },
    "serverless.js" = { path = "${path.module}/serverless_frontend/serverless.js", content_type = "application/javascript" },
    "whiskers.png" = { path = "${path.module}/serverless_frontend/whiskers.png", content_type = "image/png" }
  }
}

# S3 - Upload Files
resource "aws_s3_object" "files" {
    bucket = aws_s3_bucket.reminder-app-bucket.id
    for_each = local.S3_files_to_upload
    # for_each = toset(var.S3_files_to_upload)
    # key    = "${basename(each.value)}"
    # source = each.value
    key = each.key
    source = lookup(local.S3_files_to_upload, each.key).path
    content_type = lookup(local.S3_files_to_upload, each.key).content_type

    depends_on = [local_file.updated_python_file, local_file.updated_js_file]
}


### Update Variables in Javascript & Python ###

data "local_file" "js_file" {
  filename = "${path.module}/serverless_frontend/serverless.js"
}

# Replace API_ENDPOINT variable in JS file
resource "local_file" "updated_js_file" {
  filename = "${path.module}/serverless_frontend/serverless.js"
  content  = replace(data.local_file.js_file.content, "var API_ENDPOINT = 'REPLACEME_API_GATEWAY_INVOKE_URL';", "var API_ENDPOINT = 'https://${aws_api_gateway_rest_api.Reminder_App_API.id}.execute-api.us-east-1.amazonaws.com/prod/petcuddleotron';")

# aws_api_gateway_rest_api.Reminder_App_API.api_endpoint
}



# Define data source for Python file
data "local_file" "python_file" {
  filename = "${path.module}/API_Script/API_lambda.py"
}

# Replace SM_ARN variable in Python file
resource "local_file" "updated_python_file" {
  filename = "${path.module}/API_Script/API_lambda.py"
  content  = replace(data.local_file.python_file.content, "SM_ARN = 'YOUR_STATEMACHINE_ARN'", "SM_ARN = '${aws_sfn_state_machine.sfn_state_machine.arn}'")
}

### Outputs ### 

output "email_prompt" {
    value = "Please check your email and verify via the link. It will be sent by 'no-reply-aws@amazon.com' to ${var.user_email} "
}

output "S3_Endpoint"{
    value = aws_s3_bucket_website_configuration.reminder-app-web-config.website_endpoint
}

output "State_Machine_ARN" {
    value = aws_sfn_state_machine.sfn_state_machine.arn
}

output "Bucket_ARN" {
    value = aws_s3_bucket.reminder-app-bucket.arn
}
