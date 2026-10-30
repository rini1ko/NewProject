# Terraform migration: step by step (Lab 7)

All commands run from the repository root. Replace `new-project` and `eu-central-1` with the
values from your `.env`. **Do the steps in this order**; steps 5 and 6 delete CloudFormation stacks.

## 0. Before you start
- Terraform >= 1.10 (`terraform version`), an HCP Terraform organization, `terraform login`.
- The **bootstrap role** from Part 1, Step 7 (OIDC + IAM role). If you do not have it:
  `cd infra/bootstrap && terraform init && terraform apply -var tfc_organization=<org> -var region=<region>`.
- In HCP Terraform create the workspace `new-project-dev`: **Remote** execution mode,
  working directory `infra`, and connect it to the repository (Settings, Version Control) later (step 8).
- Workspace **environment variables**: `TFC_AWS_PROVIDER_AUTH=true`, `TFC_AWS_RUN_ROLE_ARN=<role_arn>`.
- Workspace **Terraform variables**: everything in `infra/terraform.tfvars` is read from the
  file; add `google_client_secret` (sensitive) there if Google sign-in is enabled, and
  `google_client_id` in the tfvars file.
- In `infra/versions.tf` fill in your organization and the workspace name. Fill in `infra/terraform.tfvars`.

## 1. Check the plan of the new code (nothing is imported yet)
```
make infra-validate        # syntax, types and references; no cloud access
make infra-fmt
```
Fix what `validate` reports. (If it says `invoked_via_function_url` is unsupported, raise the
AWS provider version in `versions.tf`.)

## 2. Generate the import blocks (BEFORE deleting any stack)
CloudFormation knows the real ids; it forgets them when a stack is deleted.
```
AWS_REGION=eu-central-1 PROJECT_NAME=new-project python3 infra/migrate/gen_imports.py
```
It writes `infra/imports.tf`. Open it and check: one block per resource, the user pool and the
reports bucket included. Count them: write the number down (step 7 question 1).
The three Lambda permissions are **not** imported: Terraform creates its own.

## 3. Tell CloudFormation to let go
```
python3 infra/migrate/retain.py infra/auth.yaml infra/reports.yaml infra/ai.yml
for s in auth reports ai; do
  f=infra/$s.yaml; [ $s = ai ] && f=infra/ai.yml
  aws cloudformation deploy --stack-name new-project-$s --template-file $f \
      --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset
done
```
(parameters keep their previous values). Then check in the CloudFormation console that every
resource now has `DeletionPolicy: Retain`.

## 4. Delete the three stacks (the resources stay)
```
for s in auth reports ai; do
  aws cloudformation delete-stack --stack-name new-project-$s
  aws cloudformation wait stack-delete-complete --stack-name new-project-$s
done
```
Check in the consoles that the Cognito user pool, the reports bucket, the Lambda functions and
the queue are still there.

## 5. Plan until it says nothing
```
git add -A infra && make infra-plan
```
Goal: `Plan: N to import, <a few> to add, <a few> to change, 0 to destroy.`

What is **expected**:
- to add: the three Lambda permissions (`aws_lambda_permission.*`), because they are re-created.
- to change (in place): `tags_all` (the new `ManagedBy = terraform` tag), the mailer's code
  (`source_code_hash`: same code, zipped by Terraform), the lifecycle rule of the reports bucket
  (`prefix` becomes `filter { prefix }`), possibly `provider_details` of the Google provider.

What is **never acceptable**: any `-/+` or `# forces replacement` on the user pool, the reports
bucket or a Lambda function, and anything with `destroy`. If you see one, fix the HCL (not the
resource) until it disappears. For a user pool the usual cause is the `schema` block: it is in
`ignore_changes` already; for a function it is a name or `image_config` that differs.

## 6. Apply, then prove it is stable
Merge to `main` (or start a run in HCP Terraform) and wait for `Apply finished`. Then:
```
make infra-plan | tee plan-after-migration.txt      # must end with: No changes.
```
Delete `infra/imports.tf`, `infra/migrate/`'s output and the old files:
```
git rm infra/auth.yaml infra/reports.yaml infra/ai.yml \
       infra/deploy-auth.sh infra/deploy-reports.sh infra/deploy-ai.sh \
       infra/destroy-auth.sh infra/destroy-ai.sh
rm infra/imports.tf
```
Optional cleanup: the three old Lambda permission statements still exist next to Terraform's
(`aws lambda get-policy --function-name new-project-ai-parser`, then `aws lambda remove-permission
--statement-id <old id>`). They are harmless duplicates.

## 7. Check the app still works
`make sync-env`, `make deploy-frontend`, open the site, sign in, parse an agenda.
`make report-now` (the weekly report) if you use it. The user pool id, the client id and the
parser URL are the same as before, so nothing else changes.

## 8. The pipeline (submission item 2)
Connect the workspace to the repository (Settings, Version Control; working directory `infra`).
Make one small change (a tag, a log retention), open a pull request, read the plan in the check,
merge, and take the screenshot of the run that says **Apply finished**.

## 9. Drift (Step 5 of the lab)
Change the parser's timeout in the console, start *New run, plan only* in HCP Terraform, find the
change in the plan and let Terraform put it back.

## What to hand in (checklist)
- [ ] Commit / merged PR: `infra/*.tf`, Makefile, scripts, README, `docs/adr/0007-terraform.md`
- [ ] Screenshot: HCP Terraform run, `Apply finished`, started by a merge
- [ ] `plan-after-migration.txt` ending in `No changes. Your infrastructure matches the configuration.`
