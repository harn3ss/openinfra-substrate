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
| After remediation (pre-reboot) | **196** | 23 | 16 | 6 |
| Δ | **+133** | −131 | | |

FIPS-mode rules pass in both scans (`fips_enabled=1`). The remediation applied **222 rule-fixes** — the
full `oscap generate fix` set (241 rules) with **19 Kubernetes-hostile rule blocks removed** before
applying (see the strip list below). Reaching the same target the other way — baking the fixes into the
AutoYaST profile at install — is the recommended path; see *Harden at install, not in place*.

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
4. **Reboot, then rescan.** This is not optional. Several fixes only take effect — or only *verify* — on
   reboot: the SSH cipher/kex/MAC ordering rules verify against `sshd -T` (effective config), so they
   read as failing until sshd reloads; auditd rule reload; any mount changes. **The pre-reboot number is
   provisional; the post-reboot number is the one that counts.**

## Where the 23 remaining failures come from

Every remaining failure is accounted for — this is the "documented exceptions beat a clean-looking
100%" posture an assessor actually trusts.

- **Deliberate Kubernetes tailoring exceptions (8)** — must stay off or the cluster breaks; each has a
  compensating control in [stig-tailoring-exceptions.md](stig-tailoring-exceptions.md):
  `service_firewalld_enabled`, `sysctl_net_ipv4_ip_forward`, `sysctl_net_ipv6_conf_default_forwarding`,
  `sysctl_net_ipv4_conf_all_send_redirects` (+ default), `sysctl_net_ipv6_conf_all_accept_source_route`
  (+ default), `mount_option_home_nosuid`.
- **Flip to pass on reboot (4)** — config written, effective on sshd reload:
  `sshd_use_approved_ciphers_ordered_stig`, `…_kex_…`, `…_macs_…`, `sshd_disable_x11_forwarding`.
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

## Harden at install, not in place

**Finding.** Applying the remediation in place and then rebooting a node with **no out-of-band console**
can wedge it in early boot (no network, unrecoverable). Because the remediation touches no boot config
(above), the trigger is elsewhere — a file-permission/ownership change that breaks a boot-critical unit,
or an interaction with an AutoYaST **second stage that never completed** (a hung `YaST2-Second-Stage`
leaves bootloader/fstab finalization incomplete, and the first clean reboot exposes it). Pinning the
exact cause needs a console you can watch.

**Recommendation.** Bake the hardening into the **AutoYaST profile at install time**
([`../autoyast/autoinst-hardened.xml`](../autoyast/autoinst-hardened.xml)), prove the resulting image
boots in a **recoverable** context, and *then* deploy. Do not post-hoc remediate a live, headless node
and reboot it hoping. The real dependency is **out-of-band console / BMC access** (or the VM test bed
below) — not more remediation cleverness. In-place remediation is fine for producing the *delta
evidence* above on a node you can afford to lose; it is not a deployment method for one you cannot reach.

## Validating harden-and-boot on a recoverable VM

To prove a hardened profile *boots* before it touches bare metal, install it into a throwaway VM you can
watch and power-cycle (e.g. KubeVirt). The pieces that make an unattended SLES install work headlessly,
each learned by it failing without them:

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

> **Open item (honest status).** The *as-provisioned → remediated* delta above is measured and
> reproducible. The **authoritative post-reboot rescan of a fully hardened image** — the number that
> "counts" per *reboot-then-rescan* — is still being captured on the recoverable VM path; a bare-metal
> in-place attempt reached the pre-reboot 196/23 but the reboot wedged a console-less node, which is the
> finding above. This page will carry the post-reboot number once the VM cycle completes.
