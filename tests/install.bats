#!/usr/bin/env bats
# The install step inside a guest, for every package manager the script
# knows. These run against fake guests only: a fake guest is a directory
# whose bin/ holds exactly one package manager stub, so the script's own
# `command -v apt / apk / dnf / yum` chain picks the branch.
# No real Alpine, Fedora or CentOS guest is involved.

load test_helper

setup() {
    setup_fake_node
}

# check_install <guest id> <expected package manager call>
# The guest must have used that package manager, no other, then the installer.
check_install() {
    local id="$1" expected="$2" other
    assert_calls 1 "guest $id: $expected"
    for other in apt apk dnf yum; do
        [[ "$expected" == "$other "* ]] || assert_calls 0 "guest $id: $other "
    done
    assert_calls 1 "guest $id: curl -fsSL https://tailscale.com/install.sh"
    assert_calls 1 "guest $id: sh ran tailscale installer"
    assert_calls 1 "guest $id: tailscale up"
}

@test "LXC install: apt guest uses apt update and apt install" {
    add_lxc 101 debian running apt
    run_script
    assert_status 0
    assert_summary 1 0 0
    assert_calls 1 "guest 101: apt update -y"
    check_install 101 "apt install -y curl ca-certificates"
}

@test "LXC install: apk guest uses apk add" {
    add_lxc 101 alpine running apk
    run_script
    assert_status 0
    assert_output_has "[*] Installing dependencies..."
    assert_output_has "[*] Installing Tailscale..."
    assert_summary 1 0 0
    check_install 101 "apk add --no-cache curl ca-certificates"
}

@test "LXC install: dnf guest uses dnf install" {
    add_lxc 101 fedora running dnf
    run_script
    assert_status 0
    assert_summary 1 0 0
    check_install 101 "dnf install -y curl ca-certificates"
}

@test "LXC install: yum guest uses yum install" {
    add_lxc 101 centos running yum
    run_script
    assert_status 0
    assert_summary 1 0 0
    check_install 101 "yum install -y curl ca-certificates"
}

@test "VM install: apt guest uses apt update and apt install" {
    add_vm 201 debian running apt
    run_script
    assert_status 0
    assert_summary 1 0 0
    assert_calls 1 "guest 201: apt update -y"
    check_install 201 "apt install -y curl ca-certificates"
}

@test "VM install: apk guest uses apk add" {
    add_vm 201 alpine running apk
    run_script
    assert_status 0
    assert_summary 1 0 0
    check_install 201 "apk add --no-cache curl ca-certificates"
}

@test "VM install: dnf guest uses dnf install" {
    add_vm 201 fedora running dnf
    run_script
    assert_status 0
    assert_summary 1 0 0
    check_install 201 "dnf install -y curl ca-certificates"
}

@test "VM install: yum guest uses yum install" {
    add_vm 201 centos running yum
    run_script
    assert_status 0
    assert_summary 1 0 0
    check_install 201 "yum install -y curl ca-certificates"
}

@test "LXC install: a guest with no known package manager fails and is not joined" {
    add_lxc 101 mystery running none
    run_script
    assert_status 0
    assert_output_has "[X] No supported package manager found"
    assert_output_has "[X] Install failed"
    assert_summary 0 0 1
    assert_calls 0 "curl -fsSL"
    assert_calls 0 "tailscale up"
}

@test "install: a failing package manager fails the guest before the installer runs" {
    add_lxc 101 alpine running apk
    guest_flag 101 pkg_fails
    add_vm 201 fedora running dnf
    guest_flag 201 pkg_fails
    run_script
    assert_status 0
    [[ "$(grep -cF "[X] Install failed" <<<"$output")" -eq 2 ]]
    assert_summary 0 0 2
    assert_calls 1 "guest 101: apk add"
    assert_calls 1 "guest 201: dnf install"
    assert_calls 0 "curl -fsSL"
    assert_calls 0 "tailscale up"
}

@test "install: a guest that already has tailscale is not reinstalled" {
    add_lxc 101 web
    lxc_has_tun 101
    guest_has_tailscale 101
    add_vm 201 db
    guest_has_tailscale 201
    run_script
    assert_status 0
    assert_output_has "[+] Tailscale already installed"
    assert_summary 2 0 0
    assert_calls 0 "apt"
    assert_calls 0 "curl -fsSL"
    assert_calls 0 "installer"
    assert_calls 2 "tailscale up"
}
