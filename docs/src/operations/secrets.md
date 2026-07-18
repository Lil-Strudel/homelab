# Secrets (SOPS + Age)

All secrets in this repo are encrypted with [SOPS](https://github.com/getsops/sops)
using [Age](https://github.com/FiloSottile/age) recipients. Encrypted files are
committed to git; plaintext never is.

## Convention

- Encrypted secrets live **next to what they configure**, named `*.sops.yaml`.
- Plaintext / generated artifacts stay **gitignored** (`talos/talos/*.yaml`,
  `talos/machine-configs/`, `kube-config`).
- The repo-root [`.sops.yaml`](../../../.sops.yaml) decides recipients by file path.

## Keys

Two Age keypairs:

| Key | Public | Private half lives | Decrypts |
| --- | --- | --- | --- |
| **admin** | `age1dhzh7r7c8u8sqdfrpdupk6r37zyk9m6yha3x37964u72rg4degtqy8pzp5` | `~/.config/sops/age/keys.txt` **and your password manager** | everything |
| **cluster** | `age19etvk27ryx8ksye4r2pghvqd3ml2f6aqgrsahn5c2tm5hxq5ha8sj88fwd` | `~/.config/sops/age/cluster.agekey` → in-cluster `sops-age` secret | `kubernetes/**` only |

The **admin private key is the root of trust.** Back it up to your password manager;
if it is lost, nothing in the repo can be decrypted. If it leaks, rotate (re-key every
file, see below) since the repo is public. `sops` finds the admin key automatically via
`~/.config/sops/age/keys.txt` (or `SOPS_AGE_KEY_FILE`).

## Everyday use

```bash
sops terraform/secrets.sops.yaml        # edit in place (decrypt to editor, re-encrypt on save)
sops -e -i path/to/new.sops.yaml        # encrypt a new file (recipients from .sops.yaml by path)
sops -d talos/talos/secrets.sops.yaml   # view decrypted
```

## Per-domain notes

- **Terraform** — `terraform/main.tf` reads secrets via the `carlpett/sops` provider
  (`data.sops_file.secrets`). The provider needs the admin Age key at plan/apply time,
  so runs must use **Terraform Cloud execution = Local** (already required for LAN
  access). For remote runs, set `SOPS_AGE_KEY` as a TFC workspace variable. Only values
  are encrypted, so the required keys stay visible in cleartext.
- **Talos** — `talos/talos/secrets.sops.yaml` (cluster PKI / bootstrap tokens) and
  `talosconfig.sops.yaml` are the committed source of truth; `./gen-talos-objects.sh`
  decrypts them transparently to regenerate the gitignored plaintext configs.
- **Kubernetes / Flux** — the `infra-controllers`, `infra-configs`, and `apps`
  Kustomizations each have SOPS decryption enabled (`spec.decryption.provider: sops`,
  secret `sops-age`) in `clusters/main/infrastructure.yaml` and `apps.yaml`. They
  decrypt with the cluster key, loaded once after `flux bootstrap`:

  ```bash
  kubectl create secret generic sops-age -n flux-system \
    --from-file=age.agekey=$HOME/.config/sops/age/cluster.agekey
  ```

  > The bootstrap-managed root Kustomization (`flux-system`) only reconciles
  > `clusters/main` — plain Flux CRs, no secrets — so it deliberately has no decryption
  > block. Decryption lives on the downstream Kustomizations that apply manifests,
  > which is why the standard `gotk-*` files are left untouched.

Adding an application secret is covered in
[Adding a Service](./adding-a-service.md#secrets).

## Rotating the admin key

1. `age-keygen -o ~/.config/sops/age/keys.txt` (back up the new key).
2. Update the `age:` recipients in `.sops.yaml`.
3. Re-key every file: `find . -name '*.sops.yaml' -exec sops updatekeys -y {} \;`
4. Commit. (Rotating the **cluster** key additionally means recreating the `sops-age`
   secret and letting Flux re-reconcile.)
