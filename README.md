# openinfra-substrate

A reproducible method for provisioning a **certified-track substrate** —
**SLES 15 SP7 + RKE2 under FIPS mode** — as an honest, point-in-time validation base for
[open-infra](https://github.com/harn3ss/open-infra). This is the layer the platform runs *on top of*.

> ⚠️ **Home-lab reference, NOT a certified build.** The Common Criteria and FIPS-140-3 stories cover
> SUSE's operating system and the Kubernetes cryptographic module — **not** this repository, and not
> automatically the orchestration layer. Nothing here is a certification. See
> [the honest claim](docs/runbook.md#the-honest-claim-tense-matters).

## What's here

```
provisioning/   the method — a node stages its own reimage via kexec, fired through the k8s API
  1-prep.sh              drain + pause work on the target nodes (non-destructive)
  stage-boot-server.sh  unpack the SLES Full ISO + serve it (+ profiles) over HTTP
  inject-regcode.sh      fill the eval reg-code from a (gitignored) .env into the profiles
  2-fire-node.sh         DESTRUCTIVE: kexec a node into the unattended AutoYaST installer
autoyast/       the profiles
  autoinst.template.xml  proven unhardened validation profile (FIPS-first, RKE2, key + password)
  autoinst-hardened.xml  the same + STIG hardening (partitions, SSH/PAM/auditd, crypto locks)
docs/
  runbook.md                    the full method, FIPS maintained-state, the honest claim
  stig-tailoring-exceptions.md  the k8s-vs-STIG conflicts, each with a compensating control
```

## Quickstart

```bash
sudo ./provisioning/stage-boot-server.sh SLE-15-SP7-Full-x86_64-GM-Media1.iso 8080
export BOOT_SERVER=http://<boot-server-ip>:8080
./provisioning/inject-regcode.sh ./.env          # your eval code; .env is gitignored
./provisioning/1-prep.sh
./provisioning/2-fire-node.sh <node> autoinst-hardened.xml
```

See [`docs/runbook.md`](docs/runbook.md) for the whole flow, the FIPS one-shot rationale, and what to
verify against SUSE's certifications page before making any claim.

## Secrets

This repo is public and carries **no** secrets. The eval registration code, SSH keys, root password
hash, and rendered per-node profiles are all `.gitignore`d — they live only in your local `.env` and
the boot server. Placeholders (`@@REG_CODE@@`, `@@SSH_PUBKEY@@`, `@@ROOT_PW_HASH@@`, `<boot-server-ip>`)
mark where your values go. Substitute your own subnet, hosts, and key.

## License

Apache-2.0 (see [open-infra](https://github.com/harn3ss/open-infra)).
