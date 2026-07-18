output "wg_home_public_key" {
  description = "Public key of the home WireGuard tunnel, for building client configs"
  value       = routeros_interface_wireguard.wg_home.public_key
}

output "wg_management_public_key" {
  description = "Public key of the management WireGuard tunnel, for building client configs"
  value       = routeros_interface_wireguard.wg_management.public_key
}
