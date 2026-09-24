terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
  }
}

provider "azurerm" {
  features {}
  # azurerm 4+ no longer infers the subscription from the Azure CLI; up.sh
  # passes the CLI's current one unless SUBSCRIPTION_ID is set.
  subscription_id = var.subscription_id
}
