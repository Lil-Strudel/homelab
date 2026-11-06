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

variable "manager_identity" {
  description = "Identity of the AP running CAPsMAN, whose own radios are bound directly rather than provisioned."
  type        = string
}

variable "channel_plan" {
  description = "Frequencies each AP may use, keyed by AP identity, then by band (2ghz, 5ghz)."
  type        = map(map(list(string)))

  validation {
    condition     = alltrue([for plan in values(var.channel_plan) : alltrue([for band in keys(plan) : contains(["2ghz", "5ghz"], band)])])
    error_message = "Bands must be \"2ghz\" or \"5ghz\"."
  }
}
