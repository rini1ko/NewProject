#!/usr/bin/env python3
"""Writes infra/imports.tf: one `import` block for every resource of the three CloudFormation
stacks (auth, reports, ai), using the REAL ids that CloudFormation knows.

Run it BEFORE the stacks are deleted (CloudFormation forgets the ids afterwards):

    AWS_REGION=eu-central-1 PROJECT_NAME=new-project python3 infra/migrate/gen_imports.py

Resources that are not imported on purpose (Lambda permissions) are created by Terraform
as new child resources.
"""

import os
import sys

import boto3

PROJECT = os.environ.get("PROJECT_NAME") or os.environ.get("APP_NAME") or "meetings"
REGION = os.environ["AWS_REGION"]
cfn = boto3.client("cloudformation", region_name=REGION)
account = boto3.client("sts").get_caller_identity()["Account"]

POLICY_BASIC = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
POLICY_VPC = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"


def physical_ids(stack: str) -> dict[str, str]:
    """logical id -> physical id, for the resources that exist in the stack."""
    try:
        pages = cfn.get_paginator("list_stack_resources").paginate(StackName=stack)
        return {
            r["LogicalResourceId"]: r["PhysicalResourceId"]
            for page in pages
            for r in page["StackResourceSummaries"]
            if r["ResourceStatus"] != "DELETE_COMPLETE"
        }
    except cfn.exceptions.ClientError as error:
        print(f"# stack {stack} not found ({error.response['Error']['Message']})", file=sys.stderr)
        return {}


imports: list[tuple[str, str, str]] = []  # (terraform address, import id, comment)


def add(address: str, import_id: str, comment: str = "") -> None:
    imports.append((address, import_id, comment))


# ------------------------------------------------------------------------------- auth
auth = physical_ids(f"{PROJECT}-auth")
if "UserPool" in auth:
    pool = auth["UserPool"]
    add("aws_cognito_user_pool.main", pool, "KEEP: every account lives here")
    if "UserPoolDomain" in auth:
        add("aws_cognito_user_pool_domain.main", auth["UserPoolDomain"])
    if "GoogleIdentityProvider" in auth:
        add("aws_cognito_identity_provider.google[0]", f"{pool}:Google")
    if "UserPoolClient" in auth:
        add("aws_cognito_user_pool_client.web", f"{pool}/{auth['UserPoolClient']}")

# ----------------------------------------------------------------------------- reports
rep = physical_ids(f"{PROJECT}-reports")
if "ReportsBucket" in rep:
    bucket = rep["ReportsBucket"]
    add("aws_s3_bucket.reports", bucket, "KEEP: holds every report")
    # The four settings of the bucket are separate resources; their import id is the bucket.
    add("aws_s3_bucket_public_access_block.reports", bucket)
    add("aws_s3_bucket_server_side_encryption_configuration.reports", bucket)
    add("aws_s3_bucket_lifecycle_configuration.reports", bucket)
    add("aws_s3_bucket_notification.reports", bucket)
if "S3GatewayEndpoint" in rep:
    add("aws_vpc_endpoint.s3", rep["S3GatewayEndpoint"])
if "RequestsDlq" in rep:
    add("aws_sqs_queue.requests_dlq", rep["RequestsDlq"])
if "RequestsQueue" in rep:
    add("aws_sqs_queue.requests", rep["RequestsQueue"])
if "BuilderLogGroup" in rep:
    add("aws_cloudwatch_log_group.builder", rep["BuilderLogGroup"])
if "BuilderRole" in rep:
    role = rep["BuilderRole"]
    add("aws_iam_role.builder", role)
    add("aws_iam_role_policy.builder", f"{role}:reports-builder")
    add("aws_iam_role_policy_attachment.builder_vpc", f"{role}/{POLICY_VPC}")
if "BuilderFunction" in rep:
    add("aws_lambda_function.builder", rep["BuilderFunction"])
if "BuilderQueueMapping" in rep:
    add("aws_lambda_event_source_mapping.builder_queue", rep["BuilderQueueMapping"])
if "SchedulerRole" in rep:
    role = rep["SchedulerRole"]
    add("aws_iam_role.scheduler", role)
    add("aws_iam_role_policy.scheduler", f"{role}:start-report")
if "WeeklySchedule" in rep:
    add("aws_scheduler_schedule.weekly", f"default/{PROJECT}-weekly-report")
if "MailerLogGroup" in rep:
    add("aws_cloudwatch_log_group.mailer", rep["MailerLogGroup"])
if "MailerRole" in rep:
    role = rep["MailerRole"]
    add("aws_iam_role.mailer", role)
    add("aws_iam_role_policy.mailer", f"{role}:reports-mailer")
    add("aws_iam_role_policy_attachment.mailer_logs", f"{role}/{POLICY_BASIC}")
if "MailerFunction" in rep:
    add("aws_lambda_function.mailer", rep["MailerFunction"])
if "SenderIdentity" in rep:
    add("aws_sesv2_email_identity.sender", rep["SenderIdentity"])

# ---------------------------------------------------------------------------------- ai
ai = physical_ids(f"{PROJECT}-ai")
if "LogGroup" in ai:
    add("aws_cloudwatch_log_group.parser", ai["LogGroup"])
if "Role" in ai:
    role = ai["Role"]
    add("aws_iam_role.parser", role)
    add("aws_iam_role_policy.parser", f"{role}:call-claude")
    add("aws_iam_role_policy_attachment.parser_logs", f"{role}/{POLICY_BASIC}")
if "Function" in ai:
    add("aws_lambda_function.parser", ai["Function"])
    add("aws_lambda_function_url.parser", ai["Function"])
if "Budget" in ai:
    add("aws_budgets_budget.monthly[0]", f"{account}:{ai['Budget']}")

if not imports:
    sys.exit("Nothing to import: are the stacks still there and AWS_REGION/PROJECT_NAME right?")

out = os.path.join(os.path.dirname(__file__), "..", "imports.tf")
with open(out, "w") as f:
    f.write("# Generated by infra/migrate/gen_imports.py. Delete this file after the migration.\n")
    for address, import_id, comment in imports:
        f.write(f"\nimport {{\n  to = {address}\n  id = \"{import_id}\"\n}}\n")
        if comment:
            f.write(f"# {comment}\n")
print(f"Wrote {len(imports)} import blocks to {os.path.normpath(out)}")
