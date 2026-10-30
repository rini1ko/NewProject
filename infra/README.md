# infra/: how the infrastructure is described and changed

| What | Tool | Where |
|---|---|---|
| ECR, backend (VPC, Aurora, Lambda API), frontend (S3 + CloudFront), certificate | CloudFormation | `ecr.yaml`, `backend.yaml`, `frontend.yaml`, `certificate.yaml` (via `make deploy-backend`, `make deploy-frontend`) |
| Cognito (Lab 4), weekly report (Lab 5), agenda parser (Lab 6) | **Terraform** | `auth.tf`, `reports.tf`, `ai.tf` |

Terraform state lives in **HCP Terraform** (workspace `<project>-dev`). Terraform reads the
CloudFormation stacks' outputs (`locals.tf`); the scripts read Terraform's outputs
(`terraform output -raw ...` through `tf_output` in `common.sh`).

```
infra/
  versions.tf      terraform { cloud { ... } required_providers { ... } } and the provider block
  variables.tf     project_name, region, report_email, parser_*, ... (typed, validated)
  locals.tf        data sources for the CloudFormation stacks and values shared by the .tf files
  auth.tf          Cognito user pool, domain, Google sign-in, web app client  (was auth.yaml)
  reports.tf       S3, SQS, Scheduler, builder + mailer Lambdas, SES           (was reports.yaml)
  ai.tf            agenda parser Lambda + function URL + $5 budget             (was ai.yml)
  outputs.tf       what the Makefile, the scripts and the frontend build read
  terraform.tfvars non-secret values only
  lambda/mailer/   the mailer's code (used to be inline in the template)
  bootstrap/       one-time IAM role + OIDC provider for HCP Terraform (local state)
  migrate/         one-off scripts for the CloudFormation -> Terraform move (see below)
```

## Everyday workflow

1. Change a `.tf` file on a branch; `make infra-fmt` and `make infra-validate`.
2. Open a pull request. HCP Terraform runs a **plan** as a check: read it.
3. Merge to `main`. HCP Terraform runs **apply**. Nobody applies from a laptop.
4. `make infra-plan` runs a plan in HCP Terraform from your laptop (read-only).

The application image is built and pushed by `make deploy-backend` (CloudFormation). The
builder and the parser Lambdas run the same image, read from the backend stack's `ImageUri`
output, so **after `make deploy-backend`, start a run in HCP Terraform** (workspace: New run)
to move them to the new image. A change that needs both (for example a new environment variable
for the Lambda): merge the Terraform change first, then deploy the application.

## Secrets

- `google_client_secret`: a *sensitive Terraform variable* in the HCP workspace. Never in a file.
- The database password is read from SSM (`/<project>/db-password`) by a data source, so it is
  in the Terraform state (and in the Lambda's environment, as before). The state is
  therefore sensitive: only people who may read the database password may read it.
- No AWS keys anywhere: HCP Terraform assumes a role through OIDC (dynamic credentials).

## CloudFormation -> Terraform migration (done once)

See `migrate/` and the numbered steps in `docs/terraform-migration.md`.
