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

resource "routeros_ip_dns_record" "static" {
  for_each = var.dns_records

  name    = each.key
  address = each.value
  type    = "A"
  ttl     = "5m"
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

############
# WireGuard
############
resource "routeros_interface_wireguard" "wg_home" {
  name        = "wg-home"
  listen_port = var.wg_home_port
  private_key = var.wg_home_private_key
  comment     = "Home VPN (personal / trusted devices)"
}

resource "routeros_ip_address" "wg_home" {
  interface = routeros_interface_wireguard.wg_home.name
  address   = "10.69.70.1/24"
}

resource "routeros_interface_wireguard_peer" "wg_home" {
  for_each = var.wg_home_peers

  interface       = routeros_interface_wireguard.wg_home.name
  public_key      = each.value.public_key
  preshared_key   = each.value.preshared_key
  allowed_address = [each.value.address]
  is_responder    = true
  client_address  = each.value.address
  client_dns      = "10.69.70.1"
}

resource "routeros_interface_wireguard" "wg_management" {
  name        = "wg-management"
  listen_port = var.wg_management_port
  private_key = var.wg_management_private_key
  comment     = "Management VPN (admin)"
}

resource "routeros_ip_address" "wg_management" {
  interface = routeros_interface_wireguard.wg_management.name
  address   = "10.69.80.1/24"
}

resource "routeros_interface_wireguard_peer" "wg_management" {
  for_each = var.wg_management_peers

  interface       = routeros_interface_wireguard.wg_management.name
  public_key      = each.value.public_key
  preshared_key   = each.value.preshared_key
  allowed_address = [each.value.address]
  is_responder    = true
  client_address  = each.value.address
  client_dns      = "10.69.80.1"
}

###################################
# Interface Lists For Firewall Rules
###################################
resource "routeros_interface_list" "wan_list" {
  name = "WAN_List"
}
resource "routeros_interface_list_member" "wan_list_member" {
  interface = var.wan_interface
  list      = routeros_interface_list.wan_list.name
}

# Every VLAN interface, plus the WireGuard tunnels — used by the router-service (DHCP/DNS/NTP) input rules.
resource "routeros_interface_list" "vlan_list" {
  name = "VLAN_List"
}
resource "routeros_interface_list_member" "vlan_list_member" {
  for_each = var.vlans

  interface = "${each.key}_VLAN"
  list      = routeros_interface_list.vlan_list.name
}
resource "routeros_interface_list_member" "vlan_list_member_wg" {
  for_each = toset([routeros_interface_wireguard.wg_home.name, routeros_interface_wireguard.wg_management.name])

  interface = each.value
  list      = routeros_interface_list.vlan_list.name
}

# Management only. MAC-telnet / MAC-Winbox stay available as a recovery path when IP
# routing is broken, but only from the segment that already has full router access.
resource "routeros_interface_list" "management_list" {
  name = "Management_List"
}
resource "routeros_interface_list_member" "management_list_member" {
  interface = "Management_VLAN"
  list      = routeros_interface_list.management_list.name
}

# VLANs allowed to reach the internet. Security + IoT are intentionally excluded.
resource "routeros_interface_list" "internet_list" {
  name = "Internet_List"
}
resource "routeros_interface_list_member" "internet_list_member" {
  for_each = toset(var.internet_vlans)

  interface = "${each.key}_VLAN"
  list      = routeros_interface_list.internet_list.name
}
resource "routeros_interface_list_member" "internet_list_member_wg" {
  for_each = toset([routeros_interface_wireguard.wg_home.name, routeros_interface_wireguard.wg_management.name])

  interface = each.value
  list      = routeros_interface_list.internet_list.name
}

######################
# Input Firewall Rules
######################
resource "routeros_ip_firewall_filter" "input_wireguard" {
  chain             = "input"
  action            = "accept"
  protocol          = "udp"
  dst_port          = "${var.wg_home_port},${var.wg_management_port}"
  in_interface_list = routeros_interface_list.wan_list.name
  comment           = "Allow WireGuard from WAN"
  place_before      = routeros_ip_firewall_filter.input_established.id
}

resource "routeros_ip_firewall_filter" "input_established" {
  chain            = "input"
  action           = "accept"
  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before     = routeros_ip_firewall_filter.input_icmp.id
}

resource "routeros_ip_firewall_filter" "input_icmp" {
  chain        = "input"
  action       = "accept"
  protocol     = "icmp"
  comment      = "Allow ICMP"
  place_before = routeros_ip_firewall_filter.input_dhcp.id
}

resource "routeros_ip_firewall_filter" "input_dhcp" {
  chain             = "input"
  action            = "accept"
  protocol          = "udp"
  dst_port          = "67"
  in_interface_list = routeros_interface_list.vlan_list.name
  comment           = "Allow DHCP from all VLANs"
  place_before      = routeros_ip_firewall_filter.input_dns_udp.id
}

resource "routeros_ip_firewall_filter" "input_dns_udp" {
  chain             = "input"
  action            = "accept"
  protocol          = "udp"
  dst_port          = "53"
  in_interface_list = routeros_interface_list.vlan_list.name
  comment           = "Allow DNS (UDP) from all VLANs"
  place_before      = routeros_ip_firewall_filter.input_dns_tcp.id
}

resource "routeros_ip_firewall_filter" "input_dns_tcp" {
  chain             = "input"
  action            = "accept"
  protocol          = "tcp"
  dst_port          = "53"
  in_interface_list = routeros_interface_list.vlan_list.name
  comment           = "Allow DNS (TCP) from all VLANs"
  place_before      = routeros_ip_firewall_filter.input_ntp.id
}

resource "routeros_ip_firewall_filter" "input_ntp" {
  chain             = "input"
  action            = "accept"
  protocol          = "udp"
  dst_port          = "123"
  in_interface_list = routeros_interface_list.vlan_list.name
  comment           = "Allow NTP from all VLANs"
  place_before      = routeros_ip_firewall_filter.input_bgp.id
}

resource "routeros_ip_firewall_filter" "input_bgp" {
  chain        = "input"
  action       = "accept"
  protocol     = "tcp"
  dst_port     = "179"
  in_interface = "Trusted_VLAN"
  comment      = "Allow BGP peering from cluster nodes"
  place_before = routeros_ip_firewall_filter.input_management.id
}

resource "routeros_ip_firewall_filter" "input_management" {
  chain        = "input"
  action       = "accept"
  in_interface = "Management_VLAN"
  comment      = "Allow Management VLAN full router access"
  place_before = routeros_ip_firewall_filter.input_wg_management.id
}

resource "routeros_ip_firewall_filter" "input_wg_management" {
  chain        = "input"
  action       = "accept"
  in_interface = routeros_interface_wireguard.wg_management.name
  comment      = "Allow Management VPN full router access"
  place_before = routeros_ip_firewall_filter.input_drop.id
}

resource "routeros_ip_firewall_filter" "input_drop" {
  chain    = "input"
  action   = "drop"
  comment  = "Drop All Input (staged: enforce_firewall)"
  disabled = !var.enforce_firewall
}

########################
# Forward Firewall Rules
########################
resource "routeros_ip_firewall_filter" "forward_established" {
  chain            = "forward"
  action           = "accept"
  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before     = routeros_ip_firewall_filter.forward_internet.id
}

resource "routeros_ip_firewall_filter" "forward_internet" {
  chain              = "forward"
  action             = "accept"
  in_interface_list  = routeros_interface_list.internet_list.name
  out_interface_list = routeros_interface_list.wan_list.name
  comment            = "Internet access (excludes Security + IoT)"
  place_before       = routeros_ip_firewall_filter.forward_home_services.id
}

# Matched on dst-address, not out-interface: service IPs are BGP /32s whose next hop is a
# Trusted-VLAN node, so these packets leave via Trusted_VLAN. Matching the interface would
# also expose the nodes themselves — the Talos API, the kube API, and the Zigbee Pi.
resource "routeros_ip_firewall_filter" "forward_home_services" {
  chain        = "forward"
  action       = "accept"
  in_interface = "Home_VLAN"
  dst_address  = var.services_cidr
  comment      = "Home -> Services"
  place_before = routeros_ip_firewall_filter.forward_management_all.id
}

resource "routeros_ip_firewall_filter" "forward_management_all" {
  chain              = "forward"
  action             = "accept"
  in_interface       = "Management_VLAN"
  out_interface_list = routeros_interface_list.vlan_list.name
  comment            = "Management -> all VLANs"
  place_before       = routeros_ip_firewall_filter.forward_wg_home_home.id
}

resource "routeros_ip_firewall_filter" "forward_wg_home_home" {
  chain         = "forward"
  action        = "accept"
  in_interface  = routeros_interface_wireguard.wg_home.name
  out_interface = "Home_VLAN"
  comment       = "Home VPN -> Home"
  place_before  = routeros_ip_firewall_filter.forward_wg_home_services.id
}

resource "routeros_ip_firewall_filter" "forward_wg_home_services" {
  chain        = "forward"
  action       = "accept"
  in_interface = routeros_interface_wireguard.wg_home.name
  dst_address  = var.services_cidr
  comment      = "Home VPN -> Services"
  place_before = routeros_ip_firewall_filter.forward_wg_management.id
}

resource "routeros_ip_firewall_filter" "forward_wg_management" {
  chain              = "forward"
  action             = "accept"
  in_interface       = routeros_interface_wireguard.wg_management.name
  out_interface_list = routeros_interface_list.vlan_list.name
  comment            = "Management VPN -> all VLANs"
  place_before       = routeros_ip_firewall_filter.forward_drop.id
}

resource "routeros_ip_firewall_filter" "forward_drop" {
  chain    = "forward"
  action   = "drop"
  comment  = "Drop All Forward (staged: enforce_firewall)"
  disabled = !var.enforce_firewall
}

#################
# Service Hardening
#################
# Only the services being switched off are declared. winbox (8291), ssh, and www-ssl
# (6729, the REST endpoint every provider alias uses) are deliberately left unmanaged —
# declaring www-ssl without its certificate attribute would strip the cert and break
# every subsequent apply.
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

resource "routeros_tool_bandwidth_server" "btest" {
  enabled = false
}

resource "routeros_ip_settings" "hardening" {
  accept_redirects    = false
  accept_source_route = false
  tcp_syncookies      = true
  rp_filter           = "loose" # not strict: BGP + the kube-vip VIP make return paths asymmetric
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

####################
# Raw (pre-conntrack)
####################
# The raw table drops before connection tracking, so scan and flood traffic costs no
# conntrack state. Reputation and geo lists land here once the edge host feeds them.
resource "routeros_ip_firewall_raw" "wan_dns_drop" {
  chain             = "prerouting"
  action            = "drop"
  protocol          = "udp"
  dst_port          = "53"
  in_interface_list = routeros_interface_list.wan_list.name
  comment           = "Never answer DNS from WAN (the resolver has allow-remote-requests on)"
  place_before      = routeros_ip_firewall_raw.wan_icmp_limit.id
}

# Order is load-bearing: the accept must precede the drop, or every ICMP packet from the
# WAN is discarded rather than just the excess — which black-holes PMTUD.
resource "routeros_ip_firewall_raw" "wan_icmp_limit" {
  chain             = "prerouting"
  action            = "accept"
  protocol          = "icmp"
  limit             = "10,20:packet"
  in_interface_list = routeros_interface_list.wan_list.name
  comment           = "Rate-limit ICMP from WAN"
  place_before      = routeros_ip_firewall_raw.wan_icmp_drop.id
}

resource "routeros_ip_firewall_raw" "wan_icmp_drop" {
  chain             = "prerouting"
  action            = "drop"
  protocol          = "icmp"
  in_interface_list = routeros_interface_list.wan_list.name
  comment           = "Drop ICMP from WAN above the rate limit"
}

###################
# Static DHCP Leases
###################
resource "routeros_ip_dhcp_server_lease" "lease" {
  for_each = var.dhcp_leases

  address     = each.value.address
  mac_address = each.value.mac_address
  server      = each.value.server
  client_id   = each.value.client_id
}

#############
# BGP Peering
#############
resource "routeros_routing_bgp_connection" "peer" {
  for_each = var.bgp_peers

  as            = "65100"
  name          = each.key
  router_id     = "10.69.60.1"
  routing_table = "main"

  local {
    role = "ebgp"
  }

  remote {
    address = "${each.value}/32"
    as      = "65000"
  }

  output {
    default_originate = "always"
  }
}
