terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

###############
# Router Config
###############
resource "routeros_system_identity" "identity" {
  name = var.identity
}

#################
# Internet Access
#################
resource "routeros_ip_dhcp_client" "dhcp_client" {
  interface = var.wan_interface
}

resource "routeros_ip_dns" "dns-server" {
  allow_remote_requests = true
  servers = [
    "9.9.9.9", "149.112.112.112",
    "8.8.8.8", "1.1.1.1"
  ]
}

resource "routeros_ip_firewall_nat" "nat_rule" {
  action        = "masquerade"
  chain         = "srcnat"
  out_interface = var.wan_interface
  comment       = "Masquerade internal traffic"
}

#################
# Creating Bridge 
#################
resource "routeros_interface_bridge" "bridge" {
  name           = "bridge"
  vlan_filtering = true
}

################
# Creating VLANS
################
module "vlan" {
  source   = "../vlan"
  for_each = var.vlans

  bridge  = routeros_interface_bridge.bridge.name
  name    = each.key
  id      = each.value
  base_ip = var.base_ip
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


###################################
# Creating Lists For Firewall Rules
###################################
resource "routeros_interface_list" "wan_list" {
  name = "WAN_List"
}
resource "routeros_interface_list_member" "wan_list_member" {
  interface = var.wan_interface
  list      = routeros_interface_list.wan_list.name
}

resource "routeros_interface_list" "management_list" {
  name = "Management_List"
}
resource "routeros_interface_list_member" "management_list_member" {
  interface = "Management_VLAN"
  list      = routeros_interface_list.management_list.name
}

resource "routeros_interface_list" "vlan_list" {
  name = "VLAN_List"
}
resource "routeros_interface_list_member" "vlan_list_member" {
  for_each = var.vlans

  interface = "${each.key}_VLAN"
  list      = routeros_interface_list.vlan_list.name
}

######################
# Input Firewall Rules
######################
resource "routeros_ip_firewall_filter" "input_established" {
  chain  = "input"
  action = "accept"

  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before     = routeros_ip_firewall_filter.input_vlan.id
}

resource "routeros_ip_firewall_filter" "input_vlan" {
  chain  = "input"
  action = "accept"

  in_interface_list = routeros_interface_list.vlan_list.name
  comment           = "Allow All VLANs Full Access"
  place_before      = routeros_ip_firewall_filter.input_management.id
}

resource "routeros_ip_firewall_filter" "input_management" {
  chain  = "input"
  action = "accept"

  in_interface = "Management_VLAN"
  comment      = "Allow Management VLAN Full Access"
  place_before = routeros_ip_firewall_filter.input_drop.id
}

resource "routeros_ip_firewall_filter" "input_drop" {
  chain  = "input"
  action = "drop"

  comment      = "Drop All Input"
  place_before = routeros_ip_firewall_filter.forward_established.id
  disabled     = false
}

########################
# Forward Firewall Rules
########################
resource "routeros_ip_firewall_filter" "forward_established" {
  chain  = "forward"
  action = "accept"

  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before     = routeros_ip_firewall_filter.forward_vlan_wan.id
}

resource "routeros_ip_firewall_filter" "forward_vlan_wan" {
  chain  = "forward"
  action = "accept"

  in_interface_list  = routeros_interface_list.vlan_list.name
  out_interface_list = routeros_interface_list.wan_list.name
  comment            = "VLAN Internet Access"
  place_before       = routeros_ip_firewall_filter.forward_vlan_vlan.id
}

resource "routeros_ip_firewall_filter" "forward_vlan_vlan" {
  chain  = "forward"
  action = "accept"

  in_interface_list  = routeros_interface_list.vlan_list.name
  out_interface_list = routeros_interface_list.vlan_list.name
  comment            = "VLAN to VLAN Traffic (aka make vlans fucking pointless)"
  place_before       = routeros_ip_firewall_filter.forward_drop.id
}

resource "routeros_ip_firewall_filter" "forward_drop" {
  chain  = "forward"
  action = "drop"

  comment  = "Drop All Forward"
  disabled = false
}
