terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

###############
# Router Config
###############

resource "routeros_system_identity" "identity" {
  name = "Router"
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

###########################
# Creating Bridge and VLANS
###########################

resource "routeros_interface_bridge" "bridge" {
  name           = "bridge"
  vlan_filtering = true
  frame_types    = "admit-only-vlan-tagged"
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


#####################
# Grouping Into Lists
#####################

resource "routeros_interface_list" "wan_list" {
  name = "WAN"
}

resource "routeros_interface_list" "vlan_list" {
  name = "VLAN"
}

resource "routeros_interface_list" "management_list" {
  name = "Management"
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
  tagged   = concat(tolist(var.trunk_ports), [routeros_interface_bridge.bridge.name])
}

resource "routeros_interface_bridge_port" "access_bridge_port" {
  for_each = var.access_ports

  pvid              = each.value.vlan
  bridge            = routeros_interface_bridge.bridge.name
  interface         = each.value.interface
  frame_types       = "admit-only-untagged-and-priority-tagged"
  ingress_filtering = true
}

################
# Firewall Rules
################

resource "routeros_ip_firewall_filter" "rule_1" {
  action           = "accept"
  chain            = "input"
  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before     = routeros_ip_firewall_filter.rule_2.id
}

resource "routeros_ip_firewall_filter" "rule_2" {
  action       = "accept"
  chain        = "input"
  in_interface = "Management_VLAN"
  comment      = "Allow Management VLAN"
  place_before = routeros_ip_firewall_filter.rule_3.id
}

resource "routeros_ip_firewall_filter" "rule_3" {
  action       = "drop"
  chain        = "input"
  comment      = "Drop"
  disabled     = true
  place_before = routeros_ip_firewall_filter.rule_4.id
}

resource "routeros_ip_firewall_filter" "rule_4" {
  action           = "accept"
  chain            = "forward"
  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before     = routeros_ip_firewall_filter.rule_5.id
}

resource "routeros_ip_firewall_filter" "rule_5" {
  action             = "accept"
  chain              = "forward"
  in_interface_list  = "VLAN"
  out_interface_list = "WAN"
  comment            = "VLAN Internet Access"
  place_before       = routeros_ip_firewall_filter.rule_6.id
}

resource "routeros_ip_firewall_filter" "rule_6" {
  action   = "drop"
  chain    = "forward"
  disabled = true
  comment  = "Drop"
}
