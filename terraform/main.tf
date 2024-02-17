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
  username = "admin"
  password = ""
  insecure = true
}

provider "routeros" {
  hosturl  = "10.69.100.20:6729"
  username = "admin"
  password = ""
  insecure = true
  alias    = "access_point_1"
}

module "router" {
  source             = "./modules/router"
  base_ip            = var.base_ip
  management_vlan_id = var.management_vlan_id
  vlans              = var.vlans
  wan_interface      = "ether1"
  trunk_ports        = ["ether2"]
  access_ports = {
    ether3 = {
      interface = "ether3"
      vlan      = "200"
    }
    ether4 = {
      interface = "ether4"
      vlan      = "100"
    }
    ether16 = {
      interface = "ether16"
      vlan      = "100"
    }
  }
}

module "access_point_1" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.access_point_1
  }

  name               = "Access_Point_1"
  base_ip            = var.base_ip
  management_vlan_id = var.management_vlan_id
  ip                 = "20"
  vlans              = var.vlans
  trunk_ports        = ["ether1"]
  access_ports = {
    ether2 = {
      interface = "ether2"
      vlan      = "100"
    }
    wifi1 = {
      interface = "wifi1"
      vlan      = "10"
    }
  }
}
