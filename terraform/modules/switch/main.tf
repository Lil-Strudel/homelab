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

resource "routeros_ip_dns" "dns" {
  servers               = ["${var.base_ip}.${var.management_vlan}.1"]
  allow_remote_requests = false # never an open resolver on Management
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

#################
# Service Hardening
#################
resource "routeros_ip_service" "disabled" {
  for_each = {
    "telnet"  = 23
    "ftp"     = 21
    "www"     = 80
    "api"     = 8728
    "api-ssl" = 8729
  }

  numbers  = each.key
  port     = each.value
  disabled = true
}

resource "routeros_ip_service" "ssh" {
  numbers = "ssh"
  port    = 22
  address = var.admin_sources
}

resource "routeros_ip_service" "winbox" {
  numbers = "winbox"
  port    = 8291
  address = var.admin_sources
}

# certificate must be declared: leaving it out strips the cert from the REST endpoint the
# provider uses, and the next apply cannot connect.
resource "routeros_ip_service" "www_ssl" {
  numbers     = "www-ssl"
  port        = 6729
  certificate = "tls-cert"
  tls_version = "only-1.2"
  address     = var.admin_sources
}

resource "routeros_ip_ssh_server" "ssh" {
  strong_crypto = true
  host_key_type = "ed25519"
}

resource "routeros_system_user_settings" "users" {
  minimum_password_length = 16
}

resource "routeros_tool_bandwidth_server" "btest" {
  enabled = false
}

resource "routeros_interface_list" "management_list" {
  name = "Management_List"
}

resource "routeros_interface_list_member" "management_list_member" {
  interface = routeros_interface_vlan.management_vlan.name
  list      = routeros_interface_list.management_list.name
}

resource "routeros_tool_mac_server" "mac_server" {
  allowed_interface_list = routeros_interface_list.management_list.name
}

resource "routeros_tool_mac_server_winbox" "mac_winbox" {
  allowed_interface_list = routeros_interface_list.management_list.name
}

resource "routeros_ip_neighbor_discovery_settings" "discovery" {
  discover_interface_list = routeros_interface_list.management_list.name
}
