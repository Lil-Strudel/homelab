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
  hosturl  = "192.168.1.21:6729"
  username = "admin"
  password = "1234"
  insecure = true
}

module "router" {
  source             = "./modules/router"
  base_ip            = var.base_ip
  management_vlan_id = var.management_vlan_id
  vlans              = var.vlans
  wan_interface      = "ether1"
  trunk_ports        = ["ether2"]
  access_ports = [{
    interface = "ether3"
    vlan      = "100"
  }]
}

