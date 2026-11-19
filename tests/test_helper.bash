#!/usr/bin/env bash
# Shared setup and helpers for the bats suite.
#
# Nothing here talks to a real Proxmox node. Every test gets a fake node
# under $BATS_TEST_TMPDIR:
#   fake/lxc.json, fake/qemu.json   what the fake pvesh returns
#   fake/lxc-conf/<vmid>.conf       container configs (TS_BULK_LXC_CONF_DIR)
#   fake/guests/<vmid>/             one dir per guest; bin/ is its whole PATH
#   fake/calls.log                  every state-changing call the stubs saw
#   fake/run.log                    the script's own log (TS_BULK_LOG)
# The host commands (pct, qm, pvesh, lsmod, modprobe, sleep, apt) come from
# tests/stubs/host, put first on PATH.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/tailscale-bulk-deploy.sh"
STUB_HOST_DIR="$REPO_ROOT/tests/stubs/host"
export STUB_GUEST_DIR="$REPO_ROOT/tests/stubs/guest"

# The only key the suite ever uses. It is not a real key.
FAKE_KEY="tskey-auth-FAKE"

TUN_ALLOW_LINE='lxc.cgroup2.devices.allow: c 10:200 rwm'
TUN_MOUNT_LINE='lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file'

setup_fake_node() {
    export FAKE_ROOT="$BATS_TEST_TMPDIR/fake"
    export FAKE_NODE="testnode"
    mkdir -p "$FAKE_ROOT/guests" "$FAKE_ROOT/lxc-conf" "$BATS_TEST_TMPDIR/home"
    echo '[]' > "$FAKE_ROOT/lxc.json"
    echo '[]' > "$FAKE_ROOT/qemu.json"
    : > "$FAKE_ROOT/calls.log"

    # Real tools the fake guests are allowed to use, resolved before PATH
    # is narrowed inside a guest.
    REAL_BASH="$(type -P bash)"
    REAL_GREP="$(type -P grep)"
    REAL_TRUE="$(type -P true)"
    STUB_LN="$(type -P ln)"
    export STUB_LN

    # shellcheck disable=SC2034  # used by tests that rebuild PATH
    ORIG_PATH="$PATH"
    export PATH="$STUB_HOST_DIR:$PATH"
    export HOME="$BATS_TEST_TMPDIR/home"

    export TS_BULK_LOG="$FAKE_ROOT/run.log"
    export TS_BULK_LXC_CONF_DIR="$FAKE_ROOT/lxc-conf"
    export TS_BULK_TEST_ONLY_SKIP_ROOT_CHECK=1
    export PVE_NODE="$FAKE_NODE"
    export TS_AUTHKEY="$FAKE_KEY"
    unset TS_EXTRA_ARGS TS_HOSTNAME_PREFIX TS_LOGIN_SERVER
}

# _add_guest <lxc|qemu> <vmid> <name> <status> <pkg>
# pkg is the guest's package manager: apt, apk, dnf, yum or none.
_add_guest() {
    local kind="$1" id="$2" name="$3" status="$4" pkg="$5"
    local list="$FAKE_ROOT/$kind.json" bin="$FAKE_ROOT/guests/$id/bin" tool

    jq --argjson id "$id" --arg name "$name" --arg status "$status" \
        '. + [{vmid: $id, name: $name, status: $status}]' "$list" > "$list.new"
    mv "$list.new" "$list"

    mkdir -p "$bin"
    ln -s "$REAL_BASH" "$bin/bash"
    ln -s "$REAL_GREP" "$bin/grep"
    ln -s "$REAL_TRUE" "$bin/true"
    for tool in curl sh systemctl journalctl; do
        ln -s "$STUB_GUEST_DIR/$tool" "$bin/$tool"
    done
    if [[ "$pkg" != "none" ]]; then
        ln -s "$STUB_GUEST_DIR/pkgmgr" "$bin/$pkg"
    fi
}

# add_lxc <vmid> <name> [status=running] [pkg=apt]
# Creates a privileged container (no "unprivileged: 1" line) with no TUN lines.
add_lxc() {
    local id="$1" name="$2" status="${3:-running}" pkg="${4:-apt}"
    _add_guest lxc "$id" "$name" "$status" "$pkg"
    printf 'arch: amd64\nhostname: %s\nmemory: 512\n' "$name" > "$(lxc_conf "$id")"
}

# add_vm <vmid> <name> [status=running] [pkg=apt]
# The guest agent responds unless the test calls vm_agent_down.
add_vm() {
    local id="$1" name="$2" status="${3:-running}" pkg="${4:-apt}"
    _add_guest qemu "$id" "$name" "$status" "$pkg"
    : > "$FAKE_ROOT/guests/$id/agent"
}

lxc_conf() { echo "$FAKE_ROOT/lxc-conf/$1.conf"; }

# The container already has the TUN lines, so no restart is needed for them.
lxc_has_tun() {
    printf '\n# Tailscale requirement\n%s\n%s\n' "$TUN_ALLOW_LINE" "$TUN_MOUNT_LINE" >> "$(lxc_conf "$1")"
}

lxc_unprivileged() { echo 'unprivileged: 1' >> "$(lxc_conf "$1")"; }

vm_agent_down() { rm -f "$FAKE_ROOT/guests/$1/agent"; }

# Tailscale is installed in the guest but it has not joined.
guest_has_tailscale() {
    ln -sf "$STUB_GUEST_DIR/tailscale" "$FAKE_ROOT/guests/$1/bin/tailscale"
}

# The guest is already in the tailnet.
guest_joined() {
    guest_has_tailscale "$1"
    : > "$FAKE_ROOT/guests/$1/joined"
}

# guest_up_plan <vmid> <outcome>...
# One outcome per future `tailscale up`: "ok", or the error text to fail with.
guest_up_plan() {
    local id="$1"
    shift
    printf '%s\n' "$@" > "$FAKE_ROOT/guests/$id/up_plan"
}

# guest_flag <vmid> <flag>: pkg_fails, curl_fails, install_fails, reboot_fails, down
guest_flag() { : > "$FAKE_ROOT/guests/$1/$2"; }

run_script() {
    run bash "$SCRIPT" "$@"
}

# run_fn <function> [args...]
# Calls one function of the script. The script has no "library mode", so it
# is sourced in a child shell with the fake pvesh reporting an empty node
# (the scan finds no guests) and the function is called afterwards.
run_fn() {
    local FAKE_PVESH_EMPTY=1
    export FAKE_PVESH_EMPTY
    # shellcheck disable=SC2016  # expanded by the child shell, not here
    run bash -c 'source "$1" >/dev/null 2>&1; trap - ERR; set +e; shift; "$@"' _ "$SCRIPT" "$@"
}

calls() { cat "$FAKE_ROOT/calls.log"; }

# count_calls <fixed string>: how many logged calls contain the string.
count_calls() { grep -cF -- "$1" "$FAKE_ROOT/calls.log" || true; }

_fail() {
    {
        echo "FAILED: $1"
        echo "--- exit status: ${status:-?}"
        echo "--- output:"
        echo "${output:-}"
        echo "--- stub calls:"
        cat "$FAKE_ROOT/calls.log" 2>/dev/null
    } >&2
    return 1
}

assert_status() {
    [[ "$status" -eq "$1" ]] || _fail "expected exit status $1"
}

assert_output_has() {
    [[ "$output" == *"$1"* ]] || _fail "output should contain: $1"
}

refute_output_has() {
    [[ "$output" != *"$1"* ]] || _fail "output should NOT contain: $1"
}

# assert_calls <count> <fixed string>
assert_calls() {
    local n
    n="$(count_calls "$2")"
    [[ "$n" -eq "$1" ]] || _fail "expected $1 call(s) containing '$2', saw $n"
}

# The container config has not been given the TUN lines.
refute_lxc_tun() {
    if grep -qF -- "$TUN_ALLOW_LINE" "$(lxc_conf "$1")"; then
        _fail "CT $1 config should not have the TUN lines"
    fi
}

# assert_summary <success> <skipped> <failed>
assert_summary() {
    assert_output_has "Success : $1"
    assert_output_has "Skipped : $2"
    assert_output_has "Failed  : $3"
}
