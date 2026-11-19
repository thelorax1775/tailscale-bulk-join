#!/usr/bin/env bats
# Unit tests for single functions of tailscale-bulk-deploy.sh.

load test_helper

setup() {
    setup_fake_node
}

# --- is_authkey_error -------------------------------------------------------

@test "is_authkey_error: an invalid key is an auth-key error" {
    run_fn is_authkey_error "backend error: invalid key: API key kFAKEFAKE11CNTRL not valid"
    assert_status 0
}

@test "is_authkey_error: an expired key is an auth-key error" {
    run_fn is_authkey_error "the auth key has expired"
    assert_status 0
    run_fn is_authkey_error "expired key, generate a new one"
    assert_status 0
}

@test "is_authkey_error: a used single-use key and refused tags are auth-key errors" {
    run_fn is_authkey_error "key has already been used"
    assert_status 0
    run_fn is_authkey_error "requested tags [tag:prox] are invalid or not permitted"
    assert_status 0
}

@test "is_authkey_error: matching ignores case" {
    run_fn is_authkey_error "Backend Error: INVALID KEY"
    assert_status 0
}

@test "is_authkey_error: tailscaled startup and network failures are not auth-key errors" {
    local msg
    for msg in \
        "failed to connect to local tailscaled; it doesn't appear to be running (sudo systemctl start tailscaled ?)" \
        "dial unix /var/run/tailscale/tailscaled.sock: connect: no such file or directory" \
        "context deadline exceeded" \
        "" ; do
        run_fn is_authkey_error "$msg"
        [[ "$status" -ne 0 ]] || _fail "should not be treated as an auth-key error: '$msg'"
    done
}

# --- enable_tun_lxc ---------------------------------------------------------

@test "enable_tun_lxc: adds the two TUN lines once and reports a change" {
    add_lxc 101 web
    run_fn enable_tun_lxc 101
    assert_status 0
    assert_output_has "[*] Enabling /dev/net/tun for CT 101"
    [[ "$(grep -cFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)")" -eq 1 ]]
    [[ "$(grep -cFx -- "$TUN_MOUNT_LINE" "$(lxc_conf 101)")" -eq 1 ]]
    # The original config is still there, in front of the new lines.
    [[ "$(head -n 1 "$(lxc_conf 101)")" == "arch: amd64" ]]
}

@test "enable_tun_lxc: a second call changes nothing and reports no change" {
    add_lxc 101 web
    run_fn enable_tun_lxc 101
    assert_status 0
    cp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/after-first"

    run_fn enable_tun_lxc 101
    assert_status 1
    [[ -z "$output" ]] || _fail "second call should print nothing"
    cmp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/after-first"
    [[ "$(grep -cFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)")" -eq 1 ]]
    [[ "$(grep -cFx -- "$TUN_MOUNT_LINE" "$(lxc_conf 101)")" -eq 1 ]]
}

@test "enable_tun_lxc: warns for an unprivileged container, not for a privileged one" {
    add_lxc 101 priv
    add_lxc 102 unpriv
    lxc_unprivileged 102

    run_fn enable_tun_lxc 101
    refute_output_has "UNPRIVILEGED"

    run_fn enable_tun_lxc 102
    assert_status 0
    assert_output_has "[!] CT 102 is UNPRIVILEGED"
    grep -qFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 102)"
}

# --- inc --------------------------------------------------------------------

@test "inc: counts up from zero without tripping set -e" {
    # shellcheck disable=SC2016  # expanded by the child shell, not here
    FAKE_PVESH_EMPTY=1 run bash -c 'source "$1" >/dev/null 2>&1; n=0; inc n; inc n; echo "n=$n"' _ "$SCRIPT"
    assert_status 0
    assert_output_has "n=2"
}
