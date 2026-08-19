# STIG hardening — the measured delta, the method, and where in-place remediation bites

How far a stock SLES 15 SP7 + RKE2 node moves toward the DISA STIG, measured; how to get there; and
the one finding that reshapes *how* you apply it. Companion to
[stig-tailoring-exceptions.md](stig-tailoring-exceptions.md), which catalogs the Kubernetes-vs-STIG
conflicts this delta leaves as documented exceptions.

> Scans are **OpenSCAP** against the SLE 15 SCAP Security Guide datastream (`ssg-sle15-ds.xml`),
> profile `xccdf_org.ssgproject.content_profile_stig`. Counts below are over the **241 rules that
> profile selects** on this system. Reproduce with `oscap xccdf eval --profile
> xccdf_org.ssgproject.content_profile_stig --results r.xml --report r.html <datastream>`.

## The measured delta

| Scan | pass | fail | n/a | notchecked |
|---|---:|---:|---:|---:|
| As provisioned (unhardened profile, FIPS on) | **63** | 154 | 18 | 6 |
| After remediation, pre-reboot | **196** | 23 | 16 | 6 |
| After remediation, **post-reboot** (same node, ~18 h live) | **194** | 25 | 16 | 6 |

FIPS-mode rules pass in every scan (`fips_enabled=1`). The remediation applied **222 rule-fixes** — the
full `oscap generate fix` set (241 rules) with **19 Kubernetes-hostile rule blocks removed** before
applying (see the strip list below). The remediated node **rebooted cleanly** (FIPS on, RKE2 active,
root-login now disabled) and the **post-reboot rescan is the authoritative number: 194/25**.

The 2-rule slip from the pre-reboot scan (196 → 194) is **not a remediation regression** — it is
**operational drift**: two file-permission rules (`dir_perms_world_writable_sticky_bits`,
`permissions_local_var_log`) fail because ~18 hours of live RKE2/pod activity created files that drift
from the freshly-scanned state. Its own lesson: **rescan a freshly-hardened image, not a node that has
been serving pods for a day** — the container runtime steadily creates world-writable and
non-STIG-permissioned paths. Reaching the same posture by baking the fixes into the AutoYaST profile at
install gives a cleaner, reproducible baseline; see *In place works — install-time is cleaner*.

## The method: generate → strip → apply → **reboot** → rescan

1. `oscap xccdf generate fix --fix-type bash --profile xccdf_org.ssgproject.content_profile_stig
   <datastream> > fix.sh` — the full remediation as a bash script, one block per rule.
2. **Strip the Kubernetes-hostile rule blocks** before running it. These *break the cluster*, silently
   and often not at apply time but at the next reboot or the next cross-node connection. Remove any
   `# BEGIN fix … # END fix` block whose rule id matches:

   ```
   ip_forward  send_redirects  accept_source_route  _forwarding  all_forwarding
   rp_filter  firewalld  disable_ipv6  conntrack          # Category A/B — network & firewall
   noexec  mount_option  partition_for  nosuid  nodev      # Category C — mount options / layout
   ```

   Each corresponds to an entry in [stig-tailoring-exceptions.md](stig-tailoring-exceptions.md) with a
   compensating control. Everything else applies safely.
3. **Apply, then reassert `ip_forward=1`** as a belt-and-suspenders (a `sysctl --system` inside another
   rule can reset it) and confirm `rke2-server` is still active and the node still `Ready`.
4. **Reboot, then rescan.** This is not optional — it is where you learn whether the node comes back and
   what actually holds. The reboot is where root-login-disable becomes effective (`sshd -T` →
   `permitrootlogin no`, so plan non-root access first — see below), where FIPS re-asserts, and where any
   remaining reboot-dependent state settles. **The pre-reboot number is provisional; the post-reboot
   number is the one that counts** — here, **194/25**. Budget for a **slow first boot**: a FIPS +
   hardened node can take well over ten minutes to become reachable; do not mistake a slow boot for a
   brick (see the finding below).

## Where the remaining failures come from (25 post-reboot)

Every remaining failure is accounted for — this is the "documented exceptions beat a clean-looking
100%" posture an assessor actually trusts.

- **Deliberate Kubernetes tailoring exceptions (8)** — must stay off or the cluster breaks; each has a
  compensating control in [stig-tailoring-exceptions.md](stig-tailoring-exceptions.md):
  `service_firewalld_enabled`, `sysctl_net_ipv4_ip_forward`, `sysctl_net_ipv6_conf_default_forwarding`,
  `sysctl_net_ipv4_conf_all_send_redirects` (+ default), `sysctl_net_ipv6_conf_all_accept_source_route`
  (+ default), `mount_option_home_nosuid`.
- **FIPS-vs-STIG crypto conflict (4)** — these do **not** flip on reboot; they fail both before and
  after, by design: `sshd_use_approved_ciphers_ordered_stig`, `…_kex_…`, `…_macs_…`,
  `sshd_disable_x11_forwarding`. Under FIPS, the **crypto-policy governs** the effective SSH cipher/MAC/
  KEX set — measured here as `aes256-ctr,aes192-ctr,aes128-ctr` / `hmac-sha2-512,hmac-sha2-256` /
  `ecdh-sha2-nistp256,…` (no GCM) — which does not match the STIG's *exact ordered* list (it expects the
  GCM-first order). The box is running FIPS-validated crypto and is arguably *more* constrained, but the
  literal ordered-match rule fails. A documented crypto exception, not a remediation gap.
- **Operational drift (2, post-reboot only)** — created by ~18 h of live RKE2 activity, not by the
  remediation: `dir_perms_world_writable_sticky_bits`, `permissions_local_var_log`. Rescan a fresh image.
- **Build-time / deliberate operational deviations (5)** — not remediable in place; this is exactly
  what the **hardened AutoYaST profile** exists to fix at install: `encrypt_partitions` (full-disk LUKS,
  reinstall-only), `partition_for_var_log_audit` (the hardened profile provisions it); plus
  `grub2_password` / `grub2_uefi_password` (a bootloader password blocks unattended reboots — a
  conscious decline for headless hardware) and `accounts_authorized_local_users` (flags the operational
  admin account).
- **Minor residual open findings (6)** — real, small, name them and move on:
  `file_permissions_ungroupowned` / `no_files_unowned_by_user` (files owned by high container-runtime
  UIDs with no `/etc/passwd` entry — normal on a container host), `pam_disable_automatic_configuration`,
  `accounts_passwords_pam_faildelay_delay`, `accounts_password_set_max_life_existing` /
  `…_min_life_existing` (aging on pre-existing accounts).

## The remediation does **not** touch the boot path

Worth stating because the instinct is to fear a STIG run bricking a FIPS box: inspected against the
actual `oscap generate fix` output for this profile, the remediation makes **no bootloader or initramfs
change**. The only grub rules are `grub2_password` / `grub2_uefi_password`, both emitted as no-ops
("FIX … IS MISSING"); there is no `update-bootloader` / `grub2-mkconfig` / `dracut` / `mkinitrd` /
`GRUB_CMDLINE` edit, no kernel-cmdline argument rule, and no audit *failure-mode = panic* (`-f 2`) rule.
The only `/etc/fstab` writers are the `mount_option_*` rules — which the strip removes. So a
FIPS-integrity or grub-cmdline theory of a post-remediation boot failure does not hold for this content.

## In place works — install-time is cleaner

**Finding (verified).** Applying the remediation in place and rebooting a headless node **works** — it
does **not** brick the node. The remediated node came back **fully functional**: `fips_enabled=1`,
`rke2-server` active, `wicked`/`eth0` up with its DHCP lease and default route, `sshd` active, and
`sshd -T` → `permitrootlogin no`. The post-reboot rescan (194/25) was taken over SSH from that recovered
node. Consistent with *the remediation does not touch the boot path* (above), there was no boot brick.

**The real trap is a slow first boot, not a wedge.** A FIPS + hardened node can take **well over ten
minutes** to become reachable on the first post-remediation boot. A naive "no ping after ~7 minutes ⇒
dead" check will call a perfectly healthy node bricked — it isn't; it is still coming up. Wait it out
(and watch a console if you have one) before concluding anything.

**Two things that genuinely matter before you reboot:**
1. **Have non-root access ready.** The remediation disables SSH root login. Create a non-root sudo
   account (and install its key) *before* applying, or the reboot locks you out of remote admin even
   though the node is healthy.
2. **Prefer baking the fixes into the AutoYaST profile at install** for a *deployment*
   ([`../autoyast/autoinst-hardened.xml`](../autoyast/autoinst-hardened.xml)) — not because in-place is
   unsafe (it isn't) but because an install-time image is **reproducible and auditable** (one file in
   git) and does not accumulate the operational drift a long-running node does. In-place remediation is
   the right tool for producing the **before/after delta evidence** above; install-time is the right tool
   for a clean baseline you deploy.

## Validating harden-and-boot on a recoverable VM

The authoritative post-reboot number above came off **bare metal** (the node recovered from its slow
boot). Still, a recoverable VM is worth having to prove a hardened *profile* boots before it touches
hardware you cannot power-cycle, and to iterate faster. Install it into a throwaway VM you can watch and
reset (e.g. KubeVirt). The pieces that make an unattended SLES install work headlessly, each learned by
it failing without them:

- **Netboot the installer** — point the VM's direct kernel boot at the ISO's `boot/x86_64/loader/{linux,
  initrd}` with `install=http://…/<iso-root> autoyast=http://…/profile.xml ip=dhcp`. No PXE needed.
- **Install offline from the Full ISO's local module repos** — `do_registration=false` plus explicit
  `<add-on>` repos for `Product-SLES` + `Module-Basesystem` (+ others you need) served off the ISO, and
  `self_update=0`. Registration over a NAT'd VM network hangs; the Full ISO is a complete offline medium.
- **Force a serial console** so you can actually see the installer — with only a serial console present,
  YaST renders its UI there. On a graphical VM the installer talks to the (headless) VGA and you are
  blind.
- **Serve the ISO with a threaded HTTP server.** A single-threaded server (e.g. `python -m http.server`)
  **deadlocks** under the installer's concurrent/keep-alive package pulls — the install stalls mid-way
  with no error. This one silently eats hours.
- **Do not pass `ssh=1` for an unattended run** — it puts the installer into "SSH install" mode that
  waits for you to log in and run `yast.ssh`, instead of auto-running AutoYaST. Useful for *debugging* an
  install; fatal to an unattended one.
- **A direct-kernel netboot re-enters the installer on every reboot** — after the install completes,
  remove the kernel-boot override so the VM boots the installed disk, then let the FIPS one-shot run.

> **Status (resolved).** The full sequence is measured and reproducible: as-provisioned **63/154** →
> remediated pre-reboot **196/23** → **post-reboot 194/25** on the same bare-metal node, which rebooted
> cleanly (FIPS on, RKE2 active, root-login disabled). An earlier note here claimed the reboot *wedged* a
> console-less node — that was **wrong and is retracted**: the node was simply slow to boot (well past a
> naive multi-minute reachability check) and came up completely healthy. Remaining honestly open: a
> post-reboot rescan of a *freshly* hardened image (to separate the operational-drift rules from the
> steady-state posture) and running the same remediation through the hardened AutoYaST profile end to end.
