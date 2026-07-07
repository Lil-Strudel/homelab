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

variable "capsman_role" {
  type = string
  validation {
    condition     = contains(["manager", "client"], var.capsman_role)
    error_message = "Allowed values for input_parameter are \"manager\" or \"client\"."
  }
}

variable "manager_wifi_config" {
  description = "Wifi configuration name to bind to this AP's own radios (manager role only)."
  type        = string
  default     = ""
}

variable "virtual_aps" {
  description = "Extra virtual AP interfaces to create, keyed by interface name."
  type = map(object({
    master_interface = string
    mac_address      = string
    configuration    = string
    pvid             = number
  }))
  default = {}
}
