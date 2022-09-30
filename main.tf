terraform {
  required_version = ">= 0.13.1" # see https://releases.hashicorp.com/terraform/
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.3.0" # see https://github.com/terraform-providers/terraform-provider-google/releases
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 4.3.0" # see https://github.com/terraform-providers/terraform-provider-google-beta/releases
    }
  }
}

locals {
  memory_store_name = (
    var.full_name != ""
    ?
    format("%s-%s", var.full_name, var.name_suffix)
    :
    format("redis-%s-%s", var.name, var.name_suffix)
  )
  memory_store_display_name = "Redis generated by Terraform ${var.name_suffix}"
  region                    = data.google_client_config.google_client.region

  # determine a primary zone if it is not provided
  primary_zone_letter = var.primary_zone == "" ? "a" : var.primary_zone
  primary_zone        = "${local.region}-${local.primary_zone_letter}"

  # determine an alternate zone if it is not provided
  all_zone_letters       = ["a", "b", "c", "d"]
  remaining_zone_letters = tolist(setsubtract(toset(local.all_zone_letters), toset([local.primary_zone_letter])))
  alternate_zone_letter  = var.alternate_zone == "" ? local.remaining_zone_letters.0 : var.alternate_zone
  alternate_zone         = "${local.region}-${local.alternate_zone_letter}"

  # Determine connection mode and IP ranges
  connect_mode  = var.use_private_g_services ? "PRIVATE_SERVICE_ACCESS" : "DIRECT_PEERING"
  ip_cidr_range = var.use_private_g_services ? null : var.ip_cidr_range
  # Read-replica for Redis memorystore
  redis_replicas_mode = var.use_redis_replicas ? "READ_REPLICAS_ENABLED" : "READ_REPLICAS_DISABLED"
  redis_replica_count = var.use_redis_replicas ? var.redis_replica_count : null
  # DNS
  create_private_dns = var.dns_zone_name == "" ? false : true
}

data "google_client_config" "google_client" {}

resource "google_project_service" "redis_api" {
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns_api" {
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_redis_instance" "redis_store" {
  name                    = local.memory_store_name
  memory_size_gb          = var.memory_size_gb
  display_name            = local.memory_store_display_name
  redis_version           = var.redis_version
  tier                    = var.service_tier
  authorized_network      = var.vpc_network
  region                  = local.region
  location_id             = local.primary_zone
  auth_enabled            = var.auth_enabled
  alternative_location_id = var.service_tier == "STANDARD_HA" ? local.alternate_zone : null
  connect_mode            = local.connect_mode
  reserved_ip_range       = local.ip_cidr_range
  depends_on              = [google_project_service.redis_api]
  read_replicas_mode      = local.redis_replicas_mode
  replica_count           = local.redis_replica_count
  timeouts {
    create = var.redis_timeout
    update = var.redis_timeout
    delete = var.redis_timeout
  }
}

resource "google_dns_record_set" "redis_subdomain" {
  count        = local.create_private_dns ? 1 : 0
  managed_zone = var.dns_zone_name
  name         = format("%s.%s", var.dns_subdomain, data.google_dns_managed_zone.dns_zone.dns_name)
  type         = "A"
  rrdatas      = [google_redis_instance.redis_store.host]
  ttl          = var.dns_ttl
}

resource "google_dns_record_set" "redis_read_replica_subdomain" {
  count        = var.use_redis_replicas ? (local.create_private_dns ? 1 : 0) : 0
  managed_zone = var.dns_zone_name
  name         = format("%s.%s", var.dns_subdomain, data.google_dns_managed_zone.dns_zone.dns_name)
  type         = "A"
  rrdatas      = [google_redis_instance.redis_store.read_endpoint]
  ttl          = var.dns_ttl
}

data "google_dns_managed_zone" "dns_zone" {
  name       = var.dns_zone_name
  depends_on = [google_project_service.dns_api]
}
