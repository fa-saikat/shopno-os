# Self-hosted runner — recovery runbook

Disposable Debian VM on local libvirt that registers itself as a
GitHub Actions runner. Proved dead-and-reborn via destroy/apply
(T5). All commands run from this directory unless noted.

## Prereqs

- `terraform` (any recent 1.x), `libvirt` system daemon, user in
  the `kvm` and `libvirt` groups, `/dev/kvm` present.
- Storage pool `iso` with 60+ GB free (the `default` pool is too
  small on this host — T0 measured 41 GB free).
- A runner registration token, fresh (1 h expiry):
  `gh api --method POST /repos/fa-saikat/shopno-os/actions/runners/registration-token --jq '.token'`

## Bring it up (T3 verbatim)

```bash
TF_VAR_github_token=<jit-or-pat> terraform apply
```

## Prove it (all three, every time)

```bash
virsh --connect qemu:///system list
gh api repos/fa-saikat/shopno-os/actions/runners \
  --jq '.runners[] | {name, status, labels: [.labels[].name]}'
terraform plan   # expect: no changes (convergence, not drift)
```

Expect: domain `shopno-iso-builder` running; runner `online`
with labels `self-hosted,linux,iso-builder,kvm` (plus the
automatic `Linux,X64`); plan exit 0.

## Reach the guest

```bash
virsh --connect qemu:///system domifaddr shopno-iso-builder
ssh -i ~/.ssh/gh builder@<lease-ip>
```

No `virsh console`: the 0.9 provider cannot express a pty serial
without a hardcoded host path, so this domain ships VNC only.
Guest eyes without SSH: QEMU screendump
(`virsh qemu-monitor-command ... --hmp "screendump /tmp/x.ppm"`)
or the qemu-agent channel
(`virsh qemu-agent-command ... '{"execute":"guest-ping"}'`).
Stale DHCP leases linger — always match the lease MAC against
`virsh domiflist` before trusting an address.

## Rebuild / destroy

```bash
terraform destroy   # everything is disposable by design
```

## Gotchas learned (T3)

- AppArmor emits a per-domain profile with no `.files` list for
  this layout, silently denying every disk open. The domain sets
  `sec_label = [{ type = "none" }]`, matching this host's existing
  domains (none carry a seclabel).
- The cloud-init seed volume must omit `target.format` (provider
  auto-detects iso). A forced `qcow2` makes the seed unreadable;
  forcing `raw` trips a provider read-back bug.
- `network_config` must match `driver: virtio_net` (the kernel
  name, not the virtio model string), or the guest gets no DHCP.
- cloud-init runs once per `instance-id`: bump it on any seed
  change or reboots silently skip the new config.
- `svc.sh install/start` resolve relative to CWD — `cd` into the
  runner dir first or they die with "Must run from runner root".
- Headless: `APT::Install-Recommends "false"` keeps
  `qemu-system-x86` from dragging a GTK stack along.
- Token never enters git: `TF_VAR_github_token` env only, and
  never print a full `plan`/`show` (rendered `user_data` carries
  the secret). Filter output to resource lines.

## T5 record (cutover + rebirth)

- Destroy: 2026-10-01, 6 resources removed, virsh clean.
- Rebirth minutes later: 6 added, runner online in 6 min,
  service born with kvm groups, plan exit 0 (no changes).
- Proof run 36845248152 (PR #85): desktop SUCCESS Oct 1
  (package 1822, boot PASSED, uploaded); core rebuilt Oct 4
  after a root-owned workspace blocked checkout — package
  PASSED (784), boot PASSED with the KVM line, upload red
  solely on artifact quota (`CreateArtifact: quota has been
  hit`), which is environmental per policy, not a verdict.
- T4 probes: 36822999141 (green, TCG — stale groups),
  36826135264 (green, KVM). Core 23 min, +8 GB per build.
- Operator notes: wipe root-owned `build/` between jobs until
  T6 automates post-job cleanup; always match lease MAC to
  `domiflist`; `git`+`rsync` are declared runner deps since
  no-recommends exposed their absence (exit 127).
