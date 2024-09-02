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
      version = "1.61.2"
    }
  }
}

locals {
  envs = { for tuple in regexall("(.*)=(.*)", file(".env")) : tuple[0] => sensitive(tuple[1]) }
  vlans = {
    Home       = 10,
    Guest      = 20,
    Security   = 30,
    IoT        = 40,
    DMZ        = 50,
    Trusted    = 60,
    Management = 100,
    Dad        = 200,
  }
  base_ip = "10.69"
}

provider "routeros" {
  hosturl  = "10.69.100.1:6729"
  username = local.envs["ROUTEROS_USERNAME"]
  password = local.envs["ROUTEROS_PASSWORD"]
  insecure = true
  alias    = "ccr2004"
}

provider "routeros" {
  hosturl  = "10.69.100.10:6729"
  username = local.envs["ROUTEROS_USERNAME"]
  password = local.envs["ROUTEROS_PASSWORD"]
  insecure = true
  alias    = "crs326"
}

provider "routeros" {
  hosturl  = "10.69.100.11:6729"
  username = local.envs["ROUTEROS_USERNAME"]
  password = local.envs["ROUTEROS_PASSWORD"]
  insecure = true
  alias    = "crs312"
}

provider "routeros" {
  hosturl  = "10.69.100.20:6729"
  username = local.envs["ROUTEROS_USERNAME"]
  password = local.envs["ROUTEROS_PASSWORD"]
  insecure = true
  alias    = "cAPax-1"
}

provider "routeros" {
  hosturl  = "10.69.100.21:6729"
  username = local.envs["ROUTEROS_USERNAME"]
  password = local.envs["ROUTEROS_PASSWORD"]
  insecure = true
  alias    = "cAPax-2"
}

module "router" {
  source = "./modules/router"
  providers = {
    routeros = routeros.ccr2004
  }

  identity      = "router"
  wan_interface = "ether1"

  base_ip = local.base_ip

  vlans = local.vlans

  trunk_ports = ["ether2", "ether3", "ether4"]
  access_ports = {
    "ether5"  = local.vlans["Management"]
    "ether6"  = local.vlans["Management"]
    "ether7"  = local.vlans["Management"]
    "ether8"  = local.vlans["Management"]
    "ether9"  = local.vlans["Dad"]
    "ether10" = local.vlans["Dad"]
    "ether11" = local.vlans["Dad"]
    "ether12" = local.vlans["Dad"]
  }
}

module "core_switch" {
  source = "./modules/switch"
  providers = {
    routeros = routeros.crs326
  }

  identity = "core_switch"

  base_ip    = local.base_ip
  ip_address = "10"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["sfp-sfpplus24"]
  access_ports = {
    sfp-sfpplus1  = local.vlans["Trusted"]
    sfp-sfpplus3  = local.vlans["Trusted"]
    sfp-sfpplus9  = local.vlans["Trusted"]
    sfp-sfpplus11 = local.vlans["Trusted"]
    sfp-sfpplus17 = local.vlans["Trusted"]
    sfp-sfpplus19 = local.vlans["Trusted"]
  }
}

module "ethernet_switch" {
  source = "./modules/switch"
  providers = {
    routeros = routeros.crs312
  }

  identity = "ethernet_switch"

  base_ip    = local.base_ip
  ip_address = "11"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["ether1", "combo1"]
  access_ports = {
    ether2 = local.vlans["Management"]
    ether3 = local.vlans["Management"]
    ether4 = local.vlans["Management"]
    ether5 = local.vlans["Trusted"]
    ether6 = local.vlans["Trusted"]
    ether7 = local.vlans["Trusted"]
    ether8 = local.vlans["Trusted"]
  }
}

module "wifi_config" {
  source = "./modules/wifi_config"
  providers = {
    routeros = routeros.cAPax-1
  }

  ssid       = "Strudel"
  passphrase = local.envs["WIFI1_PASSWORD"]
}

module "access_point_1" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.cAPax-1
  }

  capsman_role = "manager"

  identity = "access_point_1"

  base_ip    = local.base_ip
  ip_address = "20"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["ether1"]
  access_ports = {
    ether2 = local.vlans["Management"]
    wifi1  = local.vlans["Management"]
    wifi2  = local.vlans["Management"]
  }
}

module "access_point_2" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.cAPax-2
  }

  depends_on   = [module.access_point_1]
  capsman_role = "client"

  identity = "access_point_2"

  base_ip    = local.base_ip
  ip_address = "21"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["ether1"]
  access_ports = {
    wifi1 = local.vlans["Management"]
    wifi2 = local.vlans["Management"]
  }
}
