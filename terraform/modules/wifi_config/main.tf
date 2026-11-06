terraform {
  required_providers {
    routeros = {
      source = "terraform-routeros/routeros"
    }
  }
}

locals {
  name = lower(var.ssid)

  bands = {
    "2ghz" = {
      band      = "2ghz-ax"
      width     = "20mhz"
      frequency = ["2412", "2437", "2462"]
    }
    "5ghz" = {
      band      = "5ghz-ax"
      width     = "20/40/80mhz"
      frequency = null
    }
  }
}

resource "routeros_wifi_security" "wifi_security" {
  name                 = "${local.name}_security"
  authentication_types = ["wpa2-psk", "wpa3-psk"]
  ft                   = true
  ft_over_ds           = true
  wps                  = "disable"
  passphrase           = var.passphrase
}

resource "routeros_wifi_datapath" "wifi_datapath" {
  name    = "${local.name}_datapath"
  bridge  = var.bridge
  vlan_id = var.vlan_id
}

resource "routeros_wifi_channel" "wifi_channel" {
  for_each = local.bands

  name              = "${local.name}_${each.key}_channel"
  band              = each.value.band
  width             = each.value.width
  frequency         = each.value.frequency
  skip_dfs_channels = "all"
  reselect_time     = "03:00:00..04:00:00"
}

resource "routeros_wifi_configuration" "wifi_config" {
  for_each = local.bands

  name    = "${local.name}_${each.key}_config"
  country = "United States"
  mode    = "ap"
  ssid    = var.ssid

  security = {
    config = routeros_wifi_security.wifi_security.name
  }

  datapath = {
    config = routeros_wifi_datapath.wifi_datapath.name
  }

  channel = {
    config = routeros_wifi_channel.wifi_channel[each.key].name
  }
}

resource "routeros_wifi_provisioning" "wifi_provisioning" {
  for_each = local.bands

  action               = "create-dynamic-enabled"
  supported_bands      = [each.value.band]
  master_configuration = routeros_wifi_configuration.wifi_config[each.key].name
}
