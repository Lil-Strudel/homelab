terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

locals {
  bridge_vlans = flatten([
    for vlan_key, vlan in var.vlans : [
      for trunk_port in var.trunk_ports : {
        vlan       = vlan
        trunk_port = trunk_port
      }
    ]
  ])
}

resource "routeros_system_identity" "identity" {
  name = "Router"
}

resource "routeros_interface_bridge" "bridge" {
  name           = "bridge"
  vlan_filtering = true
  frame_types    = "admit-only-vlan-tagged"
}

resource "routeros_interface_list" "wan_list" {
  name = "WAN"
}

resource "routeros_interface_list" "vlan_list" {
  name = "VLAN"
}

resource "routeros_interface_list" "management_list" {
  name = "Management"
}

module "vlan" {
  source   = "../vlan"
  for_each = var.vlans

  bridge     = routeros_interface_bridge.bridge.name
  id         = each.value.id
  name       = each.value.name
  base_ip    = var.base_ip
  dns_server = "${var.base_ip}.${var.management_vlan_id}.1"
}

module "firewall_rules" {
  source = "../router_firewall_rules"
}

resource "routeros_interface_list_member" "wan_list_member" {
  interface = var.wan_interface
  list      = routeros_interface_list.wan_list.name
}

resource "routeros_interface_list_member" "management_list_member" {
  interface = "Management_VLAN"
  list      = routeros_interface_list.management_list.name
}

resource "routeros_interface_list_member" "vlan_list_member" {
  for_each = var.vlans

  interface = "${each.value.name}_VLAN"
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_bridge_port" "trunk_bridge_port" {
  for_each = var.trunk_ports

  pvid        = 1
  bridge      = routeros_interface_bridge.bridge.name
  interface   = each.value
  frame_types = "admit-only-vlan-tagged"
}

resource "routeros_interface_bridge_vlan" "bridge_vlan" {
  for_each = {
    for bridge_vlan in local.bridge_vlans : "${bridge_vlan.vlan.name}_VLAN.${bridge_vlan.trunk_port}" => bridge_vlan
  }

  vlan_ids = each.value.vlan.id
  bridge   = routeros_interface_bridge.bridge.name
  tagged = [
    routeros_interface_bridge.bridge.name,
    each.value.trunk_port
  ]
}

resource "routeros_dns" "dns-server" {
  allow_remote_requests = true
  servers               = "9.9.9.9,149.112.112.112"
}

resource "routeros_ip_dhcp_client" "dhcp_client" {
  interface = var.wan_interface
}

resource "routeros_ip_firewall_nat" "nat_rule" {
  action             = "masquerade"
  chain              = "srcnat"
  out_interface_list = routeros_interface_list.wan_list.name
}
