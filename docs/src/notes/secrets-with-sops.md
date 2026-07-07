# Secrets with SOPS + Age

All secrets in this repo are encrypted with [SOPS](https://github.com/getsops/sops)
using [Age](https://github.com/FiloSottile/age) recipients. Encrypted files are
committed to git; plaintext never is.

## Convention

- Encrypted secrets live **next to what they configure** and are named `*.sops.yaml`.
- Plaintext / generated artifacts stay **gitignored** (`terraform/.env` — gone now,
  `talos/talos/*.yaml`, `talos/machine-configs/`, `kube-config`).
- The repo-root [`.sops.yaml`](../../../.sops.yaml) decides recipients by file path.

## Keys

Two Age keypairs:

| Key | Public | Private half lives | Decrypts |
| --- | --- | --- | --- |
| **admin** | `age1dhzh7r7c8u8sqdfrpdupk6r37zyk9m6yha3x37964u72rg4degtqy8pzp5` | `~/.config/sops/age/keys.txt` **and your password manager** | everything |
| **cluster** | `age19etvk27ryx8ksye4r2pghvqd3ml2f6aqgrsahn5c2tm5hxq5ha8sj88fwd` | `~/.config/sops/age/cluster.agekey` → in-cluster `sops-age` secret | `kubernetes/**` only |

The **admin private key is the root of trust.** Back it up to your password manager
now; if it is lost, nothing in the repo can be decrypted. If it leaks, rotate
(re-key every file, see below) since the repo is public.

`sops` finds the admin key automatically via `~/.config/sops/age/keys.txt`
(or the `SOPS_AGE_KEY_FILE` env var).

## Everyday use

Edit a secret in place (decrypts to your editor, re-encrypts on save):

```
sops terraform/secrets.sops.yaml
```

Encrypt a brand-new plaintext file (recipients come from `.sops.yaml` by path):

```
sops -e -i path/to/new.sops.yaml
```

View decrypted:

```
sops -d talos/talos/secrets.sops.yaml
```

## Terraform

`terraform/main.tf` reads secrets via the `carlpett/sops` provider:

```hcl
data "sops_file" "secrets" { source_file = "secrets.sops.yaml" }
# ... data.sops_file.secrets.data["routeros_password"]
```

The provider needs the admin Age key at plan/apply time, so runs must use
**Terraform Cloud execution = Local** (the MikroTik apply already requires this for
LAN access). If you ever run remotely, set `SOPS_AGE_KEY` as a TFC workspace variable
instead. Edit values with `sops terraform/secrets.sops.yaml` (the required keys are visible
in cleartext there — SOPS only encrypts the values).

## Talos

`talos/talos/secrets.sops.yaml` (cluster PKI / bootstrap tokens) and
`talos/talos/talosconfig.sops.yaml` are the committed source of truth.
`./gen-talos-objects.sh` decrypts them transparently (via process substitution) to
regenerate the plaintext `controlplane.yaml` / `worker.yaml` / `talosconfig`, which
stay gitignored.

## Kubernetes / Flux

The root Flux Kustomization has SOPS decryption enabled (patched in
`kubernetes/main/flux-system/kustomization.yaml`). It decrypts using the cluster key,
which must be loaded once as a secret after `flux bootstrap`:

```
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/cluster.agekey
```

To add an application secret: write a normal `Secret` manifest named `something.sops.yaml`
somewhere under `kubernetes/`, encrypt it with `sops -e -i something.sops.yaml`
(only `data`/`stringData` get encrypted so the rest stays diffable), add it to the
relevant kustomization, and commit. Flux decrypts it on apply.

## Rotating the admin key

1. `age-keygen -o ~/.config/sops/age/keys.txt` (back up the new key).
2. Update the `age:` recipients in `.sops.yaml`.
3. Re-key every file: `find . -name '*.sops.yaml' -exec sops updatekeys -y {} \;`
4. Commit. (Rotating the **cluster** key additionally means recreating the `sops-age`
   secret and letting Flux re-reconcile.)
