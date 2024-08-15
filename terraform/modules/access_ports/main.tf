terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

resource "routeros_interface_bridge_port" "access_bridge_port" {
  for_each = var.access_ports

  bridge            = var.bridge
  interface         = each.key
  pvid              = each.value
  ingress_filtering = true
  frame_types       = "admit-only-untagged-and-priority-tagged"
}
