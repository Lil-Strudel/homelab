variable "passphrase" {
  type      = string
  sensitive = true
}

variable "ssid" {
  type = string
}

variable "bridge" {
  description = "Bridge every AP's radios join, named the same on the manager and each CAP."
  type        = string
}

variable "vlan_id" {
  description = "VLAN that clients of this SSID are placed on."
  type        = number
}
