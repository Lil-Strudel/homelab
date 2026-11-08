terraform {
  backend "s3" {
    bucket       = "strudelan-tfstate-3c9b7ca5"
    key          = "homelab/cnh.tfstate"
    region       = "us-west-2"
    profile      = "strudelan"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.28"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}

data "sops_file" "secrets" {
  source_file = "secrets.sops.yaml"
}

locals {
  domain     = "quikk.live"
  account_id = data.sops_file.secrets.data["cloudflare_account_id"]
  origins = {
    "^/api/"    = "http://api.cnh.svc.cluster.local:8080"
    "^/events/" = "http://fanout.cnh.svc.cluster.local:8080"
  }
}

provider "cloudflare" {
  api_token = data.sops_file.secrets.data["cloudflare_api_token"]
}

provider "aws" {
  region  = "us-east-1"
  profile = "lil-strudel"
}

resource "cloudflare_zone" "app" {
  account = { id = local.account_id }
  name    = local.domain
  type    = "full"
}

resource "aws_route53domains_registered_domain" "app" {
  domain_name = local.domain

  dynamic "name_server" {
    for_each = cloudflare_zone.app.name_servers
    content {
      name = name_server.value
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "app" {
  account_id = local.account_id
  name       = "cnh-homelab"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "app" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.app.id
  config = {
    ingress = concat(
      [for path, service in local.origins : { hostname = local.domain, path = path, service = service }],
      [
        { hostname = local.domain, service = "http://web.cnh.svc.cluster.local:8080" },
        { service = "http_status:404" },
      ],
    )
  }
}

resource "cloudflare_dns_record" "app" {
  zone_id = cloudflare_zone.app.id
  name    = local.domain
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.app.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "app" {
  account_id = local.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.app.id
}

output "tunnel_token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.app.token
  sensitive = true
}

output "name_servers" {
  value = cloudflare_zone.app.name_servers
}
