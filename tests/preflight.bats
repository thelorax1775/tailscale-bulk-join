#!/usr/bin/env bats
# --help and the checks the script makes before it touches any guest.

load test_helper

setup() {
    setup_fake_node
}

@test "--help prints the usage block and does nothing else" {
    run_script --help
    assert_status 0
    assert_output_has "Proxmox Bulk Tailscale Deployment"
    assert_output_has "USAGE:"
    assert_output_has "export TS_AUTHKEY='tskey-auth-xxxxxxxxxxxx'"
    assert_output_has "TS_LOGIN_SERVER"
    refute_output_has "#!/usr/bin/env bash"
    refute_output_has "set -Eeuo pipefail"
    [[ ! -e "$TS_BULK_LOG" ]] || _fail "--help must not create a log file"
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "--help must not call anything"
}

@test "-h is the same as --help" {
    run_script --help
    local long="$output"
    run_script -h
    assert_status 0
    [[ "$output" == "$long" ]]
}

@test "refuses to run without root, and logs to /root by default" {
    [[ "$(id -u)" -ne 0 ]] || skip "needs a non-root user"
    # With the overrides unset the script opens its default log under /root.
    # For a normal user that open is refused, so nothing is written.
    [[ ! -w /root ]] || skip "/root is writable for this user"
    add_lxc 101 web
    unset TS_BULK_TEST_ONLY_SKIP_ROOT_CHECK TS_BULK_LOG TS_BULK_LXC_CONF_DIR
    run_script
    assert_status 1
    assert_output_has "[X] This script must be run as root on a Proxmox VE node."
    assert_output_has "Log:  /root/tailscale-bulk-"
    refute_output_has "Scanning LXC"
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "no guest may be touched"
}

@test "refuses to run where pvesh is missing" {
    # A PATH with every host stub except pvesh.
    PATH="$ORIG_PATH"
    ! command -v pvesh >/dev/null 2>&1 || skip "a real pvesh is on PATH"
    local bin="$BATS_TEST_TMPDIR/no-pvesh" stub
    mkdir -p "$bin"
    for stub in "$STUB_HOST_DIR"/*; do
        [[ "${stub##*/}" == "pvesh" ]] || ln -s "$stub" "$bin/"
    done
    export PATH="$bin:$ORIG_PATH"

    add_lxc 101 web
    run_script
    assert_status 1
    assert_output_has "[X] pvesh not found. This does not look like a Proxmox VE node."
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "no guest may be touched"
}

@test "refuses to run without TS_AUTHKEY" {
    add_lxc 101 web
    unset TS_AUTHKEY
    run_script
    assert_status 1
    assert_output_has "[X] TS_AUTHKEY is not set."
    refute_output_has "Scanning LXC"
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "no guest may be touched"
}

@test "an empty node finishes with all counters at zero and writes the log" {
    run_script
    assert_status 0
    assert_output_has "Node: testnode"
    assert_output_has "[*] Scanning LXC containers on node 'testnode'..."
    assert_output_has "[*] Scanning VMs on node 'testnode'..."
    assert_summary 0 0 0
    assert_output_has "Log     : $TS_BULK_LOG"
    grep -qF "Failed  : 0" "$TS_BULK_LOG"
    assert_calls 0 "modprobe"
    assert_calls 0 "host apt"
}

@test "a host with /dev/net/tun present does not run modprobe or write tun.conf" {
    run_script
    assert_status 0
    assert_calls 0 "modprobe"
    [[ ! -e "$FAKE_ROOT/tun.conf" ]] || _fail "tun.conf should not exist"
    refute_output_has "loading the tun module"
}

@test "a host without /dev/net/tun loads tun and persists it" {
    # shellcheck disable=SC2030,SC2031  # bats runs each test in a subshell; export is intentional
    export TS_BULK_TUN_DEV="$BATS_TEST_TMPDIR/no-tun"
    run_script
    assert_status 0
    assert_calls 1 "modprobe tun"
    assert_output_has "is missing on the host — loading the tun module"
    # tun.conf should exist and contain exactly "tun"
    [[ -f "$FAKE_ROOT/tun.conf" ]] || _fail "tun.conf should exist"
    local content
    content="$(cat "$FAKE_ROOT/tun.conf")"
    [[ "$content" == "tun" ]] || _fail "tun.conf should contain exactly 'tun', got: $content"
}

@test "a failed modprobe stops the run before any guest is touched" {
    add_lxc 101 web
    # shellcheck disable=SC2030,SC2031  # bats runs each test in a subshell; export is intentional
    export TS_BULK_TUN_DEV="$BATS_TEST_TMPDIR/no-tun"
    export FAKE_MODPROBE_FAILS=1
    run_script
    assert_status 1
    assert_output_has "[X] Could not load the tun module"
    refute_output_has "Scanning LXC"
    assert_calls 0 "pct"
}

@test "pvesh fails to list LXC containers: exits 1 with clear error and no tailscale up calls" {
    add_lxc 101 web
    export PVE_NODE=wrongnode
    run_script
    assert_status 1
    assert_output_has "[X] Could not list containers on node 'wrongnode'"
    refute_output_has "DONE"
    assert_calls 0 "tailscale up"
}

@test "pvesh lists LXC but fails to list VMs: exits 1 with clear VM error" {
    add_lxc 101 web
    add_vm 201 vm-web
    export FAKE_PVESH_FAIL_QEMU=1
    run_script
    assert_status 1
    assert_output_has "[X] Could not list VMs on node 'testnode'"
}