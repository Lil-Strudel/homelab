# DNS & Certificates

DNS is **split-horizon**, and both sides are declared in Terraform from one source of
truth — the `services` map in `terraform/main.tf`:

- **Internal** — the MikroTik resolver answers for LAN clients, pointing each service at
  its **pinned** cluster `LoadBalancer` IP (`10.69.60.x` internal / `10.69.50.x`
  public-class). Managed as `routeros_ip_dns_record`s by the router module.
- **Public** — Route53 answers for the internet, pointing internet-facing services at
  the public entry point. This side is **built but dormant**: the records only
  materialize once `local.public_ingress_ip` is set (the internet last-mile — a tunnel /
  VPS). Until then, `public = true` services resolve **internally only**.

Entries are keyed by **FQDN**, so a service can live on a subdomain or on a bare apex,
and `zone` picks which of the owned domains it belongs to.

Certificates are separate and need no inbound reachability:

- [**cert-manager**](https://cert-manager.io/) — issues [Let's Encrypt](https://letsencrypt.org/)
  certificates using the **DNS-01** solver against Route53. Because the challenge is a
  `TXT` record, certs are obtained with zero public HTTP exposure — so a service can carry
  a browser-trusted cert while still being internal-only.

Versions are in [Reference → Versions](../reference/versions.md). cert-manager is brought
up by Flux from `kubernetes/infrastructure/{controllers,configs}/`; the DNS records are
applied by Terraform.

## What runs where

| Object | Managed by | Role |
| --- | --- | --- |
| Internal `A` records | Terraform (`routeros_ip_dns_record`, router module) | MikroTik resolver → pinned LB IP |
| Public `A` records | Terraform (`aws_route53_record.public`, `route53.tf`) | Route53 → public entry point (dormant until last-mile) |
| `cert-manager` | Flux (`cert-manager` OCI chart, controllers) | Controller, webhook, cainjector + CRDs |
| `letsencrypt-staging` / `letsencrypt-prod` | Flux (`ClusterIssuer`, configs) | ACME issuers with the Route53 DNS-01 solver |

`infra-controllers` runs with `wait: true`, so cert-manager's CRDs exist before the
`ClusterIssuer` CRs reconcile in `infra-configs`.

## Zones

`local.zones` in `terraform/main.tf` lists every hosted zone the cluster may use. It is
the whole control surface: a zone in the list is read by Terraform **and** made writable
by cert-manager, so DNS-01 can issue for any name in it. A zone left out is neither.

| Zone | Used for |
| --- | --- |
| `lilstrudel.io` | the primary domain — cluster services, `vpn` |
| `16e.link` | Shlink short links (apex) and its admin UI |
| `lilstrudel.com` | enrolled, unused |
| `strudelconsulting.com` | enrolled, unused |
| `aaronsanto.com` | enrolled, unused |

Enrolling a zone is read-only plus an IAM grant — it never adopts or modifies records
already in that zone. Only names that appear in `local.services` (plus `vpn`) are
managed, so everything else a zone serves is left alone. The cost of enrolling a zone is
that the in-cluster credential gains `ChangeResourceRecordSets` on it; keep a zone out of
the list if it should never be cluster-writable.

## AWS account & IAM

All the zones live in a **separate AWS account** from the `strudelan` Terraform-state
account. Terraform manages Route53 (the zone data sources, the public records, and the
DNS IAM user) under a second provider alias (`aws.dns`, profile `lil-strudel`) in
`terraform/route53.tf`:

- `aws_iam_user.route53` (`homelab-route53`) with an inline policy scoped to the hosted
  zones in `local.zones`, for **cert-manager's** DNS-01 `TXT` challenges.
- `aws_iam_access_key.route53`, surfaced as the **sensitive** outputs
  `route53_access_key_id` / `route53_secret_access_key`.

Widening the zone list rewrites the policy in place and does **not** rotate the access
key, so the `route53-credentials` Secret below stays valid.

Both profiles resolve through AWS SSO / IAM Identity Center. Configure them once with
the helper (writes a managed block into `~/.aws/config`, then logs in):

```bash
./scripts/aws_sso_setup.sh
```

Refresh an expired session any time with `aws sso login --sso-session homelab`.

## Credentials → SOPS

The IAM key is not consumed directly by Terraform's cluster — it is copied into a
[SOPS](./secrets.md)-encrypted Kubernetes Secret in the `cert-manager` namespace:

```bash
cd terraform && terraform apply
terraform output -raw route53_access_key_id
terraform output -raw route53_secret_access_key
```

| Secret | Namespace | Shape | Consumed by |
| --- | --- | --- | --- |
| `route53-credentials` | `cert-manager` | `access-key-id` / `secret-access-key` keys | the `ClusterIssuer` DNS-01 solver |

Edit it with `sops <file>` to paste the two values, then commit. The repo-root
`.sops.yaml` encrypts it to the admin **and** cluster keys automatically (only
`data`/`stringData`), and Flux decrypts it in-cluster.

## Using it

**A DNS record for a service** — add it to the `services` map in `terraform/main.tf` and
`terraform apply`. The key is the full hostname; `ip` is the service's pinned
LoadBalancer IP, whose subnet also decides the Cilium pool (`10.69.50.x` public /
`10.69.60.x` internal); `zone` names which of the [enrolled zones](#zones) it sits in:

```hcl
services = {
  "myapp.lilstrudel.io" = { ip = "10.69.60.65", zone = local.domain, public = false }
  "example.com"         = { ip = "10.69.50.68", zone = "example.com", public = false }
  # public-class: ip in 10.69.50.x + public = true
}
```

A bare apex is just a key with no subdomain part, so a service can own an entire domain.

- `public = false` → an internal MikroTik record only. Reachable on the LAN and over
  `wg-home`.
- `public = true` → the internal record **plus** a Route53 record — but the Route53 side
  stays dormant until `local.public_ingress_ip` is set (the last-mile tunnel). See the
  service networking notes in [Adding a Service](./adding-a-service.md).

**A certificate** — reference an issuer from an `Ingress`, or request a `Certificate`
directly. Validate wiring against staging first (untrusted, but no rate limits), then
switch to prod:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging   # then letsencrypt-prod
```

Check progress with `kubectl get certificate,certificaterequest,challenge -A`.
