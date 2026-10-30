# Agenda parser: one Lambda outside the VPC behind a function URL, plus a $5 budget alarm
# (was ai.yml, Lab 6). It never writes anything; it only suggests.

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/${var.project_name}/ai-parser"
  retention_in_days = 14
}

# Not in the VPC: it needs the internet (Bedrock, Cognito's keys) and never touches Aurora.
# Generated role name, left out on purpose (see the note in reports.tf).
resource "aws_iam_role" "parser" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "parser_logs" {
  role       = aws_iam_role.parser.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "parser" {
  name = "call-claude"
  role = aws_iam_role.parser.id

  # "*" for now; narrowing it to one model is a discussion question (Lab 6).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "bedrock-mantle:CreateInference", Resource = "*" },
      { Effect = "Allow", Action = "bedrock:InvokeModel", Resource = "*" },
    ]
  })
}

resource "aws_lambda_function" "parser" {
  function_name = "${var.project_name}-ai-parser"
  package_type  = "Image"
  image_uri     = local.backend["ImageUri"]
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 30
  role          = aws_iam_role.parser.arn

  # Same image as the API; only the command differs. No migrations, no database.
  image_config {
    command = ["uvicorn", "app.ai.agenda_lambda:app", "--host", "0.0.0.0", "--port", "8000"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.parser.name
  }

  environment {
    variables = {
      PARSER_MODEL                 = var.parser_model
      PARSER_EFFORT                = var.parser_effort
      PARSER_API                   = var.parser_api
      BEDROCK_REGION               = var.bedrock_region
      COGNITO_USER_POOL_ID         = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID            = aws_cognito_user_pool_client.web.id
      AWS_LWA_PORT                 = "8000"
      AWS_LWA_READINESS_CHECK_PATH = "/health"
    }
  }

  depends_on = [aws_cloudwatch_log_group.parser]
}

resource "aws_lambda_function_url" "parser" {
  function_name      = aws_lambda_function.parser.function_name
  authorization_type = "NONE" # the handler checks the Cognito token itself (every call costs money)

  cors {
    allow_origins = length(local.cors_origins) > 0 ? local.cors_origins : ["http://localhost:5173"]
    allow_methods = ["POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 600
  }
}

# A public function URL needs both permissions. Child resources: not imported.
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "AllowPublicFunctionUrl"
  function_name          = aws_lambda_function.parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_invoke" {
  statement_id             = "AllowPublicInvokeViaFunctionUrl"
  function_name            = aws_lambda_function.parser.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}

# Cheapest insurance in the course. Covers the whole account's spend in the month.
resource "aws_budgets_budget" "monthly" {
  count = var.budget_email != "" ? 1 : 0

  name         = "${var.project_name}-monthly-5-usd"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = "5"
  limit_unit   = "USD"

  dynamic "notification" {
    for_each = [80, 100]

    content {
      notification_type          = "ACTUAL"
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [var.budget_email]
    }
  }
}
