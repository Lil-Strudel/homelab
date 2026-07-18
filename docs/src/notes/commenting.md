# Commenting

Comments and documentation do different jobs. Keep them separate.

## Inline comments

An inline comment earns its place only when it explains an **unobvious "why"
about the immediate code** — something the code itself can't say. If a
well-meaning cleanup would break things, say why:

```yaml
proxy:
  disabled: true # Cilium is the kube-proxy replacement — do NOT re-enable
```

Do **not** write inline comments that:

- restate what the next line already says (`# generate the config` above `gen ...`);
- narrate structure or ordering ("reconciled first", "user-facing workloads");
- read like documentation — provenance, rationale, version tables, how the
  pieces fit together.

That last kind is real and worth keeping — it just belongs in the docs, not
wedged into the source.

## Docs

Anything that reads like documentation goes in [`docs/`](https://github.com/Lil-Strudel/homelab/tree/main/docs)
(this mdBook), organized by topic:

- **Why a value is what it is** — pins, divergences from a chart default,
  version provenance → the relevant guide (e.g. *Creating the Rook-Ceph Config*).
- **How the pieces relate** — ordering, dependencies, the shape of the system
  → *Architecture*.
- **Conventions and layouts** — addressing, naming, staging → the *Plans*.
- **Reusable technique** — import steps, bring-up order → the guides.

## The test

Before writing a comment, ask: *is this an unobvious "why" about this exact
line?* If yes, inline it, tersely. If it's context, rationale, or a map of how
things connect, it's documentation — put it here instead.
