terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

resource "routeros_system_identity" "identity" {
  name = "Router"
}

resource "routeros_interface_bridge" "bridge" {
  name           = "bridge"
  vlan_filtering = true
  frame_types = "admit-only-vlan-tagged"
}

resource "routeros_interface_vlan" "home_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "Home_VLAN"
  vlan_id   = 10
}

resource "routeros_interface_vlan" "guest_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "Guest_VLAN"
  vlan_id   = 20
}

resource "routeros_interface_vlan" "security_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "Security_VLAN"
  vlan_id   = 30
}

resource "routeros_interface_vlan" "iot_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "IoT_VLAN"
  vlan_id   = 40
}

resource "routeros_interface_vlan" "dmz_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "DMZ_VLAN"
  vlan_id   = 50
}

resource "routeros_interface_vlan" "trusted_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "Trusted_VLAN"
  vlan_id   = 60
}

resource "routeros_interface_vlan" "management_vlan" {
  interface =routeros_interface_bridge.bridge.name 
  name      = "Management_VLAN"
  vlan_id   = 100
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

resource "routeros_interface_list_member" "wan_member" {
  interface = "ether1"
  list      = routeros_interface_list.wan_list.name
}

resource "routeros_interface_list_member" "management_member" {
  interface = routeros_interface_vlan.management_vlan.name
  list      = routeros_interface_list.wan_list.name
}

resource "routeros_interface_list_member" "home_vlan_member" {
  interface = routeros_interface_vlan.home_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_list_member" "guest_vlan_member" {
  interface = routeros_interface_vlan.guest_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_list_member" "security_vlan_member" {
  interface = routeros_interface_vlan.security_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_list_member" "iot_vlan_member" {
  interface = routeros_interface_vlan.iot_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_list_member" "dmz_vlan_member" {
  interface = routeros_interface_vlan.dmz_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_list_member" "trusted_vlan_member" {
  interface = routeros_interface_vlan.trusted_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_interface_list_member" "management_vlan_member" {
  interface = routeros_interface_vlan.management_vlan.name
  list      = routeros_interface_list.vlan_list.name
}

resource "routeros_ip_address" "home_address" {
  address   = "10.69.10.1/24"
  interface = routeros_interface_vlan.home_vlan.name
  network   = "10.69.10.0"
}

resource "routeros_ip_address" "guest_address" {
  address   = "10.69.20.1/24"
  interface = routeros_interface_vlan.guest_vlan.name
  network   = "10.69.20.0"
}

resource "routeros_ip_address" "security_address" {
  address   = "10.69.30.1/24"
  interface = routeros_interface_vlan.security_vlan.name
  network   = "10.69.30.0"
}

resource "routeros_ip_address" "iot_address" {
  address   = "10.69.40.1/24"
  interface = routeros_interface_vlan.iot_vlan.name
  network   = "10.69.40.0"
}

resource "routeros_ip_address" "dmz_address" {
  address   = "10.69.50.1/24"
  interface = routeros_interface_vlan.dmz_vlan.name
  network   = "10.69.50.0"
}

resource "routeros_ip_address" "trusted_address" {
  address   = "10.69.60.1/24"
  interface = routeros_interface_vlan.trusted_vlan.name
  network   = "10.69.60.0"
}

resource "routeros_ip_address" "management_address" {
  address   = "10.69.100.1/24"
  interface = routeros_interface_vlan.management_vlan.name
  network   = "10.69.100.0"
}

resource "routeros_ip_pool" "home_pool" {
  name   = "Home_DHCP_Pool"
  ranges = ["10.69.10.2-10.69.10.254"]
}

resource "routeros_ip_pool" "guest_pool" {
  name   = "Guest_DHCP_Pool"
  ranges = ["10.69.20.2-10.69.20.254"]
}

resource "routeros_ip_pool" "security_pool" {
  name   = "Security_DHCP_Pool"
  ranges = ["10.69.30.2-10.69.30.254"]
}

resource "routeros_ip_pool" "iot_pool" {
  name   = "IoT_DHCP_Pool"
  ranges = ["10.69.40.2-10.69.40.254"]
}

resource "routeros_ip_pool" "dmz_pool" {
  name   = "DMZ_DHCP_Pool"
  ranges = ["10.69.50.2-10.69.50.254"]
}

resource "routeros_ip_pool" "trusted_pool" {
  name   = "Trusted_DHCP_Pool"
  ranges = ["10.69.60.2-10.69.60.254"]
}

resource "routeros_ip_pool" "management_pool" {
  name   = "Management_DHCP_Pool"
  ranges = ["10.69.100.2-10.69.100.254"]
}

resource "routeros_ip_dhcp_server" "home_dhcp_server" {
  address_pool = routeros_ip_pool.home_pool
  interface    = routeros_interface_vlan.home_vlan
  name         = "Home_DHCP_Server"
}

resource "routeros_ip_dhcp_server" "guest_dhcp_server" {
  address_pool = routeros_ip_pool.guest_pool
  interface    = routeros_interface_vlan.guest_vlan
  name         = "Guest_DHCP_Server"
}

resource "routeros_ip_dhcp_server" "security_dhcp_server" {
  address_pool = routeros_ip_pool.security_pool
  interface    = routeros_interface_vlan.security_lan
  name         = "Security_DHCP_Server"
}

resource "routeros_ip_dhcp_server" "iot_dhcp_server" {
  address_pool = routeros_ip_pool.iot_pool
  interface    = routeros_interface_vlan.iot_vlan
  name         = "IoT_DHCP_Server"
}

resource "routeros_ip_dhcp_server" "dmz_dhcp_server" {
  address_pool = routeros_ip_pool.dmz_pool
  interface    = routeros_interface_vlan.dmz_vlan
  name         = "DMZ_DHCP_Server"
}

resource "routeros_ip_dhcp_server" "trusted_dhcp_server" {
  address_pool = routeros_ip_pool.trusted_pool
  interface    = routeros_interface_vlan.trusted_vlan
  name         = "Trusted_DHCP_Server"
}

resource "routeros_ip_dhcp_server" "management_dhcp_server" {
  address_pool = routeros_ip_pool.management_pool
  interface    = routeros_interface_vlan.management_vlan
  name         = "Management_DHCP_Server"
}

resource "routeros_ip_dhcp_server_network" "home_dhcp_server_network" {
    address    = "10.69.10.0/24"
  gateway    = "10.69.10.1"
 dns_server = "10.69.100.1"
}

resource "routeros_ip_dhcp_server_network" "guest_dhcp_server_network" {
    address    = "10.69.20.0/24"
  gateway    = "10.69.20.1"
 dns_server = "10.69.100.1"
}

resource "routeros_ip_dhcp_server_network" "security_dhcp_server_network" {
    address    = "10.69.30.0/24"
  gateway    = "10.69.30.1"
 dns_server = "10.69.100.1"
}

resource "routeros_ip_dhcp_server_network" "iot_dhcp_server_network" {
    address    = "10.69.40.0/24"
  gateway    = "10.69.40.1"
 dns_server = "10.69.100.1"
}

resource "routeros_ip_dhcp_server_network" "dmz_dhcp_server_network" {
    address    = "10.69.50.0/24"
  gateway    = "10.69.50.1"
 dns_server = "10.69.100.1"
}

resource "routeros_ip_dhcp_server_network" "trusted_dhcp_server_network" {
    address    = "10.69.60.0/24"
  gateway    = "10.69.60.1"
 dns_server = "10.69.100.1"
}

resource "routeros_ip_dhcp_server_network" "management_dhcp_server_network" {
    address    = "10.69.100.0/24"
  gateway    = "10.69.100.1"
 dns_server = "10.69.100.1"
}

resource "routeros_interface_bridge_port" "bridge_port_ether2" {
  bridge    = routeros_interface_bridge.bridge.name 
  interface = "ether2"
  frame_types = "admit-only-vlan-tagged"
}

resource "routeros_interface_bridge_vlan" "home_bridge_vlan" {
  vlan_ids = "10"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_interface_bridge_vlan" "guest_bridge_vlan" {
  vlan_ids = "20"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_interface_bridge_vlan" "security_bridge_vlan" {
  vlan_ids = "30"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_interface_bridge_vlan" "iot_bridge_vlan" {
  vlan_ids = "40"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_interface_bridge_vlan" "dmz_bridge_vlan" {
  vlan_ids = "50"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_interface_bridge_vlan" "trusted_bridge_vlan" {
  vlan_ids = "60"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_interface_bridge_vlan" "management_bridge_vlan" {
  vlan_ids = "100"
  bridge   =routeros_interface_bridge.bridge.name  
  tagged = [
   routeros_interface_bridge.bridge.name ,
   "ether2"
  ]
}

resource "routeros_dns" "dns-server" {
  allow_remote_requests = true
  servers               = "9.9.9.9,149.112.112.112"
}

resource "routeros_ip_firewall_filter" "rule_1" {
  action      = "accept"
  chain       = "input"
  connection_state = "established,related"
  comment ="Allow Established & Related"
}

resource "routeros_ip_firewall_filter" "rule_2" {
  action      = "accept"
  chain       = "input"
  in_interface= routeros_interface_vlan.management_vlan
  comment ="Allow Management VLAN"
}

resource "routeros_ip_firewall_filter" "rule_3" {
  action      = "drop"
  chain       = "input"
  comment ="Drop"
}

resource "routeros_ip_firewall_filter" "rule_4" {
  action      = "accept"
  chain       = "forward"
  connection_state = "established,related"
  comment ="Allow Established & Related"
}

resource "routeros_ip_firewall_filter" "rule_5" {
  action      = "accept"
  chain       = "forward"
  in_interface_list= routeros_interface_list.vlan_list 
  out_interface_list= routeros_interface_list.wan_list 
  comment ="VLAN Internet Access"
}

resource "routeros_ip_firewall_filter" "rule_6" {
  action      = "drop"
  chain       = "forward"
  comment ="Drop"
}

resource "routeros_ip_dhcp_client" "client" {
  interface = "ether1"
}

resource "routeros_ip_firewall_nat" "nat_rule" {
  action        = "masquerade"
  chain         = "srcnat"
  out_interface_list = routeros_interface_list.wan_list
}
