# DNS & Certificates

Public DNS and TLS are automated by two controllers, both authenticating to
**AWS Route53** for the `lilstrudel.io` zone:

- [**external-dns**](https://kubernetes-sigs.github.io/external-dns/) — watches
  `Service` (LoadBalancer) and `Ingress` objects and writes matching records into
  Route53.
- [**cert-manager**](https://cert-manager.io/) — issues [Let's Encrypt](https://letsencrypt.org/)
  certificates using the **DNS-01** solver against Route53, so certs are obtained
  without any inbound HTTP reachability.

Versions are in [Reference → Versions](../reference/versions.md). Like the rest of the
platform, Flux brings both up from `kubernetes/infrastructure/{controllers,configs}/`
— the only manual step is the one-time AWS credential setup below.

## What runs where

| Object | Chart / kind | Stage | Role |
| --- | --- | --- | --- |
| `cert-manager` | `cert-manager` (OCI) | controllers | Controller, webhook, cainjector + CRDs |
| `external-dns` | `external-dns` | controllers | Syncs hostnames to Route53 (`policy: upsert-only`) |
| `letsencrypt-staging` / `letsencrypt-prod` | `ClusterIssuer` | configs | ACME issuers with the Route53 DNS-01 solver |

`infra-controllers` runs with `wait: true`, so cert-manager's CRDs exist before the
`ClusterIssuer` CRs reconcile in `infra-configs`.

## AWS account & IAM

The `lilstrudel.io` zone lives in a **separate AWS account** from the `strudelan`
Terraform-state account. Terraform manages the Route53 IAM user under a second provider
alias (`aws.dns`, profile `lil-strudel`) in `terraform/route53.tf`:

- `aws_iam_user.route53` (`homelab-route53`) with an inline policy scoped to the
  `lilstrudel.io` hosted zone — the union of what cert-manager (DNS-01 `TXT` challenges)
  and external-dns (record CRUD) need.
- `aws_iam_access_key.route53`, surfaced as the **sensitive** outputs
  `route53_access_key_id` / `route53_secret_access_key`.

Both profiles resolve through AWS SSO / IAM Identity Center. Configure them once with
the helper (writes a managed block into `~/.aws/config`, then logs in):

```bash
./scripts/aws_sso_setup.sh
```

Refresh an expired session any time with `aws sso login --sso-session homelab`.

## Credentials → SOPS

The IAM key is not consumed directly by Terraform's cluster — it is copied into two
[SOPS](./secrets.md)-encrypted Kubernetes Secrets (one per namespace, since Secrets are
namespaced), in the two field shapes each controller expects:

```bash
cd terraform && terraform apply
terraform output -raw route53_access_key_id
terraform output -raw route53_secret_access_key
```

| Secret | Namespace | Shape | Consumed by |
| --- | --- | --- | --- |
| `external-dns` | `external-dns` | INI `credentials` file (`AWS_SHARED_CREDENTIALS_FILE`) | external-dns pod |
| `route53-credentials` | `cert-manager` | `access-key-id` / `secret-access-key` keys | the `ClusterIssuer` DNS-01 solver |

Edit each with `sops <file>` to paste the two values, then commit. The repo-root
`.sops.yaml` encrypts them to the admin **and** cluster keys automatically (only
`data`/`stringData`), and Flux decrypts them in-cluster.

## Using it

**A DNS record for a service** — annotate a `LoadBalancer` Service (or an `Ingress`):

```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: app.lilstrudel.io
```

external-dns creates the `A` + ownership `TXT` records. Because `policy: upsert-only`,
it never deletes records — prune them by hand in Route53 if a service goes away.

**A certificate** — reference an issuer from an `Ingress`, or request a `Certificate`
directly. Validate wiring against staging first (untrusted, but no rate limits), then
switch to prod:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging   # then letsencrypt-prod
```

Check progress with `kubectl get certificate,certificaterequest,challenge -A`.
