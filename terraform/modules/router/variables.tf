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
