# STIG tailoring exceptions — SLES 15 SP7 running RKE2

_The rules that conflict with Kubernetes, why, and what compensates. This is the
part nobody writes down — and the part an assessor actually reads. Every entry is
one of three verdicts and each conflict names a compensating control._

**The distinction that matters in an authorization package:** "failed the check"
vs. "failed for a legitimate, documented reason." A package with acknowledged,
explained exceptions is trusted *more* than one claiming a clean 100%.

---

## Category A — sysctl / network (Kubernetes IS a router)

STIG assumes a server that does one job and talks to a few known peers. A
Kubernetes node is a router, a NAT device, and a mesh endpoint. These are the
sneaky ones — several degrade a path rather than breaking outright, which with
Canal's VXLAN overlay shows up as *partial* packet loss on a cluster that still
looks healthy.

| STIG rule (class) | STIG wants | Conflict | Verdict | Compensating control |
|---|---|---|---|---|
| `net.ipv4.ip_forward` | 0 (off) | Pods on other nodes are unreachable; CNI dead | **Exception** | East-west traffic constrained by NetworkPolicy (default-deny) + Canal; forwarding is required, not incidental |
| `net.ipv4.conf.all.send_redirects` | 0 | Degrades specific overlay paths | **Exception (partial)** | Overlay is VXLAN-encapsulated; ICMP redirects not used for pod routing |
| `net.ipv4.conf.all.accept_source_route` | 0 | Interacts badly with overlay return paths | **Verify per-cluster** | Keep 0 if cluster healthy after; this one is often safe to enforce — test |
| reverse-path filtering / `rp_filter` | strict | VXLAN asymmetry → silent drops | **Exception** | Leave at loose/CNI-managed value; document the measured drop test |
| conntrack max / hashsize | STIG caps | Too low starves kube-proxy | **Exception** | Sized up for cluster scale; monitored via node metrics |

> Do not blanket-apply the sysctl STIG group. Enforce case by case and rescan;
> the ones that "pass" without breaking the cluster are free wins, the rest are
> exceptions with the CNI rationale.

---

## Category B — host firewall

| STIG rule | STIG wants | Conflict | Verdict | Compensating control |
|---|---|---|---|---|
| firewalld enabled, default-deny | on | Blocks API (6443), supervisor (9345), kubelet (10250), etcd peers, Canal VXLAN (8472/udp), NodePort range → node can't join, and it fails *later* when a node first reaches an unseen peer | **Exception, conditional** | Host firewall MAY be enabled only with the full RKE2 port inventory allowed (see rke2/ layer). If enabled without the inventory it partitions the cluster. Default posture: managed at the RKE2 layer, not by the STIG firewalld rule |

---

## Category C — partition / mount options

Handled declaratively in AutoYaST (`autoyast/autoinst-hardened.xml`), which is
why they're exceptions *by design* rather than remediation targets.

| STIG rule | STIG wants | Conflict | Verdict | Compensating control |
|---|---|---|---|---|
| `noexec` on `/var` | set | containerd unpacks & **executes** image layers under `/var/lib/rancher/rke2/agent/containerd`; kubelet dir; Longhorn stages replicas under `/var/lib/longhorn`. Every container fails to start with permission-denied errors that look nothing like a mount problem | **Exception** | `/var` mounted `nodev,nosuid` (not `noexec`); execute is scoped to the container runtime tree; broader `/var/log`, `/var/tmp`, `/tmp` keep full `nodev,nosuid,noexec` |
| `nodev` on `/var` | set | Breaks Longhorn block-device attach / CSI device nodes if applied to the CSI staging path | **Partial / verify** | `nodev` on `/var` is generally safe; confirm Longhorn attach after. If it breaks, scope nodev off the CSI staging subtree only |
| separate `/var`, `/var/log`, `/var/log/audit`, `/tmp`, `/var/tmp`, `/home` | set | None — this is compatible and done | **Fixed** | Provisioned at install via AutoYaST; sized so `/var` (images) doesn't trigger kubelet disk-pressure eviction |

---

## Category D — everything else

The large majority of STIG rules have no Kubernetes conflict and are simply
**fixed** — login.defs/PAM password policy, SSH ciphers/MACs/kex, auditd rules,
package minimization, banner, FIPS mode. These are set in the AutoYaST profile
and should scan green. Anything in this category that still fails post-build is
an **acknowledged open finding**, not an exception — name it and move on.

---

## How this maps to the measured delta

The measured before/after — as-provisioned **63/154** pass/fail → after remediation **196/23** over the
241 selected rules — is in [stig-hardening.md](stig-hardening.md), with the remediation method and a full
accounting of the 23 remaining failures. Every one falls into a named bucket:

- **Category A/B/C exceptions (this file):** the network sysctls, `firewalld`, and the `/var`/`/home`
  mount options above — must stay non-compliant or the cluster breaks; each carries a compensating
  control. These are the bulk of the deliberate remaining failures.
- **Build-time items:** disk encryption and the separate audit partition are provisioned by the hardened
  AutoYaST profile, not by in-place remediation; a bootloader password is a conscious decline on
  headless hardware.
- **A handful of minor open findings** (unowned container-UID files, existing-account aging) — named,
  not hidden.

The posture that matters: **documented exceptions + named open findings, zero *undocumented* failures**,
and the number only counts **after reboot-then-rescan**.
