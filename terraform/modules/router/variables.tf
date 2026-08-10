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

variable "services_cidr" {
  description = "Routed range holding cluster LoadBalancer IPs. Not a VLAN and not an L2 segment — the router only ever learns /32s in it over BGP, so rules must match dst-address rather than out-interface."
  type        = string
}

variable "dns_records" {
  description = "Internal static DNS A records served by the router's resolver, keyed by FQDN -> IP"
  type        = map(string)
  default     = {}
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

variable "wg_home_private_key" {
  type      = string
  sensitive = true
}

variable "wg_management_private_key" {
  type      = string
  sensitive = true
}

variable "wg_home_port" {
  type    = number
  default = 51820
}

variable "wg_management_port" {
  type    = number
  default = 51821
}

variable "wg_home_peers" {
  description = "WireGuard clients for the home tunnel, keyed by a stable name. address is the client's /32 on 10.69.70.0/24."
  type = map(object({
    public_key    = string
    address       = string
    preshared_key = optional(string)
  }))
  default = {}
}

variable "wg_management_peers" {
  description = "WireGuard clients for the management tunnel, keyed by a stable name. address is the client's /32 on 10.69.80.0/24."
  type = map(object({
    public_key    = string
    address       = string
    preshared_key = optional(string)
  }))
  default = {}
}
