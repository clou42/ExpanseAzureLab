terraform {
  backend "local" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>4.57.0"

    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~>3.7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.0"
    }
    http = { source = "hashicorp/http" }
  }
}
