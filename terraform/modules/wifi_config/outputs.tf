output "configuration_names" {
  description = "Wifi configuration name per AP identity, then per band, for binding to radios."
  value = {
    for ap, plan in var.channel_plan : ap => {
      for band in keys(plan) : band => routeros_wifi_configuration.wifi_config["${ap}_${band}"].name
    }
  }
}
