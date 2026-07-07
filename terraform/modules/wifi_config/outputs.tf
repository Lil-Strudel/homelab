output "configuration_name" {
  description = "Name of the wifi configuration, for binding to radios."
  value       = routeros_wifi_configuration.wifi_config.name
}
