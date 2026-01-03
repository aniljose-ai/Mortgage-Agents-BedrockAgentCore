################################################################################
# ECR Repository
################################################################################
resource "aws_ecr_repository" "agentcore_terraform_runtime" {
  name                 = "bedrock-agentcore/${lower(var.app_name)}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

data "aws_ecr_authorization_token" "token" {}

################################################################################
# S3 Bucket for CodeBuild Source
################################################################################
resource "aws_s3_bucket" "agent_source" {
  bucket_prefix = "${lower(var.app_name)}-agent-source-"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "agent_source" {
  bucket = aws_s3_bucket.agent_source.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Archive the source code
data "archive_file" "agent_source" {
  type        = "zip"
  source_dir  = "../${path.root}"
  output_path = "${path.module}/.terraform/agent_source.zip"
  excludes = [
    ".git/**",
    ".terraform/**",
    "terraform/**",
    "*.zip",
    "**/__pycache__/**",
    "**/.pytest_cache/**",
    "**/.venv/**",
    "**/venv/**"
  ]
}

# Upload source to S3
resource "aws_s3_object" "agent_source" {
  bucket = aws_s3_bucket.agent_source.id
  key    = "agent_source_${data.archive_file.agent_source.output_md5}.zip"
  source = data.archive_file.agent_source.output_path
  etag   = data.archive_file.agent_source.output_md5
}

################################################################################
# CodeBuild IAM Role
################################################################################
resource "aws_iam_role" "image_build" {
  name = "${var.app_name}-ImageBuildRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "image_build_policy" {
  role = aws_iam_role.image_build.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.app_name}-*"
        ]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = [
          "${aws_s3_bucket.agent_source.arn}/*"
        ]
      },
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      }
    ]
  })
}

################################################################################
# CodeBuild Project
################################################################################
resource "aws_codebuild_project" "agent_image" {
  name          = "${var.app_name}-agent-build"
  description   = "Build agent Docker image for ${var.app_name}"
  service_role  = aws_iam_role.image_build.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_LARGE"
    image           = "aws/codebuild/amazonlinux2-aarch64-standard:3.0"
    type            = "ARM_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = data.aws_region.current.region
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.agentcore_terraform_runtime.name
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.agent_source.id}/${aws_s3_object.agent_source.key}"
    buildspec = file("${path.module}/../buildspec.yml")
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/${var.app_name}-agent-build"
    }
  }
}

################################################################################
# Trigger CodeBuild on Source Changes
################################################################################
resource "null_resource" "trigger_build" {
  depends_on = [
    aws_codebuild_project.agent_image,
    aws_s3_object.agent_source
  ]

  triggers = {
    source_code_md5 = data.archive_file.agent_source.output_md5
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/build-image.sh ${aws_codebuild_project.agent_image.name} ${data.aws_region.current.region}"
  }
}

################################################################################
# MCP Lambda Function
################################################################################

# Install dependencies into a temporary directory
resource "null_resource" "lambda_dependencies" {
  triggers = {
    requirements = filesha256("../${path.root}/mcp/lambda/requirements.txt")
    lambda_code  = filesha256("../${path.root}/mcp/lambda/lambda_function.py")
  }

  provisioner "local-exec" {
    command = <<EOF
      rm -rf ../${path.root}/.lambda_build
      mkdir -p ../${path.root}/.lambda_build
      cp ../${path.root}/mcp/lambda/lambda_function.py ../${path.root}/.lambda_build/
      pip install -r ../${path.root}/mcp/lambda/requirements.txt -t ../${path.root}/.lambda_build/ --upgrade
    EOF
  }
}

data "archive_file" "mcp_lambda_zip" {
  type        = "zip"
  source_dir  = "../${path.root}/.lambda_build"
  output_path = "../${path.root}/mcp_lambda.zip"

  depends_on = [null_resource.lambda_dependencies]
}

resource "aws_lambda_function" "mcp_lambda" {
  function_name = "${var.app_name}-McpLambda"
  role          = aws_iam_role.mcp_lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  filename         = data.archive_file.mcp_lambda_zip.output_path
  source_code_hash = data.archive_file.mcp_lambda_zip.output_base64sha256
}

resource "aws_iam_role" "mcp_lambda_role" {
  name = "${var.app_name}-McpLambdaRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mcp_lambda_basic" {
  role       = aws_iam_role.mcp_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

################################################################################
# AgentCore Gateway Roles
################################################################################

resource "aws_iam_role" "agentcore_gateway_role" {
  name               = "${var.app_name}-AgentCoreGatewayRole"
  assume_role_policy = data.aws_iam_policy_document.bedrock_agentcore_assume_role.json
}

resource "aws_iam_role_policy_attachment" "agentcore_gateway_permissions" {
  role       = aws_iam_role.agentcore_gateway_role.name
  policy_arn = "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess"
}

resource "aws_iam_role_policy" "agentcore_gateway_lambda_invoke" {
  role = aws_iam_role.agentcore_gateway_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["lambda:InvokeFunction"]
      Effect   = "Allow"
      Resource = [aws_lambda_function.mcp_lambda.arn]
    }]
  })
}

################################################################################
# AgentCore Gateway Inbound Auth - Cognito
################################################################################

resource "aws_cognito_user_pool" "cognito_user_pool" {
  name = "${var.app_name}-CognitoUserPool"
}

resource "aws_cognito_resource_server" "cognito_resource_server" {
  identifier   = "${var.app_name}-CognitoResourceServer"
  name         = "${var.app_name}-CognitoResourceServer"
  user_pool_id = aws_cognito_user_pool.cognito_user_pool.id
  scope {
    scope_description = "Basic access to ${var.app_name}"
    scope_name        = "basic"
  }
}

resource "aws_cognito_user_pool_client" "cognito_app_client" {
  name                                 = "${var.app_name}-CognitoUserPoolClient"
  user_pool_id                         = aws_cognito_user_pool.cognito_user_pool.id
  generate_secret                      = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["${aws_cognito_resource_server.cognito_resource_server.identifier}/basic"]
  supported_identity_providers         = ["COGNITO"]
}

resource "aws_cognito_user_pool_domain" "cognito_domain" {
  domain       = "${lower(var.app_name)}-${data.aws_region.current.region}"
  user_pool_id = aws_cognito_user_pool.cognito_user_pool.id
}

locals {
  cognito_discovery_url = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.cognito_user_pool.id}/.well-known/openid-configuration"
}

################################################################################
# AgentCore Gateway
################################################################################

resource "aws_bedrockagentcore_gateway" "agentcore_gateway" {
  name            = "${var.app_name}-Gateway"
  protocol_type   = "MCP"
  role_arn        = aws_iam_role.agentcore_gateway_role.arn
  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = local.cognito_discovery_url
      allowed_clients = [aws_cognito_user_pool_client.cognito_app_client.id]
    }
  }
}

################################################################################
# Gateway Target 1: GDS/TDS Calculator
################################################################################
resource "aws_bedrockagentcore_gateway_target" "calculate_gds_tds_target" {
  name               = "${var.app_name}-GDS-TDS-Target"
  gateway_identifier = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.mcp_lambda.arn

        tool_schema {
          inline_payload {
            name        = "calculate_gds_tds"
            description = "Calculate Gross Debt Service (GDS) and Total Debt Service (TDS) ratios per CMHC guidelines for Canadian mortgage qualification. GDS limit is 39%, TDS limit is 44%."
            input_schema {
              type        = "object"
              description = "Applicant financial information"
              property {
                name        = "gross_annual_income"
                type        = "number"
                description = "Applicant's gross annual income in CAD"
                required    = true
              }
              property {
                name        = "monthly_mortgage_payment"
                type        = "number"
                description = "Monthly mortgage payment (principal + interest)"
                required    = true
              }
              property {
                name        = "monthly_property_taxes"
                type        = "number"
                description = "Monthly property taxes"
                required    = true
              }
              property {
                name        = "monthly_heating"
                type        = "number"
                description = "Monthly heating costs"
                required    = true
              }
              property {
                name        = "monthly_condo_fees"
                type        = "number"
                description = "Monthly condo fees (if applicable)"
                required    = false
              }
              property {
                name        = "monthly_other_debts"
                type        = "number"
                description = "Monthly other debt payments (car loans, credit cards, etc.)"
                required    = false
              }
            }
          }
        }
      }
    }
  }
}

################################################################################
# Gateway Target 2: OSFI B-20 Stress Test
################################################################################
resource "aws_bedrockagentcore_gateway_target" "osfi_b20_stress_test_target" {
  name               = "${var.app_name}-OSFI-B20-Target"
  gateway_identifier = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.mcp_lambda.arn

        tool_schema {
          inline_payload {
            name        = "osfi_b20_stress_test"
            description = "Apply OSFI B-20 stress test to mortgage qualification. Borrower must qualify at the higher of contract rate + 2% or 5.25% minimum qualifying rate."
            input_schema {
              type        = "object"
              description = "Mortgage details for stress test"
              property {
                name        = "purchase_price"
                type        = "number"
                description = "Property purchase price in CAD"
                required    = true
              }
              property {
                name        = "down_payment"
                type        = "number"
                description = "Down payment amount in CAD"
                required    = true
              }
              property {
                name        = "contract_interest_rate"
                type        = "number"
                description = "Contract interest rate as percentage (e.g., 3.5 for 3.5%)"
                required    = true
              }
              property {
                name        = "amortization_years"
                type        = "number"
                description = "Amortization period in years (typically 25)"
                required    = false
              }
            }
          }
        }
      }
    }
  }
}

################################################################################
# Gateway Target 3: Down Payment Calculator
################################################################################
resource "aws_bedrockagentcore_gateway_target" "calculate_down_payment_target" {
  name               = "${var.app_name}-Down-Payment-Target"
  gateway_identifier = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.mcp_lambda.arn

        tool_schema {
          inline_payload {
            name        = "calculate_down_payment"
            description = "Calculate minimum down payment and CMHC insurance requirements per Canadian rules. Properties under $500K require 5% down, $500K-$1M require 5% on first $500K + 10% on remainder, over $1M require 20% down."
            input_schema {
              type        = "object"
              description = "Property and down payment details"
              property {
                name        = "purchase_price"
                type        = "number"
                description = "Property purchase price in CAD"
                required    = true
              }
              property {
                name        = "proposed_down_payment"
                type        = "number"
                description = "Proposed down payment amount in CAD"
                required    = true
              }
            }
          }
        }
      }
    }
  }
}

################################################################################
# Gateway Target 4: Credit Score Check
################################################################################
resource "aws_bedrockagentcore_gateway_target" "check_credit_threshold_target" {
  name               = "${var.app_name}-Credit-Check-Target"
  gateway_identifier = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.mcp_lambda.arn

        tool_schema {
          inline_payload {
            name        = "check_credit_threshold"
            description = "Check if credit score meets CMHC minimum requirements. CMHC insured mortgages require 600+ credit score, conventional mortgages require 650+."
            input_schema {
              type        = "object"
              description = "Credit score and mortgage type"
              property {
                name        = "credit_score"
                type        = "number"
                description = "Applicant's credit score (300-900 range)"
                required    = true
              }
              property {
                name        = "down_payment_percentage"
                type        = "number"
                description = "Down payment as percentage of purchase price"
                required    = true
              }
            }
          }
        }
      }
    }
  }
}

################################################################################
# AgentCore Runtime IAM Roles
################################################################################

data "aws_iam_policy_document" "bedrock_agentcore_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agentcore_runtime_execution_role" {
  name        = "${var.app_name}-AgentCoreRuntimeRole"
  description = "Execution role for Bedrock AgentCore Runtime"

  assume_role_policy = data.aws_iam_policy_document.bedrock_agentcore_assume_role.json
}

# https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html#runtime-permissions-execution
resource "aws_iam_role_policy" "agentcore_runtime_execution_role_policy" {
  role = aws_iam_role.agentcore_runtime_execution_role.id
  name = "${var.app_name}-AgentCoreRuntimeExecutionPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRImageAccess"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [
          "arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:CreateLogGroup",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
        ]
      },
      {
        Sid    = "ECRTokenAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
        ]
        Resource = [
          "*",
        ]
      },
      {
        Effect   = "Allow"
        Resource = "*"
        Action   = "cloudwatch:PutMetricData"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "bedrock-agentcore"
          }
        }
      },
      {
        Sid    = "GetAgentAccessToken"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:GetWorkloadAccessToken",
          "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
          "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default",
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:workload-identity-directory/default/workload-identity/agentName-*",
        ]
      },
      {
        Sid    = "BedrockModelInvocation"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*",
        ]
      },
      {
        Sid    = "MemoryOperations"
        Effect = "Allow"
        Action = [
          "bedrock-agentcore:ListEvents",
          "bedrock-agentcore:CreateEvent",
          "bedrock-agentcore:AddEvent",
          "bedrock-agentcore:GetEvent",
          "bedrock-agentcore:DeleteEvent",
          "bedrock-agentcore:ListMemories",
          "bedrock-agentcore:GetMemory",
        ]
        Resource = [
          "arn:aws:bedrock-agentcore:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:memory/*",
        ]
      },
    ]
  })
}


################################################################################
# AgentCore Memory
################################################################################
resource "aws_bedrockagentcore_memory" "agentcore_memory" {
  name                  = "mortgageAgents_Memory"
  description           = "Memory resource with 30 days event expiry"
  event_expiry_duration = 30
}
# Add a built-in strategy from https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/built-in-strategies.html or define a custom one
# Example of adding semantic memory
# resource "aws_bedrockagentcore_memory_strategy" "semantic" {
#  name        = "semantic-strategy"
#  memory_id   = aws_bedrockagentcore_memory.agentcore_memory.id
#  type        = "SEMANTIC"
#  description = "Semantic understanding strategy"
#  namespaces  = ["default"]
# }

################################################################################
# AgentCore Runtime
################################################################################
resource "aws_bedrockagentcore_agent_runtime" "agentcore_runtime" {
  agent_runtime_name = "mortgageAgents_Agent"
  role_arn           = aws_iam_role.agentcore_runtime_execution_role.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agentcore_terraform_runtime.repository_url}:latest"
    }
  }

  depends_on = [null_resource.trigger_build, aws_bedrockagentcore_memory.agentcore_memory]

  network_configuration {
    network_mode = "PUBLIC"
  }
  environment_variables = {
    AWS_REGION                  = data.aws_region.current.region
    BEDROCK_AGENTCORE_MEMORY_ID = aws_bedrockagentcore_memory.agentcore_memory.id
    GATEWAY_URL                 = aws_bedrockagentcore_gateway.agentcore_gateway.gateway_url
    COGNITO_CLIENT_ID           = aws_cognito_user_pool_client.cognito_app_client.id
    COGNITO_CLIENT_SECRET       = aws_cognito_user_pool_client.cognito_app_client.client_secret
    COGNITO_TOKEN_URL           = "https://${aws_cognito_user_pool_domain.cognito_domain.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/token"
    COGNITO_SCOPE               = "${aws_cognito_resource_server.cognito_resource_server.identifier}/basic"
    DEMO_MODE                   = "1" # Set to "0" for production streaming. "1" to disable streaming for demos/screenshots
  }

}


################################################################################
# AgentCore Runtime Endpoints
################################################################################
resource "aws_bedrockagentcore_agent_runtime_endpoint" "dev_endpoint" {
  name                  = "DEV"
  agent_runtime_id      = aws_bedrockagentcore_agent_runtime.agentcore_runtime.agent_runtime_id
  agent_runtime_version = var.agent_runtime_version
}

