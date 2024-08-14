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
      version = "1.59.4"
    }
  }
}

provider "routeros" {
  hosturl  = "10.69.100.1:6729"
  username = "admin"
  password = "1234"
  insecure = true
}

provider "routeros" {
  hosturl  = "10.69.100.10:6729"
  username = "admin"
  password = "1234"
  insecure = true
  alias    = "switch_1"
}

provider "routeros" {
  hosturl  = "10.69.100.20:6729"
  username = "admin"
  password = "1234"
  insecure = true
  alias    = "access_point_1"
}


module "router" {
  source             = "./modules/router"
  base_ip            = var.base_ip
  management_vlan_id = var.management_vlan_id
  vlans              = var.vlans
  wan_interface      = "ether1"
  trunk_ports        = ["ether2", "ether4"]
  access_ports = {
    ether3 = {
      interface            = "ether3"
      default_vlan         = "200"
      allowed_tagged_vlans = []
    }
    ether16 = {
      interface            = "ether16"
      default_vlan         = "100"
      allowed_tagged_vlans = []
    }
  }
}

module "switch_1" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.switch_1
  }

  name               = "Switch_1"
  base_ip            = var.base_ip
  management_vlan_id = var.management_vlan_id
  ip                 = "10"
  vlans              = var.vlans
  trunk_ports        = ["ether8"]
  access_ports = {
    ether1 = {
      interface = "ether1"
      vlan      = "60"
    }
    ether2 = {
      interface = "ether2"
      vlan      = "60"
    }
    ether3 = {
      interface = "ether3"
      vlan      = "60"
    }
    ether4 = {
      interface = "ether4"
      vlan      = "60"
    }
    ether5 = {
      interface = "ether5"
      vlan      = "60"
    }
    ether6 = {
      interface = "ether6"
      vlan      = "60"
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

