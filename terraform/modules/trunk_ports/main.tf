terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

##################
# Ingress Behavior
##################
resource "routeros_interface_bridge_port" "bridge_port" {
  for_each = toset(var.interfaces)

  bridge            = var.bridge
  interface         = each.key
  ingress_filtering = true
  frame_types       = "admit-only-vlan-tagged"
}

##################
# Egress Behavior
##################
resource "routeros_interface_bridge_vlan" "bridge_vlan" {
  for_each = var.vlans

  bridge   = var.bridge
  tagged   = toset(concat([var.bridge], var.interfaces))
  vlan_ids = [each.value]
}
