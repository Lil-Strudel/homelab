# Introduction

Welcome. These docs cover my homelab end to end — the network, the bare-metal
Kubernetes cluster, and how it's all kept declarative in one repo.

They're organized around three jobs:

- **Bootstrap** — bring the whole thing up from bare metal, in order.
- **Operations** — keep it running: secrets, storage, backups, observability, the
  applications on it, adding services, upgrades.
- **Decisions & Lessons** — why things are the way they are.

Plus **Reference** (hardware, network, versions) and the [Architecture](./architecture.md)
overview for the big picture. Start there, or jump to [Reference → Systems](./reference/systems.md)
and [Reference → Network](./reference/network.md).

---

{{#include ../../README.md}}
