#!/usr/bin/env bats
# End-to-end runs of the script against a fake node: which guests are
# skipped, joined, retried or failed, and what the final summary says.

load test_helper

setup() {
    setup_fake_node
}

# --- skips ------------------------------------------------------------------

@test "guests that are not running are skipped and never touched" {
    add_lxc 101 stopped-ct stopped
    add_vm 201 stopped-vm stopped
    run_script
    assert_status 0
    assert_output_has "[SKIP] CT 101 (stopped-ct) not running"
    assert_output_has "[SKIP] VM 201 (stopped-vm) not running"
    assert_summary 0 2 0
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "stopped guests must not be touched"
    refute_lxc_tun 101
}

@test "guests already in the tailnet are skipped: no install, no join, no reboot, no config edit" {
    add_lxc 101 joined-ct
    guest_joined 101
    add_vm 201 joined-vm
    guest_joined 201
    run_script
    assert_status 0
    assert_output_has "LXC 101 | joined-ct"
    assert_output_has "VM 201 | joined-vm"
    [[ "$(grep -cF "[SKIP] Tailscale already active in tailnet" <<<"$output")" -eq 2 ]]
    assert_summary 0 2 0
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "joined guests must not be touched"
    refute_lxc_tun 101
}

@test "a VM whose guest agent does not respond is skipped" {
    add_vm 201 no-agent
    vm_agent_down 201
    run_script
    assert_status 0
    assert_output_has "[SKIP] QEMU guest agent not responding."
    assert_summary 0 1 0
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "the VM must not be touched"
}

# --- successful joins -------------------------------------------------------

@test "a fresh LXC gets TUN, a restart, an install and joins as ct-<id>" {
    add_lxc 101 web
    run_script
    assert_status 0
    assert_output_has "[*] Enabling /dev/net/tun for CT 101"
    assert_output_has "[*] Restarting CT 101 for TUN changes"
    assert_output_has "[*] Joining tailnet (fresh enroll) as 'ct-101'"
    assert_output_has "[+] Joined tailnet"
    assert_summary 1 0 0
    grep -qFx -- "$TUN_ALLOW_LINE" "$(lxc_conf 101)"
    grep -qFx -- "$TUN_MOUNT_LINE" "$(lxc_conf 101)"
    assert_calls 1 "pct reboot 101"
    assert_calls 1 "guest 101: sh ran tailscale installer"
    assert_calls 1 "guest 101: tailscale up --reset --authkey $FAKE_KEY --hostname ct-101"
    assert_calls 1 "guest 101: systemctl enable --now tailscaled"
}

@test "a fresh VM gets an install and joins as vm-<id> without a reboot" {
    add_vm 201 db
    run_script
    assert_status 0
    assert_output_has "[*] Joining tailnet (fresh enroll) as 'vm-201'"
    assert_output_has "[+] Joined tailnet"
    assert_summary 1 0 0
    assert_calls 1 "guest 201: sh ran tailscale installer"
    assert_calls 1 "guest 201: tailscale up --reset --authkey $FAKE_KEY --hostname vm-201"
    assert_calls 0 "qm reboot"
}

@test "an LXC with a Proxmox devN passthrough line gets no TUN edit and no reboot, and still joins" {
    add_lxc 101 web
    printf 'dev0: /dev/net/tun\n' >> "$(lxc_conf 101)"
    local conf_before
    conf_before=$(cat "$(lxc_conf 101)")
    run_script
    assert_status 0
    refute_output_has "Enabling /dev/net/tun"
    assert_summary 1 0 0
    assert_calls 0 "pct reboot"
    refute_lxc_tun 101
    cmp "$(lxc_conf 101)" <(cat <<<"$conf_before")
    assert_calls 1 "guest 101: tailscale up"
}

@test "a second run over the same node joins nothing and skips everything" {
    add_lxc 101 web
    add_vm 201 db
    run_script
    assert_summary 2 0 0
    cp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/conf-after-first"
    : > "$FAKE_ROOT/calls.log"

    run_script
    assert_status 0
    assert_summary 0 2 0
    [[ ! -s "$FAKE_ROOT/calls.log" ]] || _fail "second run must not touch any guest"
    cmp "$(lxc_conf 101)" "$BATS_TEST_TMPDIR/conf-after-first"
}

@test "TS_HOSTNAME_PREFIX, TS_LOGIN_SERVER and TS_EXTRA_ARGS reach tailscale up" {
    add_lxc 101 web
    lxc_has_tun 101
    add_vm 201 db
    export TS_HOSTNAME_PREFIX="lab-"
    export TS_LOGIN_SERVER="https://headscale.invalid"
    export TS_EXTRA_ARGS="--ssh --accept-routes"
    run_script
    assert_status 0
    assert_summary 2 0 0
    assert_calls 1 "guest 101: tailscale up --reset --authkey $FAKE_KEY --hostname lab-101 --login-server=https://headscale.invalid --ssh --accept-routes"
    assert_calls 1 "guest 201: tailscale up --reset --authkey $FAKE_KEY --hostname lab-201 --login-server=https://headscale.invalid --ssh --accept-routes"
}

# --- counters and summary ---------------------------------------------------

@test "the summary counts joined, skipped and failed guests across LXCs and VMs" {
    add_lxc 101 fresh-ct                 # joins                -> Success
    add_lxc 102 stopped-ct stopped       # not running          -> Skipped
    add_lxc 103 joined-ct                # already in tailnet   -> Skipped
    guest_joined 103
    add_lxc 104 no-pkg-ct running none   # no package manager   -> Failed
    add_vm 201 fresh-vm                  # joins                -> Success
    add_vm 202 no-agent-vm               # agent down           -> Skipped
    vm_agent_down 202
    add_vm 203 broken-vm                 # installer fails      -> Failed
    guest_flag 203 install_fails
    run_script
    assert_status 0
    assert_summary 2 3 2
    assert_output_has " DONE"
    assert_output_has "Log     : $TS_BULK_LOG"
    refute_output_has "rejected your auth key"
    # The same summary is in the log file.
    grep -qF "Success : 2" "$TS_BULK_LOG"
    grep -qF "Skipped : 3" "$TS_BULK_LOG"
    grep -qF "Failed  : 2" "$TS_BULK_LOG"
}

# --- reboot and retry once --------------------------------------------------

@test "LXC: a failed join that is not a key error reboots once and retries" {
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "failed to connect to local tailscaled; it doesn't appear to be running" ok
    run_script
    assert_status 0
    assert_output_has "[X] Tailnet join failed"
    assert_output_has "    fake tailscaled journal for guest 101"
    assert_output_has "[*] Join failed — rebooting CT 101 and retrying once"
    assert_output_has "[+] Joined tailnet after reboot"
    refute_output_has "rejected the auth key"
    assert_summary 1 0 0
    assert_calls 1 "pct reboot 101"
    assert_calls 2 "guest 101: tailscale up"
}

@test "VM: a failed join that is not a key error reboots once and retries" {
    add_vm 201 db
    guest_has_tailscale 201
    guest_up_plan 201 "failed to connect to local tailscaled; it doesn't appear to be running" ok
    run_script
    assert_status 0
    assert_output_has "[X] Tailnet join failed"
    assert_output_has "[*] Join failed — rebooting VM 201 and retrying once"
    assert_output_has "[+] Joined tailnet after reboot"
    refute_output_has "rejected the auth key"
    assert_summary 1 0 0
    assert_calls 1 "qm reboot 201"
    assert_calls 2 "guest 201: tailscale up"
}

@test "a join that still fails after the reboot is counted as failed, with no second reboot" {
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "tailscaled not running" "tailscaled not running" ok
    add_vm 201 db
    guest_has_tailscale 201
    guest_up_plan 201 "tailscaled not running" "tailscaled not running" ok
    run_script
    assert_status 0
    [[ "$(grep -cF "[X] Still failed after reboot — needs manual investigation" <<<"$output")" -eq 2 ]]
    assert_summary 0 0 2
    assert_calls 1 "pct reboot 101"
    assert_calls 1 "qm reboot 201"
    assert_calls 2 "guest 101: tailscale up"
    assert_calls 2 "guest 201: tailscale up"
}

@test "a reboot that fails ends the guest as failed and the scan carries on" {
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "tailscaled not running"
    guest_flag 101 reboot_fails
    add_lxc 102 next
    lxc_has_tun 102
    run_script
    assert_status 0
    assert_output_has "[X] Reboot failed for CT 101"
    assert_output_has "LXC 102 | next"
    assert_summary 1 0 1
    assert_calls 1 "guest 101: tailscale up"
}

# --- fail fast on a rejected key --------------------------------------------

@test "LXC: an invalid key stops the run early: no reboot, later guests are not enrolled" {
    add_lxc 101 first
    lxc_has_tun 101
    guest_up_plan 101 "backend error: invalid key: API key kFAKEFAKE11CNTRL not valid"
    add_lxc 102 second
    add_lxc 103 already-in
    guest_joined 103
    add_vm 201 third
    run_script
    assert_status 0
    assert_output_has "[X] Tailnet join failed — control server rejected the auth key"
    assert_output_has "and already consumed by an earlier guest. Not rebooting CT 101."
    [[ "$(grep -cF "[X] Skipping enroll — auth key was already rejected earlier this run." <<<"$output")" -eq 2 ]]
    assert_output_has "[!] The control server rejected your auth key partway through this run."
    refute_output_has "retrying once"
    # 101, 102 and 201 failed; 103 was already joined and is still a skip.
    assert_summary 0 1 3
    assert_calls 0 "reboot"
    assert_calls 1 "tailscale up"
    # The later guests were left alone: no install, no join, no TUN edit.
    assert_calls 0 "guest 102:"
    assert_calls 0 "guest 201:"
    refute_lxc_tun 102
}

@test "VM: an expired key stops the run early: no reboot, later VMs are not enrolled" {
    add_vm 201 first
    guest_up_plan 201 "the auth key has expired"
    add_vm 202 second
    run_script
    assert_status 0
    assert_output_has "the auth key has expired"
    assert_output_has "[X] Tailnet join failed — control server rejected the auth key"
    assert_output_has "and already consumed by an earlier guest. Not rebooting VM 201."
    assert_output_has "[X] Skipping enroll — auth key was already rejected earlier this run."
    assert_output_has "[!] The control server rejected your auth key partway through this run."
    refute_output_has "retrying once"
    assert_summary 0 0 2
    assert_calls 0 "reboot"
    assert_calls 1 "tailscale up"
    assert_calls 0 "guest 202:"
}

@test "a single-use key: the first guest joins, the rest fail fast without reboots" {
    add_lxc 101 first
    lxc_has_tun 101
    add_lxc 102 second
    lxc_has_tun 102
    guest_up_plan 102 "backend error: invalid key: key has already been used"
    add_lxc 103 third
    lxc_has_tun 103
    run_script
    assert_status 0
    assert_summary 1 0 2
    assert_calls 0 "reboot"
    assert_calls 2 "tailscale up"
    assert_calls 0 "guest 103:"
}

# --- the auth key never leaks -----------------------------------------------

@test "LXC: a tailscale error that echoes the key does not put it in the output or the log" {
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "Error: changing settings via 'tailscale up' requires mentioning all non-default flags. Command: @ECHO@" ok
    run_script
    assert_status 0
    assert_output_has "[redacted-key]"
    assert_output_has "[+] Joined tailnet after reboot"
    refute_output_has "tskey-"
    if grep -q "tskey-" "$TS_BULK_LOG"; then _fail "secret found in $TS_BULK_LOG"; fi
}

@test "VM: a tailscale error that echoes the key does not put it in the output or the log" {
    add_vm 201 db
    guest_has_tailscale 201
    guest_up_plan 201 "Error: requires mentioning all non-default flags. Command: @ECHO@" ok
    run_script
    assert_status 0
    assert_output_has "[redacted-key]"
    refute_output_has "tskey-"
    if grep -q "tskey-" "$TS_BULK_LOG"; then _fail "secret found in $TS_BULK_LOG"; fi
}

@test "LXC: a key in the tailscaled journal after a failed join is redacted" {
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "some failure" "some failure"
    printf 'tailscaled: auth %s\n' "$FAKE_KEY" > "$FAKE_ROOT/guests/101/journal_extra"
    run_script
    assert_output_has "fake tailscaled journal for guest 101"
    assert_output_has "[redacted-key]"
    refute_output_has "tskey-"
    if grep -q "tskey-" "$TS_BULK_LOG"; then _fail "secret found in $TS_BULK_LOG"; fi
}

@test "VM: a key in the tailscaled journal after a failed join is redacted" {
    add_vm 201 db
    guest_has_tailscale 201
    guest_up_plan 201 "some failure" "some failure"
    printf 'tailscaled: auth %s\n' "$FAKE_KEY" > "$FAKE_ROOT/guests/201/journal_extra"
    run_script
    assert_output_has "fake tailscaled journal for guest 201"
    assert_output_has "[redacted-key]"
    refute_output_has "tskey-"
    if grep -q "tskey-" "$TS_BULK_LOG"; then _fail "secret found in $TS_BULK_LOG"; fi
}

@test "a key that does not look like tskey-... is redacted too" {
    export TS_AUTHKEY="plainsecret123"
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "bad things: @ECHO@" ok
    run_script
    refute_output_has "plainsecret123"
    if grep -q "plainsecret123" "$TS_BULK_LOG"; then _fail "secret found in $TS_BULK_LOG"; fi
}

@test "the key is not in any pct or qm command line, only the guest's own tailscale call" {
    add_lxc 101 web
    lxc_has_tun 101
    add_vm 201 db
    run_script
    assert_status 0
    assert_summary 2 0 0
    [[ -s "$FAKE_ROOT/argv.log" ]]
    if grep -qF -- "$FAKE_KEY" "$FAKE_ROOT/argv.log"; then _fail "secret found in $FAKE_ROOT/argv.log"; fi
    # ...and it still reached tailscale inside both guests.
    assert_calls 1 "guest 101: tailscale up --reset --authkey $FAKE_KEY"
    assert_calls 1 "guest 201: tailscale up --reset --authkey $FAKE_KEY"
}

# --- network errors that mention the key are not key rejections -------------

@test "a network error mentioning authkey does not stop the run: later guests are tried and the retry happens" {
    add_lxc 101 first
    lxc_has_tun 101
    guest_has_tailscale 101
    guest_up_plan 101 "dial tcp: i/o timeout while validating authkey" ok
    add_lxc 102 second
    lxc_has_tun 102
    run_script
    assert_status 0
    refute_output_has "rejected the auth key"
    refute_output_has "Skipping enroll"
    assert_output_has "[*] Join failed — rebooting CT 101 and retrying once"
    assert_calls 1 "pct reboot 101"
    assert_calls 1 "guest 102: tailscale up"
    assert_summary 2 0 0
}

# --- one guest must not end the scan ------------------------------------------

@test "a pct that reads stdin does not stop the scan: all 3 containers are processed" {
    for id in 101 102 103; do
        add_lxc "$id" "ct$id"
        lxc_has_tun "$id"
    done
    pct_reads_stdin
    run_script
    assert_status 0
    assert_summary 3 0 0
    for id in 101 102 103; do
        assert_calls 1 "guest $id: tailscale up"
    done
}

# --- TUN config write failure ------------------------------------------------

@test "LXC: config write failure (chmod 444) is reported as failed, no install, no join, no reboot" {
    [[ $EUID -ne 0 ]] || skip "root ignores file permissions"
    add_lxc 101 web
    chmod 444 "$(lxc_conf 101)"
    run_script
    assert_status 0
    assert_output_has "[X] Could not edit"
    assert_output_has "[X] TUN setup failed for CT 101"
    assert_summary 0 0 1
    assert_calls 0 "tailscale up"
    assert_calls 0 "pct reboot"
    # no guest 101: apt call
    if grep -qF "guest 101: apt" "$FAKE_ROOT/calls.log"; then
        _fail "guest 101: apt should not be called"
    fi
}

@test "LXC: config write failure on CT 101 does not stop CT 102 from joining" {
    [[ $EUID -ne 0 ]] || skip "root ignores file permissions"
    add_lxc 101 web
    chmod 444 "$(lxc_conf 101)"
    add_lxc 102 web2
    run_script
    assert_status 0
    assert_output_has "[X] Could not edit"
    assert_output_has "[X] TUN setup failed for CT 101"
    assert_output_has "[+] Joined tailnet"
    assert_summary 1 0 1
    assert_calls 1 "guest 102: tailscale up"
    assert_calls 1 "pct reboot 102"
}
