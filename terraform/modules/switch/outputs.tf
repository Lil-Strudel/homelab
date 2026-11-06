output "bridge" {
  value = routeros_interface_bridge.bridge.name
}

output "management_interface" {
  value = routeros_interface_vlan.management_vlan.name
}
