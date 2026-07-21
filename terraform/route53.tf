data "aws_route53_zone" "main" {
  provider = aws.dns
  name     = local.domain
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
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.main.zone_id}"
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

# Public records for internet-exposed services. Dormant until local.public_ingress_ip
# is set (the internet last-mile: a tunnel / VPS), at which point every `public = true`
# service in local.services gets an A record pointing at that entry point.
resource "aws_route53_record" "public" {
  for_each = {
    for name, svc in local.services : name => svc
    if svc.public && local.public_ingress_ip != ""
  }

  provider = aws.dns
  zone_id  = data.aws_route53_zone.main.zone_id
  name     = "${each.key}.${local.domain}"
  type     = "A"
  ttl      = 300
  records  = [local.public_ingress_ip]
}

resource "aws_route53_record" "vpn" {
  provider = aws.dns
  zone_id  = data.aws_route53_zone.main.zone_id
  name     = "vpn.${local.domain}"
  type     = "A"
  ttl      = 300
  records  = [data.sops_file.secrets.data["vpn_public_ip"]]
}
