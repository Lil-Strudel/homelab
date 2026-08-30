terraform {
  backend "s3" {
    bucket       = "strudelan-tfstate-3c9b7ca5"
    key          = "homelab/terraform.tfstate"
    region       = "us-west-2"
    profile      = "strudelan"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    routeros = {
      source  = "terraform-routeros/routeros"
      version = "1.99.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "aws" {
  region  = "us-west-2"
  profile = "strudelan"
}

provider "aws" {
  alias   = "dns"
  region  = "us-east-1"
  profile = "lil-strudel"
}

resource "random_id" "tfstate_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "strudelan-tfstate-${random_id.tfstate_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "tfstate_bucket" {
  description = "Name of the S3 bucket holding Terraform state"
  value       = aws_s3_bucket.tfstate.bucket
}

data "sops_file" "secrets" {
  source_file = "secrets.sops.yaml"
}

locals {
  vlans = {
    Home       = 10,
    Guest      = 20,
    Security   = 30,
    IoT        = 40,
    DMZ        = 50,
    Trusted    = 60,
    Management = 100,
    Dad        = 200,
  }
  base_ip = "10.69"
  domain  = "lilstrudel.io"

  # Cluster LoadBalancer IPs. Deliberately outside every VLAN's /24: no interface owns it,
  # so no host ever treats a service IP as directly connected and ARPs for it on-segment.
  # The router only ever learns /32s here over BGP from the Trusted-VLAN workers.
  services_cidr = "10.69.65.0/24"

  # Listing a zone here grants the cert-manager IAM user write access to it — a zone
  # left out cannot be issued certs via DNS-01. See route53.tf.
  zones = toset([
    local.domain,
    "16e.link",
    "lilstrudel.com",
    "strudelconsulting.com",
    "aaronsanto.com",
  ])

  # Single source of truth for cluster services, keyed by FQDN, and the allocation record
  # for the services range: this is the one place to look up a taken IP or claim a free
  # one. `ip` is the pinned Cilium LoadBalancer IP, `zone` must be one of local.zones.
  #
  # `expose` is the whole internet-facing decision for a service — it drives the dst-nat
  # rule, the DMZ -> service forward rule, and the public Route53 record together, so a
  # service that is not declared here cannot be reachable from the WAN. `null` means
  # internal-only. The shape, once the edge host exists:
  #
  #   expose = {
  #     wan_port = 443                            # dst-nat WAN -> edge host
  #     backend  = { proto = "tcp", port = 443 }  # edge host -> this service's ip
  #     enabled  = true                           # false keeps the path built but closed
  #   }
  services = {
    "vault.lilstrudel.io"    = { ip = "10.69.65.20", zone = local.domain, expose = null }
    "dashy.lilstrudel.io"    = { ip = "10.69.65.24", zone = local.domain, expose = null }
    "immich.lilstrudel.io"   = { ip = "10.69.65.25", zone = local.domain, expose = null }
    "rustdesk.lilstrudel.io" = { ip = "10.69.65.26", zone = local.domain, expose = null }
    "ceph.lilstrudel.io"     = { ip = "10.69.65.10", zone = local.domain, expose = null }
    "mc.lilstrudel.io"       = { ip = "10.69.65.30", zone = local.domain, expose = null, match_subdomain = true }
    "factorio.lilstrudel.io" = { ip = "10.69.65.31", zone = local.domain, expose = null }
    "grafana.lilstrudel.io"  = { ip = "10.69.65.40", zone = local.domain, expose = null }
    "loki.lilstrudel.io"     = { ip = "10.69.65.41", zone = local.domain, expose = null }
    "vmsingle.lilstrudel.io" = { ip = "10.69.65.42", zone = local.domain, expose = null }
    "syslog.lilstrudel.io"   = { ip = "10.69.65.43", zone = local.domain, expose = null }
    "alloy.lilstrudel.io"    = { ip = "10.69.65.44", zone = local.domain, expose = null }
    "16e.link"               = { ip = "10.69.65.21", zone = "16e.link", expose = null }
    "admin.16e.link"         = { ip = "10.69.65.22", zone = "16e.link", expose = null }
  }

  # WAN-side entry point for exposed services: the DMZ edge host, reached via dst-nat.
  # Empty until that host exists, which keeps the public Route53 records dormant.
  public_ingress_ip = ""
}

provider "routeros" {
  hosturl  = "10.69.100.1:6729"
  username = data.sops_file.secrets.data["routeros_username"]
  password = data.sops_file.secrets.data["routeros_password"]
  insecure = true
  alias    = "ccr2004"
}

provider "routeros" {
  hosturl  = "10.69.100.10:6729"
  username = data.sops_file.secrets.data["routeros_username"]
  password = data.sops_file.secrets.data["routeros_password"]
  insecure = true
  alias    = "crs326"
}

provider "routeros" {
  hosturl  = "10.69.100.11:6729"
  username = data.sops_file.secrets.data["routeros_username"]
  password = data.sops_file.secrets.data["routeros_password"]
  insecure = true
  alias    = "crs312"
}

provider "routeros" {
  hosturl  = "10.69.100.20:6729"
  username = data.sops_file.secrets.data["routeros_username"]
  password = data.sops_file.secrets.data["routeros_password"]
  insecure = true
  alias    = "cAPax-1"
}

provider "routeros" {
  hosturl  = "10.69.100.21:6729"
  username = data.sops_file.secrets.data["routeros_username"]
  password = data.sops_file.secrets.data["routeros_password"]
  insecure = true
  alias    = "cAPax-2"
}

module "router" {
  source = "./modules/router"
  providers = {
    routeros = routeros.ccr2004
  }

  identity      = "router"
  wan_interface = "ether1"

  base_ip = local.base_ip

  vlans         = local.vlans
  services_cidr = local.services_cidr

  dns_records           = { for fqdn, svc in local.services : fqdn => svc.ip if !try(svc.match_subdomain, false) }
  dns_subdomain_records = { for fqdn, svc in local.services : fqdn => svc.ip if try(svc.match_subdomain, false) }

  enforce_firewall = true

  internet_vlans = ["Home", "Guest", "DMZ", "Trusted", "Management", "Dad"]

  trunk_ports = ["ether2", "ether3", "ether4"]
  access_ports = {
    "ether5"  = local.vlans["Management"]
    "ether6"  = local.vlans["Management"]
    "ether7"  = local.vlans["Management"]
    "ether8"  = local.vlans["Management"]
    "ether9"  = local.vlans["Dad"]
    "ether10" = local.vlans["Dad"]
    "ether11" = local.vlans["Dad"]
    "ether12" = local.vlans["Dad"]
  }

  bgp_peers = {
    "Makima-1 Peer" = "10.69.60.11"
    "Makima-2 Peer" = "10.69.60.12"
    "Makima-3 Peer" = "10.69.60.13"
    "Rem-1 Peer"    = "10.69.60.21"
    "Rem-2 Peer"    = "10.69.60.22"
    "Rem-3 Peer"    = "10.69.60.23"
  }

  dhcp_leases = {
    makima-1   = { address = "10.69.60.11", mac_address = "6C:B3:11:87:36:A8", server = "Trusted_DHCP_Server" }
    makima-2   = { address = "10.69.60.12", mac_address = "6C:B3:11:86:A5:32", server = "Trusted_DHCP_Server" }
    makima-3   = { address = "10.69.60.13", mac_address = "6C:B3:11:87:3A:C6", server = "Trusted_DHCP_Server" }
    trusted-21 = { address = "10.69.60.21", mac_address = "6C:B3:11:87:38:AC", server = "Trusted_DHCP_Server" }
    trusted-22 = { address = "10.69.60.22", mac_address = "6C:B3:11:87:3A:5C", server = "Trusted_DHCP_Server" }
    trusted-23 = { address = "10.69.60.23", mac_address = "6C:B3:11:74:89:C0", server = "Trusted_DHCP_Server" }
    trusted-30 = { address = "10.69.60.30", mac_address = "D8:3A:DD:F8:00:79", server = "Trusted_DHCP_Server", client_id = "1:d8:3a:dd:f8:0:79" }
    mgmt-30    = { address = "10.69.100.30", mac_address = "D8:3A:DD:68:92:7C", server = "Management_DHCP_Server", client_id = "1:d8:3a:dd:68:92:7c" }
    mgmt-32    = { address = "10.69.100.32", mac_address = "90:B1:1C:00:E4:0F", server = "Management_DHCP_Server" }
  }

  wg_home_private_key       = data.sops_file.secrets.data["wireguard_home_private_key"]
  wg_management_private_key = data.sops_file.secrets.data["wireguard_management_private_key"]

  wg_home_peers = {
    home-phone  = { public_key = "X7PrlehY0YkbVyv5hC0/xokHpnt927U8FTk3LFLF3lc=", address = "10.69.70.2/32" }
    home-laptop = { public_key = "25l6Q7lmYuTl4SvDsrcVXSKSeJY7UlR3mXPXuJ94mVg=", address = "10.69.70.3/32" }
  }
  wg_management_peers = {
    mgmt-laptop = { public_key = "KJ/Z4ibFkUg9ZbJlND1kmqP36oF2vr2dFn3AyZqEE1k=", address = "10.69.80.2/32" }
  }
}

output "wg_home_public_key" {
  description = "Public key of the home WireGuard tunnel, for building client configs"
  value       = module.router.wg_home_public_key
}

output "wg_management_public_key" {
  description = "Public key of the management WireGuard tunnel, for building client configs"
  value       = module.router.wg_management_public_key
}

module "core_switch" {
  source = "./modules/switch"
  providers = {
    routeros = routeros.crs326
  }

  identity = "core_switch"

  base_ip    = local.base_ip
  ip_address = "10"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["sfp-sfpplus24"]
  access_ports = {
    sfp-sfpplus1  = local.vlans["Trusted"]
    sfp-sfpplus3  = local.vlans["Trusted"]
    sfp-sfpplus9  = local.vlans["Trusted"]
    sfp-sfpplus11 = local.vlans["Trusted"]
    sfp-sfpplus17 = local.vlans["Trusted"]
    sfp-sfpplus19 = local.vlans["Trusted"]
  }
}

module "ethernet_switch" {
  source = "./modules/switch"
  providers = {
    routeros = routeros.crs312
  }

  identity = "ethernet_switch"

  base_ip    = local.base_ip
  ip_address = "11"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["ether1", "combo1"]
  access_ports = {
    ether2 = local.vlans["Management"]
    ether3 = local.vlans["Management"]
    ether4 = local.vlans["Management"]
    ether5 = local.vlans["Trusted"]
    ether6 = local.vlans["Trusted"]
    ether7 = local.vlans["Trusted"]
    ether8 = local.vlans["Trusted"]
  }
}

module "wifi_config" {
  source = "./modules/wifi_config"
  providers = {
    routeros = routeros.cAPax-1
  }

  ssid       = "Strudel"
  passphrase = data.sops_file.secrets.data["wifi1_password"]
}

resource "routeros_wifi_configuration" "sprinkleract" {
  provider = routeros.cAPax-1

  name    = "sprinkleract_config"
  ssid    = "SprinklerAct Studios"
  country = "United States"
  mode    = "ap"

  security = {
    authentication_types = "wpa2-psk"
    passphrase           = data.sops_file.secrets.data["wifi2_password"]
    ft                   = "true"
    ft_over_ds           = "true"
    ft_preserve_vlanid   = "true"
  }

  channel = {
    skip_dfs_channels = "all"
  }
}

module "access_point_1" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.cAPax-1
  }

  capsman_role        = "manager"
  manager_wifi_config = module.wifi_config.configuration_name

  identity = "access_point_1"

  base_ip    = local.base_ip
  ip_address = "20"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["ether1"]
  access_ports = {
    ether2 = local.vlans["Management"]
    wifi1  = local.vlans["Management"]
    wifi2  = local.vlans["Management"]
  }

  virtual_aps = {
    wifi3 = {
      master_interface = "wifi2"
      mac_address      = "4A:A9:8A:C7:8C:F1"
      configuration    = routeros_wifi_configuration.sprinkleract.name
      pvid             = local.vlans["Dad"]
    }
  }
}

module "access_point_2" {
  source = "./modules/access_point"
  providers = {
    routeros = routeros.cAPax-2
  }

  depends_on   = [module.access_point_1]
  capsman_role = "client"

  identity = "access_point_2"

  base_ip    = local.base_ip
  ip_address = "21"

  vlans           = local.vlans
  management_vlan = local.vlans["Management"]

  trunk_ports = ["ether1"]
  access_ports = {
    wifi1 = local.vlans["Management"]
    wifi2 = local.vlans["Management"]
  }
}

##########################################
# Syslog: every device ships to Loki
##########################################
module "syslog_router" {
  source = "./modules/syslog"
  providers = {
    routeros = routeros.ccr2004
  }

  target_ip = local.services["syslog.lilstrudel.io"].ip
}

module "syslog_core_switch" {
  source = "./modules/syslog"
  providers = {
    routeros = routeros.crs326
  }

  target_ip = local.services["syslog.lilstrudel.io"].ip
}

module "syslog_ethernet_switch" {
  source = "./modules/syslog"
  providers = {
    routeros = routeros.crs312
  }

  target_ip = local.services["syslog.lilstrudel.io"].ip
}

module "syslog_access_point_1" {
  source = "./modules/syslog"
  providers = {
    routeros = routeros.cAPax-1
  }

  target_ip = local.services["syslog.lilstrudel.io"].ip
}

module "syslog_access_point_2" {
  source = "./modules/syslog"
  providers = {
    routeros = routeros.cAPax-2
  }

  target_ip = local.services["syslog.lilstrudel.io"].ip
}
