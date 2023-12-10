terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

resource "routeros_interface_bridge" "bridge" {
  name = "local"
}

resource "routeros_interface_bridge_port" "bridge_port" {
  bridge    = routeros_interface_bridge.bridge.name
  interface = "ether2"
  pvid      = "1"
}

resource "routeros_ip_address" "address" {
  address   = "10.69.100.20/24"
  interface = routeros_interface_bridge.bridge.name
}

resource "routeros_ip_pool" "mgmt_pool" {
  name   = "mgmt_dhcp_pool"
  ranges = ["10.69.100.2-10.69.100.254"]
}

resource "routeros_ip_dhcp_server" "dhcp_server" {
  address_pool = routeros_ip_pool.mgmt_pool.name
  interface    = routeros_interface_bridge.bridge.name
  name         = "mgmt_dhcp_server"
  lease_time   = "10m"
}

resource "routeros_ip_dhcp_server_network" "dhcp_server_network" {
  address    = "10.69.100.0/24"
  gateway    = "10.69.100.1"
  dns_server = "8.8.8.8"
}

resource "routeros_ip_dhcp_client" "dhcp_client" {
  interface = "ether1"
}

resource "routeros_ip_firewall_nat" "nat_rule" {
  action        = "masquerade"
  chain         = "srcnat"
  out_interface = "ether1"
}

resource "routeros_system_certificate" "root_cert" {
  name        = "root-cert"
  common_name = "root-cert"
  key_usage   = ["key-cert-sign", "crl-sign"]
  trusted     = true
  key_size    = 4096
  days_valid  = 3650
  sign {
  }
}

resource "routeros_system_certificate" "tls_cert" {
  name        = "tls-cert"
  common_name = "tls-cert"
  key_size    = 4096
  days_valid  = 3650
  key_usage   = ["digital-signature", "key-agreement", "tls-server"]
  sign {
    ca = routeros_system_certificate.root_cert.name
  }
}

locals {
  tls_service     = { "www-ssl" = 6729 }
  disable_service = { "api" = 8728, "api-ssl" = 8729, "ftp" = 21, "telnet" = 23, "www" = 80 }
  enable_service  = { "ssh" = 9623, "winbox" = 9712 }
}

resource "routeros_ip_service" "tls_services" {
  for_each    = local.tls_service
  numbers     = each.key
  port        = each.value
  certificate = routeros_system_certificate.tls_cert.name
  tls_version = "only-1.2"
  disabled    = false
}

resource "routeros_ip_service" "disabled_services" {
  for_each = local.disable_service
  numbers  = each.key
  port     = each.value
  disabled = true
}

resource "routeros_ip_service" "enabled_services" {
  for_each = local.enable_service
  numbers  = each.key
  port     = each.value
  disabled = false
}

resource "routeros_system_user" "strudel_user" {
  name     = "strudel"
  group    = "full"
  password = "12345"
}

resource "routeros_system_user" "terraform_user" {
  name     = "terraform"
  group    = "full"
  password = "12345"
}
