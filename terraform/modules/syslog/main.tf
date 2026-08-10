terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

###############
# Syslog Action
###############
resource "routeros_system_logging_action" "loki" {
  name              = "loki"
  target            = "remote"
  remote            = var.target_ip
  remote_port       = var.target_port
  remote_protocol   = "udp"
  remote_log_format = "syslog"
}

################
# Topic → Action
################
resource "routeros_system_logging" "loki" {
  # One rule per topic: RouterOS ANDs the topics within a single rule, so a
  # combined list would only match messages carrying every topic at once.
  for_each = toset(var.topics)

  action = routeros_system_logging_action.loki.name
  topics = [each.value]
}
