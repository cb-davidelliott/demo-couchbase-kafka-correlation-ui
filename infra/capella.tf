locals {
  collections = toset([
    "logs", "traces", "metrics", "customers", "orders",
    "support_tickets", "accounts", "services", "incidents",
    "payments", "shipments", "deployments"
  ])
}

resource "couchbase-capella_cluster" "demo" {
  organization_id = var.capella_organization_id
  project_id      = var.capella_project_id
  name            = "${var.prefix}-cluster"
  description     = "Auto-provisioned for Couchbase Capella + Kafka + OTel demo"

  cloud_provider = {
    type   = "azure"
    region = var.capella_cluster_region
    cidr   = "10.1.0.0/23"
  }

  service_groups = [
    {
      node = {
        compute = {
          cpu = 4
          ram = 16
        }
        disk = {
          storage = 64
          type    = "P6"
        }
      }
      num_of_nodes = 3
      services     = ["data", "index", "query"]
    }
  ]

  availability = {
    type = "single"
  }

  support = {
    plan     = "developer pro"
    timezone = "PT"
  }
}

resource "random_password" "db_password" {
  length      = 20
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "couchbase-capella_bucket" "demo" {
  organization_id            = var.capella_organization_id
  project_id                 = var.capella_project_id
  cluster_id                 = couchbase-capella_cluster.demo.id
  name                       = var.couchbase_bucket
  type                       = "couchbase"
  storage_backend            = "couchstore"
  memory_allocation_in_mb    = 512
  bucket_conflict_resolution = "seqno"
  durability_level           = "none"
  replicas                   = 1
  flush                      = false
  time_to_live_in_seconds    = 0
}

resource "couchbase-capella_scope" "app360" {
  organization_id = var.capella_organization_id
  project_id      = var.capella_project_id
  cluster_id      = couchbase-capella_cluster.demo.id
  bucket_id       = couchbase-capella_bucket.demo.id
  scope_name      = var.couchbase_scope
}

resource "couchbase-capella_collection" "collections" {
  for_each        = local.collections
  organization_id = var.capella_organization_id
  project_id      = var.capella_project_id
  cluster_id      = couchbase-capella_cluster.demo.id
  bucket_id       = couchbase-capella_bucket.demo.id
  scope_name      = couchbase-capella_scope.app360.scope_name
  collection_name = each.value
  max_ttl         = 0
}

resource "couchbase-capella_database_credential" "demo_user" {
  organization_id = var.capella_organization_id
  project_id      = var.capella_project_id
  cluster_id      = couchbase-capella_cluster.demo.id
  name            = "demo-app-user"
  password        = random_password.db_password.result

  access = [
    {
      privileges = ["data_reader", "data_writer"]
      resources = {
        buckets = [
          {
            name = couchbase-capella_bucket.demo.name
            scopes = [
              {
                name        = couchbase-capella_scope.app360.scope_name
                collections = ["*"]
              }
            ]
          }
        ]
      }
    }
  ]
}

resource "couchbase-capella_allowlist" "vm_ip" {
  organization_id = var.capella_organization_id
  project_id      = var.capella_project_id
  cluster_id      = couchbase-capella_cluster.demo.id
  cidr            = "${azurerm_public_ip.pip.ip_address}/32"
  comment         = "Demo VM - auto-provisioned by Terraform"
}
