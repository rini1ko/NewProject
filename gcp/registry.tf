# ECR's counterpart. 0.5 GB is free.
resource "google_artifact_registry_repository" "spry" {
  repository_id = "spry"
  location      = var.region
  format        = "DOCKER"
  description   = "Spry backend images"

  depends_on = [google_project_service.apis]
}
