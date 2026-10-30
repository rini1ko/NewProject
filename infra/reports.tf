# Weekly report: S3, SQS, Scheduler, the builder Lambda (in the VPC) and the mailer Lambda
# (outside it), SES identity (was reports.yaml, Lab 5).
#
# The VPC, subnets, security group and database come from the backend stack's outputs.

# ------------------------------------------------------------------------------ Storage
# In Terraform the bucket, the Lambda permission and the notification are three separate
# resources, so the CloudFormation circular dependency (and the "build the bucket name by hand"
# trick) is gone.
resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.mailer_from_s3]
}

# Free. Without it the builder's PutObject hangs: the VPC has no internet route.
resource "aws_vpc_endpoint" "s3" {
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_id            = local.backend["VpcId"]
  route_table_ids   = [local.backend["PrivateRouteTableId"]]
}

# --------------------------------------------------------------------------------- Queue
resource "aws_sqs_queue" "requests_dlq" {
  name                      = "${var.project_name}-report-requests-dlq"
  message_retention_seconds = 1209600
  max_message_size          = 1048576 # SQS's current default; Terraform's default would be 256 KiB
}

resource "aws_sqs_queue" "requests" {
  name             = "${var.project_name}-report-requests"
  max_message_size = 1048576 # SQS's current default; Terraform's default would be 256 KiB
  # 6 x the builder's timeout (90 s): a message must not reappear while attempt 1 runs.
  visibility_timeout_seconds = 540

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.requests_dlq.arn
    maxReceiveCount     = 3
  })
}

# ------------------------------------------------------------------------------- Builder
resource "aws_cloudwatch_log_group" "builder" {
  name              = "/${var.project_name}/reports-builder"
  retention_in_days = 7
}

# The roles were created by CloudFormation with generated names. `name` is left out on
# purpose: after the import Terraform keeps the real name instead of replacing the role.
resource "aws_iam_role" "builder" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "builder_vpc" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "builder" {
  name = "reports-builder"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:${local.partition}:s3:::${local.reports_bucket}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.requests.arn
      },
    ]
  })
}

resource "aws_lambda_function" "builder" {
  function_name = "${var.project_name}-reports-builder"
  package_type  = "Image"
  image_uri     = local.backend["ImageUri"]
  architectures = ["arm64"]
  memory_size   = 512
  timeout       = 90 # Aurora may need ~15 s to resume.
  role          = aws_iam_role.builder.arn

  # Same image as the API; only the command differs (no migrations, no public routes).
  image_config {
    command = ["uvicorn", "app.reports.worker:app", "--host", "0.0.0.0", "--port", "8000"]
  }

  vpc_config {
    subnet_ids         = split(",", local.backend["PrivateSubnetIds"])
    security_group_ids = [local.backend["FunctionSecurityGroupId"]]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.builder.name
  }

  environment {
    variables = {
      DATABASE_URL                 = "postgresql+asyncpg://${var.db_user}:${data.aws_ssm_parameter.db_password.value}@${local.backend["DatabaseEndpoint"]}:5432/${var.db_name}"
      DB_POOL_SIZE                 = "1"
      DB_MAX_OVERFLOW              = "0"
      REPORTS_BUCKET               = local.reports_bucket
      AWS_LWA_PORT                 = "8000"
      AWS_LWA_READINESS_CHECK_PATH = "/health"
      AWS_LWA_PASS_THROUGH_PATH    = "/events"
    }
  }

  depends_on = [aws_cloudwatch_log_group.builder]
}

# Lambda polls the queue for us, so the function itself never connects to SQS.
resource "aws_lambda_event_source_mapping" "builder_queue" {
  event_source_arn        = aws_sqs_queue.requests.arn
  function_name           = aws_lambda_function.builder.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}

# ------------------------------------------------------------------------------ Schedule
resource "aws_iam_role" "scheduler" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-report"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.builder.arn
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.requests.arn
      },
    ]
  })
}

resource "aws_scheduler_schedule" "weekly" {
  name                = "${var.project_name}-weekly-report"
  state               = var.schedule_state
  schedule_expression = var.schedule_expression
  # Without this the cron runs in UTC and the report lands at 9 or 10 depending on DST.
  schedule_expression_timezone = "Europe/Kyiv"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.schedule_target == "queue" ? aws_sqs_queue.requests.arn : aws_lambda_function.builder.arn
    role_arn = aws_iam_role.scheduler.arn
    # No week: the builder takes the previous ISO week.
    input = "{\"week\": null, \"source\": \"schedule\"}"
  }
}

# --------------------------------------------------------------------------------- Mailer
resource "aws_cloudwatch_log_group" "mailer" {
  name              = "/${var.project_name}/reports-mailer"
  retention_in_days = 7
}

resource "aws_iam_role" "mailer" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mailer_logs" {
  role       = aws_iam_role.mailer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "mailer" {
  name = "reports-mailer"
  role = aws_iam_role.mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:${local.partition}:s3:::${local.reports_bucket}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "arn:${local.partition}:ses:${var.region}:${local.account_id}:identity/*"
      },
    ]
  })
}

# The code used to be inline in the template; now it is a real file you can test and review.
data "archive_file" "mailer" {
  type        = "zip"
  source_file = "${path.module}/lambda/mailer/index.py"
  output_path = "${path.module}/.build/mailer.zip"
}

# Not in the VPC: it needs the internet (SES) and never touches the database.
# It only reads reports/ and never writes there; writing would trigger itself forever.
resource "aws_lambda_function" "mailer" {
  function_name    = "${var.project_name}-reports-mailer"
  runtime          = "python3.13"
  handler          = "index.handler"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = 30
  role             = aws_iam_role.mailer.arn
  filename         = data.archive_file.mailer.output_path
  source_code_hash = data.archive_file.mailer.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.mailer.name
  }

  environment {
    variables = {
      MAIL_FROM = var.report_email
      MAIL_TO   = var.report_email
    }
  }

  depends_on = [aws_cloudwatch_log_group.mailer]
}

# A child resource: not imported, Terraform creates its own statement.
resource "aws_lambda_permission" "mailer_from_s3" {
  statement_id   = "AllowReportsBucketInvoke"
  function_name  = aws_lambda_function.mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_account = local.account_id
  source_arn     = aws_s3_bucket.reports.arn
}

# ------------------------------------------------------------------------------------ SES
# No domain, so the address itself is the identity: AWS emails a confirmation link.
resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.report_email
}
