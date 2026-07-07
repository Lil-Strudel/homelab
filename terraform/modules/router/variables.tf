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
