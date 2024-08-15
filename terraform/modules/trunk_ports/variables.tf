variable "bridge" {
  type = string
}

variable "interfaces" {
  type = list(string)
}

variable "vlans" {
  type = map(number)
}
