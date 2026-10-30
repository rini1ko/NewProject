# 0007. Terraform and HCP Terraform for Cognito, reports and the agenda parser

Status: accepted (draft: read it, change it, make it yours) · Date: 2026-10-30

## Context
Labs 4-6 added three CloudFormation templates (Cognito, the weekly report, the agenda parser).
They work, but the project now has more than one environment to think about (dev, a possible
stage), already reaches outside AWS (the Google OAuth client, GitHub), and several people may
change infrastructure. The state of CloudFormation stacks is hidden inside AWS, a failed update
rolls back without a reviewable plan, and the templates are hard to reuse for another
environment. Part of the infrastructure (network, database, API, site) was built in earlier labs
as CloudFormation and is stable.

## Decision
- **Terraform** (HCL) describes the three newest stacks: `infra/auth.tf`, `reports.tf`, `ai.tf`.
  The older stacks (`ecr`, `backend`, `frontend`, `certificate`) stay CloudFormation; Terraform
  reads their outputs with `aws_cloudformation_stack` data sources, and the scripts read
  Terraform's outputs. Moving everything at once was not worth the risk.
- **State** in **HCP Terraform** (one workspace per environment, here `new-project-dev`):
  one central, locked, versioned state.
- **Who may change the infrastructure:** a pull request. HCP Terraform shows the plan as a check;
  after a merge to `main` it applies, with short-lived credentials from an IAM role it assumes
  through OIDC (no AWS keys in HCP Terraform or in the repository). `terraform apply` from a
  laptop is for emergencies only; the Makefile has no apply target. An AI assistant may write
  `.tf` files and run `plan`, but it goes through the same pull request and never applies.
- **Existing resources were adopted, not re-created**: the stacks were marked `Retain`, deleted,
  and the resources were `import`ed (the generated `imports.tf` was deleted afterwards). The user
  pool and the reports bucket hold user data and reports, so they were never replaced.
  `aws_cognito_user_pool` also has `prevent_destroy`.

## Alternatives considered
- **Stay on CloudFormation.** Free, state kept by AWS, new AWS services at launch. Lost: AWS only,
  no plan on every pull request, drift only on request, nothing that also covers Google or GitHub.
- **AWS CDK.** A real language on top of CloudFormation, but the same stacks, the same rollback and
  the same AWS-only limit; one more build step.
- **OpenTofu.** Same files and commands, open-source licence. HCP Terraform and the course
  material use Terraform, and the files would work with either, so the choice can be reversed.
- **State in an S3 bucket with a lock** instead of HCP Terraform. Free and under our control,
  but we would build the run, plan-on-PR and OIDC pieces ourselves.

## Consequences
- **Secrets.** The Google client secret is a sensitive variable of the HCP workspace; it is
  also in the Terraform state and in HCP Terraform's run logs only as `(sensitive value)`. The
  database password is read from SSM and so is in the **state** too (and in the Lambda's
  environment, as before). The state must be protected like the secrets themselves: workspace
  access in HCP Terraform is the access control.
- **If HCP Terraform is down:** the application keeps running (Terraform is not on the request
  path). We cannot apply infrastructure changes until it is back; in an emergency, a person with
  AWS rights can run `terraform apply` from a laptop against the same remote state (locked by
  HCP Terraform) or change the resource and then fix the code.
- **Two roads for changes.** The application image is built by `make deploy-backend`; the builder
  and the parser run the same image, so a Terraform run is needed after it. A change that needs
  both is merged as Terraform first, then deployed.
- The bootstrap IAM role has `AdministratorAccess` and trusts every workspace of the organization;
  it should be narrowed (one workspace, the services we manage) before real production use.
- New environments are a new workspace and a new `.tfvars` file, not a copy of the templates.
