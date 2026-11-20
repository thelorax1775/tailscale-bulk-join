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
        "dial tcp: i/o timeout while validating authkey" \
        "authkey flag provided but the value is not valid yet, retrying" \
        "requested tags are being applied" \
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

# --- enable_tun_lxc and snapshot sections ------------------------------------

snap_conf() {
    printf 'arch: amd64\nhostname: web\nmemory: 512\n\n[snap]\narch: amd64\nmemory: 256\nsnaptime: 1700000000\n' > "$(lxc_conf "$1")"
}

@test "enable_tun_lxc: with a snapshot, the lines go before the first header and the snapshot is untouched" {
    add_lxc 101 web
    snap_conf 101
    sed -n '/^\[snap\]/,$p' "$(lxc_conf 101)" > "$BATS_TEST_TMPDIR/snap-before"

    run_fn enable_tun_lxc 101
    assert_status 0
    sed -n '/^\[snap\]/,$p' "$(lxc_conf 101)" > "$BATS_TEST_TMPDIR/snap-after"
    cmp "$BATS_TEST_TMPDIR/snap-before" "$BATS_TEST_TMPDIR/snap-after"

    hdr="$(grep -n '^\[snap\]' "$(lxc_conf 101)" | cut -d: -f1)"
    allow="$(grep -nFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)" | cut -d: -f1)"
    mount="$(grep -nFx -- "$TUN_MOUNT_LINE" "$(lxc_conf 101)" | cut -d: -f1)"
    [[ -n "$allow" && -n "$mount" && "$allow" -lt "$hdr" && "$mount" -lt "$hdr" ]]
    [[ "$(grep -cFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)")" -eq 1 ]]
    [[ "$(grep -cFx -- "$TUN_MOUNT_LINE" "$(lxc_conf 101)")" -eq 1 ]]

    cp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/after-first"
    run_fn enable_tun_lxc 101
    assert_status 1
    [[ -z "$output" ]]
    cmp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/after-first"
}

@test "enable_tun_lxc: TUN lines that exist only inside a snapshot do not count" {
    add_lxc 101 web
    lxc_snapshot_with_tun 101
    run_fn enable_tun_lxc 101
    assert_status 0
    assert_output_has "[*] Enabling /dev/net/tun for CT 101"
    hdr="$(grep -n '^\[snap\]' "$(lxc_conf 101)" | cut -d: -f1)"
    allow="$(grep -nFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)" | head -n 1 | cut -d: -f1)"
    [[ "$allow" -lt "$hdr" ]]
    [[ "$(grep -cFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)")" -eq 2 ]]
}

@test "enable_tun_lxc: an unprivileged flag inside a snapshot does not make the live config unprivileged" {
    add_lxc 101 web
    printf '\n[snap]\nunprivileged: 1\n' >> "$(lxc_conf 101)"
    run_fn enable_tun_lxc 101
    assert_status 0
    refute_output_has "UNPRIVILEGED"
}

@test "enable_tun_lxc: writes <conf>.bak-tailscale-bulk once and never overwrites it" {
    add_lxc 101 web
    cp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/original"
    bak="$(lxc_conf 101).bak-tailscale-bulk"
    [[ ! -e "$bak" ]]

    run_fn enable_tun_lxc 101
    assert_status 0
    cmp "$bak" "$BATS_TEST_TMPDIR/original"

    # A later edit (the TUN lines removed again by hand) must keep the first backup.
    cp "$BATS_TEST_TMPDIR/original" "$(lxc_conf 101)"
    echo 'memory: 1024' >> "$(lxc_conf 101)"
    run_fn enable_tun_lxc 101
    assert_status 0
    cmp "$bak" "$BATS_TEST_TMPDIR/original"
}

@test "enable_tun_lxc: no backup is made when nothing needs changing" {
    add_lxc 101 web
    lxc_has_tun 101
    run_fn enable_tun_lxc 101
    assert_status 1
    [[ ! -e "$(lxc_conf 101).bak-tailscale-bulk" ]]
}

# --- the "already joined" check ----------------------------------------------

@test "is_lxc_tailscale_active: 192.100.5.5 is not a tailnet address, 100.64.0.7 is" {
    add_lxc 101 web
    guest_status_out 101 "192.100.5.5  host  user@  linux  -"
    run_fn is_lxc_tailscale_active 101
    [[ "$status" -ne 0 ]] || _fail "192.100.x.x must not count as joined"
    guest_status_out 101 "100.64.0.7  host  user@  linux  -"
    run_fn is_lxc_tailscale_active 101
    assert_status 0
}

@test "is_vm_tailscale_active: 192.100.5.5 is not a tailnet address, 100.64.0.7 is" {
    add_vm 201 db
    guest_status_out 201 "192.100.5.5  host  user@  linux  -"
    run_fn is_vm_tailscale_active 201
    [[ "$status" -ne 0 ]] || _fail "192.100.x.x must not count as joined"
    guest_status_out 201 "100.64.0.7  host  user@  linux  -"
    run_fn is_vm_tailscale_active 201
    assert_status 0
}
