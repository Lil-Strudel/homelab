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

variable "admin_sources" {
  description = "Comma-separated prefixes allowed to reach the AP's ssh, winbox and www-ssl services"
  type        = string
}

variable "trunk_ports" {
  type = list(string)
}

variable "access_ports" {
  type    = map(number)
  default = {}
}

variable "capsman_role" {
  type = string
  validation {
    condition     = contains(["manager", "client"], var.capsman_role)
    error_message = "Allowed values for input_parameter are \"manager\" or \"client\"."
  }
}

variable "radio_configurations" {
  description = "Wifi configuration to bind to each of the manager's own radios, keyed by radio name (manager role only)."
  type        = map(string)
  default     = {}
}
