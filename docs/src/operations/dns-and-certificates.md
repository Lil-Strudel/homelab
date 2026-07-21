# DNS & Certificates

DNS is **split-horizon**, and both sides are declared in Terraform from one source of
truth — the `services` map in `terraform/main.tf`:

- **Internal** — the MikroTik resolver answers `*.lilstrudel.io` for LAN clients,
  pointing each service at its **pinned** cluster `LoadBalancer` IP (`10.69.60.x`
  internal / `10.69.50.x` public-class). Managed as `routeros_ip_dns_record`s by the
  router module.
- **Public** — Route53 (`lilstrudel.io`) answers for the internet, pointing
  internet-facing services at the public entry point. This side is **built but dormant**:
  the records only materialize once `local.public_ingress_ip` is set (the internet
  last-mile — a tunnel / VPS). Until then, `public = true` services resolve **internally
  only**.

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

## AWS account & IAM

The `lilstrudel.io` zone lives in a **separate AWS account** from the `strudelan`
Terraform-state account. Terraform manages Route53 (the zone data source, the public
records, and the DNS IAM user) under a second provider alias (`aws.dns`, profile
`lil-strudel`) in `terraform/route53.tf`:

- `aws_iam_user.route53` (`homelab-route53`) with an inline policy scoped to the
  `lilstrudel.io` hosted zone, for **cert-manager's** DNS-01 `TXT` challenges.
- `aws_iam_access_key.route53`, surfaced as the **sensitive** outputs
  `route53_access_key_id` / `route53_secret_access_key`.

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
`terraform apply`. The `ip` is the service's pinned LoadBalancer IP; its subnet also
decides the Cilium pool (`10.69.50.x` public / `10.69.60.x` internal):

```hcl
services = {
  myapp = { ip = "10.69.60.65", public = false }  # internal-only
  # public-class: ip in 10.69.50.x + public = true
}
```

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
