# tailscale-bulk-join

**Bulk-deploy [Tailscale](https://tailscale.com) across every LXC container and VM on a Proxmox VE node — in one command.**

`tailscale-bulk-deploy.sh` scans a Proxmox host, finds every running guest, installs Tailscale where it's missing, and enrolls each one into your tailnet. It's idempotent: guests that are already connected are skipped, so you can run it as often as you like (e.g. after spinning up new containers) and it only touches what needs touching.

---

## Features

- **Covers both LXC containers and QEMU/KVM VMs** on the node.
- **Idempotent** — already-connected guests are detected and skipped; safe to re-run.
- **Auto-configures `/dev/net/tun`** for containers (adds the cgroup allow + bind mount to the container config and reboots once when needed). A container that already has `/dev/net/tun` via Proxmox Device Passthrough (`devN: /dev/net/tun` or `devN: path=/dev/net/tun,…` in its config) is recognized as configured and is left alone.
- **Checks for `/dev/net/tun` on the host** and only loads (and persists) the `tun` module when it is missing — on Proxmox VE the kernel normally has `tun` built in, so the device already exists.
- **Multi-distro guest support** — installs prerequisites via `apt`, `apk`, `dnf`, or `yum`.
- **Automatic retry** — if the first join fails (a known `tailscaled` startup race), the guest is rebooted and the join is retried once.
- **Fails fast on a bad auth key** — if the control server *rejects* the key (invalid, expired, or a single-use key already consumed), the script recognizes it, skips the pointless reboot-and-retry, and stops attempting further enrolls instead of rebooting the rest of your fleet against a dead key.
- **Resilient scan** — a failure on one guest never aborts the rest of the run.
- **Full run log** written to `/root/tailscale-bulk-<timestamp>.log`, plus a success/skip/fail summary at the end.

---

## Requirements

| Where | Requirement |
|-------|-------------|
| Proxmox host | Run as **root** on a Proxmox VE node (`pvesh`, `pct`, `qm` available). |
| Proxmox host | `jq` (the script auto-installs it on Debian-based hosts). |
| You | A valid, **reusable** **Tailscale auth key** (`tskey-auth-…`). [Generate one here.](https://login.tailscale.com/admin/settings/keys) A single-use key only enrolls **one** guest — the first one consumes it and every guest after that is rejected. |
| VMs only | `qemu-guest-agent` must already be **installed and running inside the VM**. See [VMs vs. containers](#vms-vs-containers). |
| Guests | A POSIX `/bin/sh` (bash is not needed, so stock Alpine works). |

---

## Quick start

```bash
# 1. Get the script onto your Proxmox node, then:
git clone https://github.com/thelorax1775/tailscale-bulk-join.git
cd tailscale-bulk-join
chmod +x tailscale-bulk-deploy.sh

# 2. Export a Tailscale auth key
export TS_AUTHKEY='tskey-auth-xxxxxxxxxxxxxxxxxxxxxxxx'

# 3. Run it as root
./tailscale-bulk-deploy.sh
```

That's it. The script prints progress to your terminal and writes a full log to `/root/`.

> **Tip:** use a [**reusable, pre-authorized** auth key](https://tailscale.com/kb/1085/auth-keys) so you don't have to approve every guest in the admin console. Consider tagging (see `TS_EXTRA_ARGS` below) so all the machines land in an easy-to-manage group.

---

## Configuration

Everything is driven by environment variables — there are no positional arguments.

| Variable | Required | Default | Description |
|----------|:--------:|---------|-------------|
| `TS_AUTHKEY` | ✅ | — | Your Tailscale auth key (`tskey-auth-…`). |
| `TS_EXTRA_ARGS` | | _(empty)_ | Extra flags appended to every `tailscale up` call, e.g. `--ssh --accept-routes --advertise-tags=tag:prox`. |
| `TS_HOSTNAME_PREFIX` | | `ct-` / `vm-` | Override the hostname prefix used at enrollment. By default containers enroll as `ct-<id>` and VMs as `vm-<id>`; set this to force a single prefix for both. |
| `TS_LOGIN_SERVER` | | _(Tailscale)_ | Point at a custom control server (e.g. [Headscale](https://github.com/juanfont/headscale)). Passed as `--login-server=<url>`. |
| `PVE_NODE` | | `$(hostname -s)` | Node name to scan. Override if the short hostname doesn't match your PVE node name. If the node cannot be listed the script stops with an error. |

### Examples

Enroll everything with Tailscale SSH enabled and a tag:

```bash
export TS_AUTHKEY='tskey-auth-…'
export TS_EXTRA_ARGS='--ssh --advertise-tags=tag:proxmox'
./tailscale-bulk-deploy.sh
```

Point at a self-hosted Headscale control server:

```bash
export TS_AUTHKEY='…'
export TS_LOGIN_SERVER='https://headscale.example.com'
./tailscale-bulk-deploy.sh
```

Show the built-in help:

```bash
./tailscale-bulk-deploy.sh --help
```

---

## What it does, step by step

1. **Preflight** — verifies it's running as root on a Proxmox node, that `TS_AUTHKEY` is set, ensures `jq` is present, and checks that `/dev/net/tun` exists on the host (loading and persisting the `tun` kernel module only when it is missing; on Proxmox VE the kernel normally has `tun` built in).
2. **Scan LXC containers** (`pvesh get /nodes/<node>/lxc`). For each *running* container:
   - Skip if Tailscale is already up and has a `100.x` address.
   - Ensure `/dev/net/tun` is exposed to the container (edit config + reboot once if it wasn't).
   - Install Tailscale if missing.
   - `tailscale up` with your auth key, enrolling as `ct-<id>`.
   - On failure: reboot the container and retry once, dumping the last 15 `tailscaled` journal lines if it still fails — **unless** the failure is an auth-key rejection, in which case it fails fast (no reboot) and stops attempting further enrolls.
3. **Scan VMs** (`pvesh get /nodes/<node>/qemu`). For each *running* VM with a **responding guest agent**:
   - Same install → join → retry flow, executed inside the guest via the QEMU guest agent, enrolling as `vm-<id>`.
4. **Summary** — prints `Success / Skipped / Failed` counts and the log path.

---

## VMs vs. containers

**Containers (LXC)** are fully automatic. The Proxmox host can run commands directly inside a container with `pct exec`, so the script can install Tailscale, tweak the container config for `/dev/net/tun`, reboot, and join — all unattended.

**VMs** are different. There is **no way to run a command inside a VM's OS from the host** unless the [QEMU guest agent](https://pve.proxmox.com/wiki/Qemu-guest-agent) is installed and running *inside* the guest. The script cannot bootstrap the agent remotely — that's a chicken-and-egg problem. So:

- VMs **with** a responding guest agent are handled automatically, just like containers.
- VMs **without** one are **skipped** with a message telling you to install `qemu-guest-agent` once (via console or SSH). After that, re-run the script and it will pick them up.

To enable the agent on a Debian/Ubuntu VM:

```bash
# inside the VM
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

…and make sure the QEMU Guest Agent option is enabled for the VM in Proxmox (**VM → Options → QEMU Guest Agent**), then reboot the VM once.

---

## Notes, caveats & troubleshooting

- **Container configs with snapshots.** Proxmox keeps snapshots in the same `/etc/pve/lxc/<id>.conf`, under `[name]` headers. The script only reads and edits the live part, the lines before the first header: the TUN lines are inserted just above the first snapshot header (or at the end when there are none), and TUN lines that exist only inside a snapshot do not count as configured. Before the first edit it copies the config to `<id>.conf.bak-tailscale-bulk` next to it; that backup is made once and never overwritten. **If the config cannot be written, the container is reported as failed and is not touched further.**
- **Unprivileged containers.** TUN bind-mounts frequently fail at runtime for unprivileged containers that lack a matching `lxc.idmap`. The script proceeds and warns you — **verify these manually** afterward. If a join fails on an unprivileged CT, that's the first thing to check.
- **The script checks for `/dev/net/tun` on the host and only loads the `tun` module when the device is missing.** On Proxmox VE the kernel normally has `tun` built in, so `/dev/net/tun` already exists and no action is needed. If the device is missing, the script attempts to load the module and persists it to `/etc/modules-load.d/tun.conf` so it survives a host reboot.
- **`--reset` is used on join.** Each fresh enroll runs `tailscale up --reset …`, which clears any previous, non-default `tailscale up` settings on that guest. This keeps enrollment deterministic; if you rely on per-guest flags, bake them into `TS_EXTRA_ARGS`.
- **Auth key visibility.** The key is sent to each guest on **stdin** (`pct exec` / `qm guest exec --pass-stdin`), so it is not in the command line of any process on the Proxmox host. Inside the guest it is an argument of the `tailscale up` process while that runs, so a root user in the guest could see it in `ps` for those few seconds. Everything the guests print is passed through a filter that replaces the key and anything shaped like `tskey-…` before it reaches the screen or the log, so the key is **not** written to the log file. Prefer short-lived / reusable keys and rotate them after a bulk run.
- **Logs.** Every run is teed to `/root/tailscale-bulk-<timestamp>.log`. Failed joins include the last 15 lines of the guest's `tailscaled` journal to speed up diagnosis.
- **`invalid key … not valid` / one guest joins then the rest fail.** The control server rejected your auth key. The classic tell is a run where the *first* fresh enroll succeeds and every one after it fails with `invalid key`: that's a **single-use key** — the first guest consumed it. Generate a **reusable, pre-authorized** key ([keys page](https://login.tailscale.com/admin/settings/keys)) and re-run; already-joined guests are skipped, so only the stragglers are enrolled. Expired keys and disallowed `--advertise-tags` produce the same fail-fast path. (Note: the short ID in the error, e.g. `kGqPFaeTiV11CNTRL`, is Tailscale's internal handle for the key, **not** your secret.)
- **Nothing happens / everything skipped.** That's the expected result on a second run — every guest is already in the tailnet. 🎉

---

## Safety

This script modifies guest configurations (container `.conf` files), reboots guests when required, and installs software inside them. It's designed to be safe and idempotent, but you are running it against your whole node — **read it first** (it's a single, well-commented Bash file) and consider trying it on a single test guest before a full sweep.

---

## Project status

Feature-complete single-script tool, maintained with tests and CI since November 2026. The repository was previously named `TailAdjuster`.

**Tests and CI.** Every pull request and every push to `main` runs `bash -n`, [ShellCheck](https://www.shellcheck.net/) and a [bats](https://github.com/bats-core/bats-core) test suite on GitHub Actions (`.github/workflows/ci.yml`). The suite in `tests/` runs the real script against a fake node: `pct`, `qm`, `pvesh` and the in-guest commands (`tailscale`, `apt`/`apk`/`dnf`/`yum`, `curl`, `systemctl`) are stubs from `tests/stubs/`, and everything it writes goes to a temp dir. It covers the auth-key error detection and fail-fast, the skip rules, the reboot-and-retry-once flow, the TUN config edit, the counters and summary, and `--help`.

What that does **not** prove: the tests never touch a real Proxmox node, guest or tailnet. The `apk`, `dnf` and `yum` install paths in particular are exercised with stubs only, not on real Alpine, Fedora or CentOS guests, and end-to-end behaviour on a live node is not verified in this repo.

To run the checks yourself (needs `bats`, `shellcheck` and `jq`; no root, no Proxmox):

```bash
shellcheck tailscale-bulk-deploy.sh tests/*.bash tests/*.bats tests/stubs/host/* tests/stubs/guest/*
bats tests
```

The suite points the script at its temp dir with `TS_BULK_LOG` (log file path), `TS_BULK_LXC_CONF_DIR` (container config directory), `TS_BULK_TUN_DEV` (host TUN device to check), and `TS_BULK_TUN_MODULES_CONF` (where to persist the tun module), and skips the root check with `TS_BULK_TEST_ONLY_SKIP_ROOT_CHECK=1`. These exist for the tests; leave them unset on a real node, where the defaults (`/root/tailscale-bulk-<timestamp>.log`, `/etc/pve/lxc`, `/dev/net/tun`, `/etc/modules-load.d/tun.conf`, root required) apply.

Related: [tailscale-mullvad-bulk-deploy](https://github.com/thelorax1775/tailscale-mullvad-bulk-deploy) reuses this script's Proxmox scan/enroll pattern and additionally deploys a Mullvad exit-node kill-switch on each guest. Use this repo when you only want guests joined to the tailnet.

---

## License

Licensed under the [Apache License 2.0](LICENSE).
