# gcp/: Spry's core on Google Cloud

Frontend on **Firebase Hosting**, API on **Cloud Run**, database on **Cloud SQL (PostgreSQL)**,
secrets in **Secret Manager**, images in **Artifact Registry**. Sign-in (Cognito), the weekly report and
the agenda parser **stay on AWS** (see docs/adr/0008-google-cloud.md). `infra/` (AWS) and `gcp/` have
separate Terraform state, in separate HCP Terraform workspaces (`new-project-dev`, `spry-gcp`).

## Check the configuration without a Google account
```
cd gcp
terraform init -backend=false      # or `terraform init` with an HCP workspace named spry-gcp
terraform validate                 # syntax, types, references: needs no credentials
```
(`terraform plan` needs a real project, so it is skipped on this route.)

## Run the API the way Cloud Run runs it, locally
```
make down                                                  # if `make up` is running (port 8000)
docker compose --env-file .env -f gcp/local/docker-compose.yml up --build -d
curl http://localhost:8000/api/health                      # {"status":"ok"}: a real query in Postgres
```
Frontend against it: put `VITE_API_URL=` (empty) in `.env.local` at the repository root, run `make dev-frontend`, sign in
and create a meeting: it is stored in and read from the local PostgreSQL. Stop: `docker compose -f gcp/local/docker-compose.yml down -v`.

## Deploy to Google Cloud (needs a project with billing)
1. `gcloud auth login` and `gcloud auth application-default login` (your own account; **no service account keys**).
   Create the project (`gcloud projects create <id>`), link billing, set a $5 budget alert.
2. In `gcp/terraform.tfvars` set `project_id`. `terraform init && terraform apply`
   (the first apply uses Google's hello image so that it succeeds before your image exists).
3. Build and push the API image:
   ```
   gcloud auth configure-docker us-central1-docker.pkg.dev
   REPO=$(terraform output -raw image_repository)
   docker build -f backend/Dockerfile.cloudrun -t $REPO/spry-api:v1 backend && docker push $REPO/spry-api:v1
   terraform apply -var image=$REPO/spry-api:v1
   ```
4. Frontend: `VITE_API_URL= npm run build` in `frontend/` (so the app calls `/api`, which Firebase rewrites to Cloud Run),
   then `firebase projects:addfirebase <id>` once and `firebase deploy --only hosting --config gcp/firebase.json`.
5. Add `https://<project>.web.app/login` to the Cognito callback URLs (in `infra/`, `extra_app_urls`) if you want to sign in there.

## What still runs on AWS
Cognito (sign-in; the Cloud Run API verifies its tokens), the weekly report (SQS, Scheduler, SES), the agenda parser (Bedrock),
and the AWS deployment of the whole app.

## Stop paying
- `terraform apply -var db_running=false` stops the database compute (**storage still bills**), or
- `terraform destroy` deletes everything this configuration created. Check Billing → Reports a day later.
