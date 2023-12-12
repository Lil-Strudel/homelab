variable "base_ip" {
  type    = string
  default = "10.69"
}

variable "management_vlan_id" {
  type    = number
  default = 100
}

variable "vlans" {
  type = map(object({
    id   = number
    name = string
  }))
  default = {
    Home = {
      id   = 10
      name = "Home"
    },
    Guest = {
      id   = 20
      name = "Guest"
    },
    Security = {
      id   = 30
      name = "Security"
    },
    IoT = {
      id   = 40
      name = "IoT"
    },
    DMZ = {
      id   = 50
      name = "DMZ"
    },
    Trusted = {
      id   = 60
      name = "Trusted"
    },
    Management = {
      id   = 100
      name = "Management"
    },
    Dad = {
      id   = 200
      name = "Dad"
    },
  }
}

