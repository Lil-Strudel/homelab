terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

module "base" {
  source = "../switch"

  identity        = var.identity
  base_ip         = var.base_ip
  ip_address      = var.ip_address
  vlans           = var.vlans
  management_vlan = var.management_vlan
  admin_sources   = var.admin_sources
  trunk_ports     = var.trunk_ports
  access_ports    = var.access_ports
}

###################
# Manager Resources
###################
resource "routeros_wifi_capsman" "capsman" {
  count = var.capsman_role == "manager" ? 1 : 0

  enabled        = true
  interfaces     = [module.base.management_interface]
  ca_certificate = "auto"
  certificate    = "auto"
  upgrade_policy = "require-same-version"
}

# CAPsMAN cannot manage its own radios, so the manager binds the same profiles locally.
resource "routeros_wifi" "manager_radio" {
  for_each = var.capsman_role == "manager" ? var.radio_configurations : {}

  name     = each.key
  disabled = false
  configuration = {
    config = each.value
  }
}

###################
# Client Resources
###################
resource "routeros_wifi_datapath" "cap" {
  count = var.capsman_role == "client" ? 1 : 0

  name   = "capdp"
  bridge = module.base.bridge
}

resource "routeros_wifi_cap" "cap" {
  count = var.capsman_role == "client" ? 1 : 0

  enabled              = true
  discovery_interfaces = [module.base.management_interface]
  slaves_datapath      = routeros_wifi_datapath.cap[0].name
}

resource "routeros_wifi" "cap_radio" {
  for_each = var.capsman_role == "client" ? toset(["wifi1", "wifi2"]) : toset([])

  name     = each.key
  disabled = false
  configuration = {
    manager = "capsman"
  }
  datapath = {
    config = routeros_wifi_datapath.cap[0].name
  }
}
