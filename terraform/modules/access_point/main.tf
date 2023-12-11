terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

#####################
# Access Point Config
#####################

resource "routeros_system_identity" "identity" {
  name = var.name
}

##############
# Router Setup
##############

resource "routeros_interface_vlan" "vlan" {
  interface = routeros_interface_bridge.bridge.name
  name      = "Management_VLAN"
  vlan_id   = var.management_vlan_id
}

resource "routeros_ip_address" "address" {
  address   = "${var.base_ip}.${var.management_vlan_id}.${var.ip}/24"
  interface = routeros_interface_vlan.vlan.name
  network   = "${var.base_ip}.${var.management_vlan_id}.0"
}

resource "routeros_ip_route" "route" {
  distance = 1
  gateway  = "${var.base_ip}.${var.management_vlan_id}.1"
}

#################
# Creating Bridge
#################

resource "routeros_interface_bridge" "bridge" {
  name           = "bridge"
  vlan_filtering = true
  frame_types    = "admit-only-vlan-tagged"
}

###################
# Configuring Ports
###################

resource "routeros_interface_bridge_port" "trunk_bridge_port" {
  for_each = var.trunk_ports

  pvid              = 1
  bridge            = routeros_interface_bridge.bridge.name
  interface         = each.value
  frame_types       = "admit-only-vlan-tagged"
  ingress_filtering = true
}

resource "routeros_interface_bridge_vlan" "bridge_vlan" {
  for_each = var.vlans

  vlan_ids = each.value.id
  bridge   = routeros_interface_bridge.bridge.name
  tagged   = each.value.id == var.management_vlan_id ? concat(tolist(var.trunk_ports), [routeros_interface_bridge.bridge.name]) : var.trunk_ports
}

resource "routeros_interface_bridge_port" "access_bridge_port" {
  for_each = var.access_ports

  pvid              = each.value.vlan
  bridge            = routeros_interface_bridge.bridge.name
  interface         = each.value.interface
  frame_types       = "admit-only-untagged-and-priority-tagged"
  ingress_filtering = true
}

