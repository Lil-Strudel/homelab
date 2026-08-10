data "aws_route53_zone" "all" {
  for_each = local.zones

  provider = aws.dns
  name     = each.value
}

resource "aws_iam_user" "route53" {
  provider = aws.dns
  name     = "homelab-route53"
}

resource "aws_iam_user_policy" "route53" {
  provider = aws.dns
  name     = "homelab-route53-dns"
  user     = aws_iam_user.route53.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResources",
        ]
        Resource = [
          for z in data.aws_route53_zone.all : "arn:aws:route53:::hostedzone/${z.zone_id}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_access_key" "route53" {
  provider = aws.dns
  user     = aws_iam_user.route53.name
}

output "route53_access_key_id" {
  description = "Access key ID for the Route53 user (cert-manager DNS-01). Copy into the SOPS secrets."
  value       = aws_iam_access_key.route53.id
  sensitive   = true
}

output "route53_secret_access_key" {
  description = "Secret access key for the Route53 user (cert-manager DNS-01). Copy into the SOPS secrets."
  value       = aws_iam_access_key.route53.secret
  sensitive   = true
}

# Public records for internet-exposed services. Dormant until local.public_ingress_ip is
# set (the DMZ edge host), at which point every service carrying an `expose` block gets an
# A record pointing at that entry point.
resource "aws_route53_record" "public" {
  for_each = {
    for fqdn, svc in local.services : fqdn => svc
    if svc.expose != null && local.public_ingress_ip != ""
  }

  provider = aws.dns
  zone_id  = data.aws_route53_zone.all[each.value.zone].zone_id
  name     = each.key
  type     = "A"
  ttl      = 300
  records  = [local.public_ingress_ip]
}

resource "aws_route53_record" "vpn" {
  provider = aws.dns
  zone_id  = data.aws_route53_zone.all[local.domain].zone_id
  name     = "vpn.${local.domain}"
  type     = "A"
  ttl      = 300
  records  = [data.sops_file.secrets.data["vpn_public_ip"]]

  lifecycle {
    # The ddns CronJob owns the address; Terraform only owns the record's existence.
    ignore_changes = [records]
  }
}

locals {
  # Records the in-cluster ddns CronJob keeps pointed at the current WAN address, as
  # fqdn => hosted zone. This list is the IAM blast radius: the credential can rewrite
  # exactly these names and nothing else. Adding one here also means adding a line to
  # the `ddns-records` ConfigMap under kubernetes/infrastructure/controllers/ddns/.
  ddns_records = {
    "vpn.${local.domain}" = local.domain
  }
}

resource "aws_iam_user" "ddns" {
  provider = aws.dns
  name     = "homelab-ddns"
}

resource "aws_iam_user_policy" "ddns" {
  provider = aws.dns
  name     = "homelab-ddns-route53"
  user     = aws_iam_user.ddns.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "route53:ChangeResourceRecordSets"
        Resource = [
          for z in distinct(values(local.ddns_records)) :
          "arn:aws:route53:::hostedzone/${data.aws_route53_zone.all[z].zone_id}"
        ]
        Condition = {
          "ForAllValues:StringEquals" = {
            # Normalized names are lowercase and carry no trailing dot.
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = [
              for name in keys(local.ddns_records) : lower(name)
            ]
            "route53:ChangeResourceRecordSetsRecordTypes" = ["A"]
            "route53:ChangeResourceRecordSetsActions"     = ["UPSERT"]
          }
        }
      },
      {
        Effect = "Allow"
        Action = "route53:ListResourceRecordSets"
        Resource = [
          for z in distinct(values(local.ddns_records)) :
          "arn:aws:route53:::hostedzone/${data.aws_route53_zone.all[z].zone_id}"
        ]
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_access_key" "ddns" {
  provider = aws.dns
  user     = aws_iam_user.ddns.name
}

output "ddns_access_key_id" {
  description = "Access key ID for the ddns user. Copy into the ddns-aws-credentials SOPS secret."
  value       = aws_iam_access_key.ddns.id
  sensitive   = true
}

output "ddns_secret_access_key" {
  description = "Secret access key for the ddns user. Copy into the ddns-aws-credentials SOPS secret."
  value       = aws_iam_access_key.ddns.secret
  sensitive   = true
}
