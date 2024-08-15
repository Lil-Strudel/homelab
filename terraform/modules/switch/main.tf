terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

###############
# Switch Config
###############
resource "routeros_system_identity" "identity" {
  name = var.identity
}

#################
# Creating Bridge 
#################
resource "routeros_interface_bridge" "bridge" {
  name           = "bridge"
  vlan_filtering = true
}

#########################
# IP Addressing & Routing
#########################
resource "routeros_interface_vlan" "management_vlan" {
  interface = routeros_interface_bridge.bridge.name
  name      = "Management_VLAN"
  vlan_id   = var.management_vlan
}

resource "routeros_ip_address" "address" {
  address   = "${var.base_ip}.${var.management_vlan}.${var.ip_address}/24"
  interface = routeros_interface_vlan.management_vlan.name
}

resource "routeros_ip_route" "route" {
  distance = 1
  gateway  = "${var.base_ip}.${var.management_vlan}.1"
}

###################
# Configuring Ports
###################
module "trunk_ports" {
  source = "../trunk_ports"

  bridge     = routeros_interface_bridge.bridge.name
  vlans      = var.vlans
  interfaces = var.trunk_ports
}

module "access_ports" {
  source = "../access_ports"

  bridge       = routeros_interface_bridge.bridge.name
  access_ports = var.access_ports
}
