# Runbook — provisioning a certified-track SLES + RKE2 + FIPS substrate

How to stand up nodes on **RKE2-on-SLES 15 SP7 under FIPS mode**, as a reproducible, honest,
point-in-time validation substrate for open-infra. This documents the method that was actually used;
the scripts in [`../provisioning/`](../provisioning) implement it.

> **This is a home-lab reference, not a certified build.** The OS Common Criteria story and the
> FIPS-140-3 crypto modules cover SUSE's OS and the Kubernetes crypto module — **not** this repo,
> and not automatically the orchestration layer. Read [the honest claim](#the-honest-claim-tense-matters).

## The provisioning method: kexec-into-AutoYaST, fired through the k8s API

No PXE, no TFTP, no BMC/console. A node currently running Ubuntu + k3s **stages its own replacement**:
`2-fire-node.sh` schedules a privileged pod onto the target node, `nsenter`s into the host, installs
`kexec-tools`, fetches the SLES installer over HTTP, and `kexec`s straight into an unattended AutoYaST
install that wipes the disk and lays down RKE2-on-SLES. This works on management-controller-less
hardware because it drives entirely over the existing cluster API.

```
node (Ubuntu+k3s)  --2-fire-node.sh-->  privileged pod (nsenter host)
                   -->  kexec SLES installer (install= + autoyast= over HTTP)
                   -->  unattended AutoYaST  -->  reboot into RKE2-on-SLES (FIPS-first)
```

### Steps

1. **Stage the boot server** (a host on the subnet, not a node being wiped):
   `sudo ./provisioning/stage-boot-server.sh SLE-15-SP7-Full-x86_64-GM-Media1.iso 8080`
   then `export BOOT_SERVER=http://<boot-server-ip>:8080`.
2. **Inject the eval code** into the profiles from your (gitignored) `.env`:
   `./provisioning/inject-regcode.sh ./.env` — renders `autoinst-cn*.xml` (also gitignored) and
   copies them into the boot server's `/profiles`.
3. **Prep** (drain + pause scheduled work): `./provisioning/1-prep.sh`.
4. **Fire** each node:
   `BOOT_SERVER=$BOOT_SERVER ./provisioning/2-fire-node.sh chaos-node-2 autoinst-hardened.xml`
   (unhardened validation profile: `autoinst.template.xml`; hardened build: `autoinst-hardened.xml`).

Find a freshly-installed node's IP by its new `:22` (`nmap -p22 --open <subnet>`), or the DHCP leases.

## The two profiles

- **`autoyast/autoinst.template.xml`** — the proven **unhardened** validation profile: registration
  (4 modules incl. Certifications), FIPS packages at install, a root password **and** an injected
  ECDSA SSH key (FIPS disables Ed25519), firewalld disabled (SLE15 firewalld blocks RKE2/Canal
  ports), RKE2 installed, and the **FIPS-first one-shot** (below).
- **`autoyast/autoinst-hardened.xml`** — the same skeleton **plus STIG hardening**: the separate-
  partition layout with `nodev,nosuid` (and `noexec` everywhere except `/var` — see
  [stig-tailoring-exceptions.md](stig-tailoring-exceptions.md)), SSH ciphers/MACs/kex, PAM/login
  policy, auditd rules, and certified-crypto RPM version-locks. The SSH key is injected **before**
  `PasswordAuthentication no`, so there is no lockout window.

## FIPS — the maintained-state part

FIPS on SLES is two things: **turn on FIPS mode**, and **install + lock the certified modules**.

- FIPS packages (`patterns-base-fips`, `dracut-fips`, `crypto-policies-scripts`) are installed at
  main-install time, so the first-boot one-shot needs no `zypper` (YaST holds it locked on first boot).
- The **`openinfra-fips.service` one-shot** runs on first boot: `fips-mode-setup --enable`, enable
  `rke2-server`, then reboot into `fips=1`. RKE2 therefore only ever starts — and joins etcd — **under
  FIPS**. Starting RKE2 pre-FIPS and rebooting an etcd member for FIPS afterward breaks quorum on
  multi-server joins (learned the hard way). The unit **must** carry `[Install] WantedBy=multi-user.target`
  or `systemctl enable` silently no-ops and the one-shot never runs.
- **Version-lock the certified crypto RPMs** (`zypper addlock`) at their exact certified versions. This
  is *why* certification is a maintained state: an unpinned `zypper up` can replace a certified binary
  with a newer uncertified one and silently drop the box out of the evaluated configuration.

> SLES 15 **SP7 was submitted for Common Criteria but not for FIPS 140-3**; the FIPS modules trace to
> the **SP6** CMVP work, delivered into SP7. Which SP holds which live certificate is a maintained-state
> fact — **verify on `suse.com/support/security/certifications` before making any claim.** RKE2 carries
> FIPS at the Kubernetes crypto layer (the normal Linux/AMD64 artifacts are FIPS-built; there is **no
> separate `-fips` channel**), and its default **Canal** CNI is the only one rebuilt for FIPS.

## RKE2 notes

- Keep **Canal** (default CNI) — Cilium/Calico/Multus are not FIPS-rebuilt.
- SLES uses **AppArmor**, not SELinux — don't carry over OpenShift SELinux assumptions.
- SLES `firewalld` is aggressive; either disable it or open the full RKE2 port inventory (6443, 9345,
  10250, Canal VXLAN 8472/udp, etc.) or the cluster won't form. See
  [stig-tailoring-exceptions.md](stig-tailoring-exceptions.md) Category B.
- Restricted Pod Security rejects hardcoded `runAsUser` across a class of manifests — bring a
  `runAsUser` overlay rather than fighting it in the eval window.

## The honest claim (tense matters)

**After a clean run you may say:**

> "It **was validated** running on a stack whose OS is Common-Criteria-certified and whose Kubernetes
> cryptographic module is FIPS-140-3-validated, on `<date>`, under FIPS mode."

**You may not say** ~~"is FIPS/CC certified"~~ (the certs cover the OS + crypto module, not the
orchestration layer) or ~~"runs on a certified stack"~~ in the present tense (once the subscription
lapses the box drifts out of the evaluated config). **The validation event stays true; the state does
not.** The deployer brings their own maintained, subscribed, certified substrate; this repo is how you
prove software runs clean on one.

## Capture the evidence artifact

The deliverable is a **dated, hashed, point-in-time record**, not a running state: `fips-mode-setup
--check`, the locked certified RPM versions (`zypper locks`), node/RKE2 versions, the OpenSCAP + CIS
scan outputs, the chaos results with oracle output, and a snapshot of the certifications page showing
which cert was live on that date. Bundle + hash + date it.

## Confidence flags — verify before relying

- The certified crypto RPM list + versions, and which SP holds the live CC/FIPS certs on your install
  date — `suse.com/support/security/certifications` + `SUSEConnect --list-extensions`.
- Every AutoYaST element name against the **SP7** schema — a wrong tag fails silently into a half-install.
- RKE2's current FIPS-140-3 cert number/status on NIST CMVP.
- The SUSE eval length + current terms on the download page.
