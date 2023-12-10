terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

locals {
  start_ip = "${var.base_ip}.${var.id}"
}

resource "routeros_interface_vlan" "vlan" {
  interface = var.bridge
  name      = "${var.name}_VLAN"
  vlan_id   = var.id
}

resource "routeros_ip_address" "address" {
  address   = "${local.start_ip}.1/24"
  interface = routeros_interface_vlan.vlan.name
  network   = "${local.start_ip}.0"
}

resource "routeros_ip_pool" "pool" {
  name   = "${var.name}_DHCP_Pool"
  ranges = ["${local.start_ip}.2-${local.start_ip}.254"]
}

resource "routeros_ip_dhcp_server" "dhcp_server" {
  address_pool = routeros_ip_pool.pool.name
  interface    = routeros_interface_vlan.vlan.name
  name         = "${var.name}_DHCP_Server"
}

resource "routeros_ip_dhcp_server_network" "dhcp_server_network" {
  address    = "${local.start_ip}.0/24"
  gateway    = "${local.start_ip}.1"
  dns_server = var.dns_server
}
