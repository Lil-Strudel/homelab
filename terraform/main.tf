terraform {
  backend "remote" {
    organization = "LilStrudel"
    workspaces {
      name = "homelab"
    }
  }
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

provider "routeros" {
  hosturl  = "10.69.100.1:6729"
  username = "terraform"
  password = "12345"
  insecure = true
}

provider "routeros" {
  hosturl  = "10.69.100.20:6729"
  username = "terraform"
  password = "12345"
  insecure = true
  alias    = "AccessPoint1"
}

module "router" {
  source = "./modules/router"
}

module "ap1" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.ap1
  }
}
