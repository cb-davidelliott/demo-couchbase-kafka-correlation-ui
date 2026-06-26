terraform {
  required_version = ">= 1.5.2"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.117.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.3.0"
    }
    couchbase-capella = {
      source  = "couchbasecloud/couchbase-capella"
      version = "~> 1.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "couchbase-capella" {
  authentication_token = var.capella_auth_token
}
