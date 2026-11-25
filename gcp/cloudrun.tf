# The API runs as its OWN service account, with only the two roles it needs.
# (Not the default compute service account: it starts with the Editor role.)
resource "google_service_account" "api" {
  account_id   = "spry-api"
  display_name = "Spry API (Cloud Run)"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "api_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "api_database_url" {
  secret_id = google_secret_manager_secret.database_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloud_run_v2_service" "api" {
  name                = "spry-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.api.email

    scaling {
      min_instance_count = 0 # scales to zero: an idle API costs $0
      max_instance_count = 3
    }

    volumes {
      name = "cloudsql"

      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      image = var.image

      ports {
        container_port = 8080 # Cloud Run also sets PORT=8080 for the container
      }

      resources {
        limits   = { cpu = "1", memory = "512Mi" }
        cpu_idle = true # CPU only while a request runs: request-based billing
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name = "DATABASE_URL"

        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }

      # db-f1-micro allows few connections: 3 instances x pool of 2 stays far below the limit.
      env {
        name  = "DB_POOL_SIZE"
        value = "2"
      }

      env {
        name  = "DB_MAX_OVERFLOW"
        value = "0"
      }

      env {
        name  = "COGNITO_USER_POOL_ID"
        value = var.cognito_user_pool_id
      }

      env {
        name  = "COGNITO_CLIENT_ID"
        value = var.cognito_client_id
      }

      env {
        name  = "CORS_ORIGINS"
        value = join(",", concat(["https://${var.project_id}.web.app", "https://${var.project_id}.firebaseapp.com"], var.extra_cors_origins))
      }
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.database_url,
    google_secret_manager_secret_iam_member.api_database_url,
    google_project_iam_member.api_cloudsql,
  ]
}

# "Allow unauthenticated" only lets requests reach the container: the API checks the Cognito
# token itself on every route except /api/health.
resource "google_cloud_run_v2_service_iam_member" "public" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
