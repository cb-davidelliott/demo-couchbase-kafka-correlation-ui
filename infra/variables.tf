variable "subscription_id" {
  type        = string
  description = "The Azure subscription ID."
}

variable "location" {
  type        = string
  description = "The Azure region to deploy resources."
  default     = "eastus"
}

variable "prefix" {
  type        = string
  description = "Prefix for all resources to avoid name collisions."
  default     = "cb-otel-demo"
}

variable "vm_size" {
  type        = string
  description = "The size of the Virtual Machine."
  default     = "Standard_D4s_v5"
}

variable "admin_username" {
  type        = string
  description = "The admin username for the VM."
  default     = "azureuser"
}

variable "github_repo_url" {
  type        = string
  description = "The GitHub repository URL of this demo project."
  default     = "https://github.com/cb-davidelliott/demo-couchbase-kafka-correlation-ui.git"
}

# ------------------------------------------------------------------------------
# Couchbase Capella Management API
# ------------------------------------------------------------------------------

variable "capella_auth_token" {
  type        = string
  description = "Couchbase Capella API v4 personal access token. Create one in Capella UI under Settings > API Keys."
  sensitive   = true
}

variable "capella_organization_id" {
  type        = string
  description = "Couchbase Capella organization ID. Found in the Capella URL: cloud.couchbase.com/organizations/{id}/..."
}

variable "capella_project_id" {
  type        = string
  description = "Couchbase Capella project ID. Found in the Capella project URL."
}

variable "capella_cluster_region" {
  type        = string
  description = "Azure region for the Capella cluster. Must be a Capella-supported Azure region (e.g. eastus, westeurope, australiaeast)."
  default     = "eastus"
}

# ------------------------------------------------------------------------------
# Couchbase Schema (optional overrides — defaults are fine for the demo)
# ------------------------------------------------------------------------------

variable "couchbase_bucket" {
  type        = string
  description = "Couchbase bucket name."
  default     = "demo"
}

variable "couchbase_scope" {
  type        = string
  description = "Couchbase scope name."
  default     = "app360"
}

# ------------------------------------------------------------------------------
# Demo UI
# ------------------------------------------------------------------------------

variable "demo_preferred_incident_id" {
  type        = string
  description = "Incident ID the UI auto-selects on load. Set to match GENERATOR_INCIDENT_ID."
  default     = "INC-DEMO-001"
}

# ------------------------------------------------------------------------------
# Event Generator
# ------------------------------------------------------------------------------

variable "generator_profile" {
  type        = string
  description = "Event generator profile: demo or load."
  default     = "demo"
}

variable "generator_interval_seconds" {
  type        = string
  description = "Seconds to sleep between event generator batches."
  default     = "5.0"
}

variable "generator_events_per_batch" {
  type        = string
  description = "Number of generated business events per event generator loop."
  default     = "1"
}

variable "generator_enable_otel_calls" {
  type        = string
  description = "Whether generated events call the OTel demo service to produce traces/logs."
  default     = "true"
}

variable "generator_new_customer_probability" {
  type        = string
  description = "Probability that each generated event creates a new customer document."
  default     = "0.2"
}

variable "generator_ticket_probability" {
  type        = string
  description = "Probability that each generated event creates a support ticket document."
  default     = "0.25"
}

variable "generator_unique_metric_docs" {
  type        = string
  description = "Whether metrics use unique Kafka keys instead of updating aggregate metric docs."
  default     = "false"
}

variable "generator_enable_metrics" {
  type        = string
  description = "Whether the generator publishes metric documents."
  default     = "true"
}

variable "generator_enable_incident_updates" {
  type        = string
  description = "Whether the generator rewrites incident summary documents during event generation."
  default     = "true"
}

variable "generator_log_every_n_events" {
  type        = string
  description = "How often the generator logs progress."
  default     = "1"
}

variable "generator_flush_every_n_events" {
  type        = string
  description = "How often the generator flushes the Kafka producer. Empty uses profile default."
  default     = ""
}

variable "generator_incident_update_every_n_events" {
  type        = string
  description = "How often incident summary documents are updated."
  default     = "1"
}

variable "generator_producer_linger_ms" {
  type        = string
  description = "Kafka producer linger.ms."
  default     = "5"
}

variable "generator_producer_batch_num_messages" {
  type        = string
  description = "Kafka producer batch.num.messages."
  default     = "10000"
}

variable "generator_producer_queue_max_messages" {
  type        = string
  description = "Kafka producer queue.buffering.max.messages."
  default     = "100000"
}

variable "generator_producer_compression" {
  type        = string
  description = "Kafka producer compression.type."
  default     = "lz4"
}

variable "generator_enterprise_account_count" {
  type        = string
  description = "Number of enterprise account reference documents to seed."
  default     = "30"
}

variable "generator_scenario" {
  type        = string
  description = "Incident scenario mode for generated enterprise data."
  default     = "payment_outage"
}

variable "generator_incident_id" {
  type        = string
  description = "Optional fixed incident ID for repeatable demos."
  default     = "INC-DEMO-001"
}

variable "generator_random_seed" {
  type        = string
  description = "Optional random seed for repeatable generated data."
  default     = ""
}

variable "generator_max_active_customers" {
  type        = string
  description = "Cap on the number of active customer objects held in generator memory."
  default     = "500"
}
