output "configuration_names" {
  description = "Wifi configuration name per band (2ghz, 5ghz), for binding to radios."
  value       = { for band, config in routeros_wifi_configuration.wifi_config : band => config.name }
}
