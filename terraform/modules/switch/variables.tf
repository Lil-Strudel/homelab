variable "identity" {
  type = string
}

variable "base_ip" {
  type = string
}

variable "ip_address" {
  type = string
}

variable "management_vlan" {
  type = number
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

variable "admin_sources" {
  description = "Comma-separated prefixes allowed to reach the switch's ssh, winbox and www-ssl services"
  type        = string
}
