variable "name" {
  type = string
}

variable "base_ip" {
  type = string
}

variable "management_vlan_id" {
  type = string
}

variable "ip" {
  type = string
}

variable "vlans" {
  type = map(object({
    id   = string
    name = string
  }))
}

variable "trunk_ports" {
  type = set(string)
}

variable "access_ports" {
  type = map(object({
    interface = string
    vlan      = string
  }))
}
