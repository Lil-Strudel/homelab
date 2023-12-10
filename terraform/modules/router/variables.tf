variable "base_ip" {
  type = string
}

variable "management_vlan_id" {
  type = string
}

variable "vlans" {
  type = map(object({
    id   = string
    name = string
  }))
}

variable "wan_interface" {
  type = string
}

variable "trunk_ports" {
  type = set(string)
}

variable "access_ports" {
  type = list(object({
    interface = string
    vlan      = string
  }))
}
