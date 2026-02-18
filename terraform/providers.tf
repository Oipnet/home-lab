terraform {
  required_version = ">= 1.6.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.36"
    }
  }

  # Backend local pour démarrer — migrer vers S3 quand le bucket Scaleway sera créé.
  # Pour migrer : décommenter le bloc "backend s3" ci-dessous, commenter "backend local",
  # puis lancer : terraform init -migrate-state
  backend "local" {
    path = "terraform.tfstate"
  }

  # backend "s3" {
  #   bucket                      = "homelab-tfstate"
  #   key                         = "homelab/terraform.tfstate"
  #   region                      = "fr-par"
  #   endpoint                    = "https://s3.fr-par.scw.cloud"
  #   skip_credentials_validation = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  # }
}

provider "scaleway" {
  zone   = var.zone
  region = var.region
}
