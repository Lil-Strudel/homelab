variable "target_ip" {
  type = string
}

variable "target_port" {
  type    = number
  default = 514
}

variable "topics" {
  type    = list(string)
  default = ["info", "error", "warning", "critical"]
}
