variable "identity" {
  type = string
}

variable "wan_interface" {
  type = string
}

variable "base_ip" {
  type = string
}

variable "vlans" {
  type = map(number)
}

variable "trunk_ports" {
  type = list(string)
}

variable "access_ports" {
  type = map(number)
}

variable "bgp_peers" {
  description = "eBGP peers, keyed by connection name -> remote node IP"
  type        = map(string)
  default     = {}
}

variable "enforce_firewall" {
  description = "When false, the catch-all input/forward drop rules are created but disabled, so a bad apply can't lock you out. Verify the accept rules, then set true for stage 2."
  type        = bool
  default     = false
}

variable "internet_vlans" {
  description = "VLAN names permitted to reach the WAN. Security + IoT are intentionally omitted so they have no internet access."
  type        = list(string)
  default     = ["Home", "Guest", "DMZ", "Trusted", "Management", "Dad"]
}

variable "dhcp_leases" {
  description = "Static DHCP reservations, keyed by a stable name"
  type = map(object({
    address     = string
    mac_address = string
    server      = string
    client_id   = optional(string)
  }))
  default = {}
}
