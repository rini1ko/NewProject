# Cloud SQL for PostgreSQL: the smallest shared-core tier. UNLIKE Aurora Serverless it does not
# pause when idle: it runs and bills (about $7.67 a month plus storage) until you stop it.
resource "google_sql_database_instance" "main" {
  name                = "spry-db"
  database_version    = "POSTGRES_16"
  region              = var.region
  deletion_protection = var.db_deletion_protection

  settings {
    edition           = "ENTERPRISE" # shared-core tiers exist only in this edition
    tier              = "db-f1-micro"
    disk_size         = 10
    disk_type         = "PD_SSD"
    availability_type = "ZONAL"
    activation_policy = var.db_running ? "ALWAYS" : "NEVER"

    backup_configuration {
      enabled = false # a lab database; backups would add to the bill
    }

    ip_configuration {
      ipv4_enabled = true # no authorized networks: Cloud Run reaches it through the Cloud SQL connector
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "meetings" {
  name     = "meetings"
  instance = google_sql_database_instance.main.name
}

# The password is generated here and lives in Secret Manager (and, unavoidably, in the state:
# protect the HCP workspace like the secret itself). It never goes into the repository.
resource "random_password" "db" {
  length  = 32
  special = false # keeps it safe to paste into a URL
}

resource "google_sql_user" "meetings" {
  name     = "meetings"
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

# The API reads one DATABASE_URL (as on AWS), so the whole URL is a secret. The host is a Unix
# socket that Cloud Run mounts for the Cloud SQL connection.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "database-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  secret_data = join("", [
    "postgresql+asyncpg://${google_sql_user.meetings.name}:${random_password.db.result}",
    "@/${google_sql_database.meetings.name}",
    "?host=/cloudsql/${google_sql_database_instance.main.connection_name}",
  ])
}
