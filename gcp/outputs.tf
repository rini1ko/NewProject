output "cloud_run_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "image_repository" {
  description = "Push your image here: <this>/spry-api:<tag>"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.spry.repository_id}"
}

output "sql_connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "firebase_hosting_url" {
  description = "Created by `firebase deploy` (see gcp/README.md)"
  value       = "https://${var.project_id}.web.app"
}
