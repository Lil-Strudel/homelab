terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

#############
# Wifi Config
#############
resource "routeros_wifi_channel" "wifi_channel" {
  name              = "${lower(var.ssid)}_channel"
  skip_dfs_channels = "all"
}

resource "routeros_wifi_security" "wifi_security" {
  name                 = "${lower(var.ssid)}_security"
  authentication_types = ["wpa2-psk"]
  ft                   = true
  ft_over_ds           = true
  ft_preserve_vlanid   = true
  passphrase           = var.passphrase
}

resource "routeros_wifi_configuration" "wifi_config" {
  country = "United States"
  mode    = "ap"
  name    = "${lower(var.ssid)}_config"
  ssid    = var.ssid

  security = {
    config = routeros_wifi_security.wifi_security.name
  }

  channel = {
    config = routeros_wifi_channel.wifi_channel.name
  }
}

