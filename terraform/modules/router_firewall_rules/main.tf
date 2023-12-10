terraform {
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.27.2"
    }
  }
}

resource "routeros_ip_firewall_filter" "rule_1" {
  action           = "accept"
  chain            = "input"
  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before = routeros_ip_firewall_filter.rule_2.id
}

resource "routeros_ip_firewall_filter" "rule_2" {
  action       = "accept"
  chain        = "input"
  in_interface = "Management_VLAN"
  comment      = "Allow Management VLAN"
  place_before = routeros_ip_firewall_filter.rule_3.id
}

resource "routeros_ip_firewall_filter" "rule_3" {
  action  = "drop"
  chain   = "input"
  comment = "Drop"
  disabled = true
  place_before = routeros_ip_firewall_filter.rule_4.id
}

resource "routeros_ip_firewall_filter" "rule_4" {
  action           = "accept"
  chain            = "forward"
  connection_state = "established,related"
  comment          = "Allow Established & Related"
  place_before = routeros_ip_firewall_filter.rule_5.id
}

resource "routeros_ip_firewall_filter" "rule_5" {
  action             = "accept"
  chain              = "forward"
  in_interface_list  = "VLAN"
  out_interface_list = "WAN"
  comment            = "VLAN Internet Access"
  place_before = routeros_ip_firewall_filter.rule_6.id
}

resource "routeros_ip_firewall_filter" "rule_6" {
  action  = "drop"
  chain   = "forward"
  disabled = true
  comment = "Drop"
}
