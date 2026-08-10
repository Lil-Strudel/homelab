# DNS & Certificates

DNS is **split-horizon**, and both sides are declared in Terraform from one source of
truth — the `services` map in `terraform/main.tf`:

- **Internal** — the MikroTik resolver answers for LAN clients, pointing each service at
  its **pinned** cluster `LoadBalancer` IP in `10.69.65.0/24`. Managed as
  `routeros_ip_dns_record`s by the router module. Every service in the map gets one.
- **Public** — Route53 answers for the internet. A service gets a public record only if
  it carries an `expose` block *and* a WAN entry point (`local.public_ingress_ip`) exists.
  No service declares `expose` and there is no entry point, so the public side mints
  nothing today.

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
| Public `A` records | Terraform (`aws_route53_record.public`, `route53.tf`) | Route53 → the WAN entry point, for services declaring `expose` |
| WAN-address `A` records | the `ddns` CronJob (Flux, controllers) | Route53 → the address the ISP currently hands the router |
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

## Dynamic DNS

The ISP does not hand out a static WAN address, so every public record that points at
home is kept current by a **CronJob** (`kubernetes/infrastructure/controllers/ddns/`)
running every five minutes:

1. It asks `https://checkip.amazonaws.com` for the address it is seen from. The cluster
   egresses through the router, so that reflection *is* the WAN address.
2. For each configured name it reads the record's current value from Route53 and only
   calls `ChangeResourceRecordSets` when the two differ — a run that changes nothing
   makes no write.

Route53 holds the state, so nothing is cached in the cluster and a record edited by hand
is pulled back on the next run.

A CronJob rather than the router's own `/ip cloud` DDNS name because **`16e.link` is an
apex**: an apex cannot be a `CNAME`, and a Route53 `ALIAS` only targets AWS resources, so
a CNAME to the MikroTik DDNS hostname could only ever serve the subdomains. One mechanism
that upserts `A` records covers apex and subdomain alike.

**Which names it manages** is a list in two places, and both must agree:

| Where | What it controls |
| --- | --- |
| `local.ddns_records` in `terraform/route53.tf` | the IAM blast radius — the credential may rewrite exactly these names |
| the `ddns-records` ConfigMap (`records.yaml`) | what the job actually updates, one `<fqdn> <zone>` per line |

Adding a name means a line in each, then `terraform apply` (the policy is rewritten in
place; the access key is not rotated) and a commit.

Terraform declares the records themselves — `aws_route53_record.vpn` carries
`lifecycle { ignore_changes = [records] }`, so Terraform owns the record's *existence*
and its placeholder on first create, while the CronJob owns its *value*.

**Failure mode.** A cluster outage freezes DNS at the last address written; the records
keep resolving and only go stale if the ISP moves the address while the cluster is down.
Each run ends with a single summary line, which is what a future alert keys off:

```
level=info event=ddns_run_complete ip=<addr> updated=1 unchanged=0 failed=0
```

`ddns_record_updated` marks a real address change; `ddns_wan_lookup_failed`,
`ddns_zone_lookup_failed`, and `ddns_record_update_failed` are the error events, and any
of them fails the Job.

```bash
kubectl -n ddns get cronjob ddns
kubectl -n ddns logs -l app=ddns --tail=20
kubectl -n ddns create job ddns-now --from=cronjob/ddns   # force a run
```

## AWS account & IAM

All the zones live in a **separate AWS account** from the `strudelan` Terraform-state
account. Terraform manages Route53 (the zone data sources, the public records, and the
DNS IAM user) under a second provider alias (`aws.dns`, profile `lil-strudel`) in
`terraform/route53.tf`:

- `aws_iam_user.route53` (`homelab-route53`) with an inline policy scoped to the hosted
  zones in `local.zones`, for **cert-manager's** DNS-01 `TXT` challenges.
- `aws_iam_access_key.route53`, surfaced as the **sensitive** outputs
  `route53_access_key_id` / `route53_secret_access_key`.
- `aws_iam_user.ddns` (`homelab-ddns`) for [dynamic DNS](#dynamic-dns), a deliberately
  separate identity: its policy allows `UPSERT` of `A` records for exactly the names in
  `local.ddns_records` and nothing else, so a compromised cluster credential cannot
  rewrite the rest of a zone. Its key is the outputs `ddns_access_key_id` /
  `ddns_secret_access_key`.

Widening the zone list rewrites the policy in place and does **not** rotate the access
key, so the `route53-credentials` Secret below stays valid.

Both profiles resolve through AWS SSO / IAM Identity Center. Configure them once with
the helper (writes a managed block into `~/.aws/config`, then logs in):

```bash
./scripts/aws_sso_setup.sh
```

Refresh an expired session any time with `aws sso login --sso-session homelab`.

## Credentials → SOPS

The IAM keys are not consumed directly by Terraform's cluster — each is copied into a
[SOPS](./secrets.md)-encrypted Kubernetes Secret:

```bash
cd terraform && terraform apply
terraform output -raw route53_access_key_id
terraform output -raw route53_secret_access_key
terraform output -raw ddns_access_key_id
terraform output -raw ddns_secret_access_key
```

| Secret | Namespace | Shape | Consumed by |
| --- | --- | --- | --- |
| `route53-credentials` | `cert-manager` | `access-key-id` / `secret-access-key` keys | the `ClusterIssuer` DNS-01 solver |
| `ddns-aws-credentials` | `ddns` | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` keys | the [dynamic DNS](#dynamic-dns) CronJob |

Edit it with `sops <file>` to paste the two values, then commit. The repo-root
`.sops.yaml` encrypts it to the admin **and** cluster keys automatically (only
`data`/`stringData`), and Flux decrypts it in-cluster.

## Using it

**A DNS record for a service** — add it to the `services` map in `terraform/main.tf` and
`terraform apply`. The key is the full hostname; `ip` is the service's pinned
LoadBalancer IP, a free address in `10.69.65.0/24`; `zone` names which of the
[enrolled zones](#zones) it sits in; `expose` is the internet-facing decision:

```hcl
services = {
  "myapp.lilstrudel.io" = { ip = "10.69.65.50", zone = local.domain, expose = null }
  "example.com"         = { ip = "10.69.65.51", zone = "example.com", expose = null }
}
```

A bare apex is just a key with no subdomain part, so a service can own an entire domain.

`expose = null` is an internal MikroTik record only, reachable per the
[firewall matrix](../reference/network.md#firewall). The map is also the allocation
record for the services range — see
[Decisions → Service Networking](../decisions/service-networking.md).

**A certificate** — reference an issuer from an `Ingress`, or request a `Certificate`
directly. Validate wiring against staging first (untrusted, but no rate limits), then
switch to prod:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging   # then letsencrypt-prod
```

Check progress with `kubectl get certificate,certificaterequest,challenge -A`.
