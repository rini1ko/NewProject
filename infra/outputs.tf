# Everything the Makefile, the scripts and the frontend build read: `terraform output -raw <name>`.

output "region" {
  value = var.region
}

# auth
output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "cognito_domain" {
  description = "Cognito domain for OAuth redirects (Google)"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "issuer" {
  description = "Issuer of the tokens; the backend checks it"
  value       = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "google_enabled" {
  value = local.google_enabled ? "true" : "false"
}

# reports
output "reports_bucket" {
  value = aws_s3_bucket.reports.bucket
}

output "queue_url" {
  value = aws_sqs_queue.requests.url
}

output "dlq_url" {
  value = aws_sqs_queue.requests_dlq.url
}

output "builder_log_group" {
  value = aws_cloudwatch_log_group.builder.name
}

output "mailer_log_group" {
  value = aws_cloudwatch_log_group.mailer.name
}

# agenda parser
output "parse_url" {
  description = "POST here with the Cognito ID token; the frontend is built against it"
  value       = "${aws_lambda_function_url.parser.function_url}parse"
}

output "parser_log_group" {
  value = aws_cloudwatch_log_group.parser.name
}
