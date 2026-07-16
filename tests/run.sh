#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/pd-tests-XXXXXX")
TEST_SCRIPT="$ROOT/install.sh"
# macOS /bin/bash 3.2 不能声明关联数组；测试只触达与注册表无关或已覆写
# 的函数，因此生成一个仅供加载函数定义的兼容副本。生产脚本仍严格要求 Bash 4+。
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    TEST_SCRIPT="$TEST_ROOT/install-bash3-compat.sh"
    sed -e 's/^declare -A PROTO=()/declare -a PROTO=()/' \
        -e 's/^declare -a _PD_TMPFILES=()/declare -a _PD_TMPFILES=("")/' \
        -e 's/^\[ "${BASH_VERSINFO.*$/true # Bash 3 test compatibility/' \
        -e 's/^register_protocols$/: # registry not needed by portable tests/' \
        "$ROOT/install.sh" > "$TEST_SCRIPT"
    chmod +x "$TEST_SCRIPT"
fi
export PD_TEST_MODE=1
export PD_BASE_DIR="$TEST_ROOT/pd"
export PD_STATE_FILE="$PD_BASE_DIR/state"
export PD_SYSTEMD_DIR="$TEST_ROOT/systemd"
export PD_INSTALLED_BIN="$TEST_ROOT/bin/pd"
export PD_LOCK_FILE="$TEST_ROOT/run/lock/pd-proxy.lock"
mkdir -p "$PD_BASE_DIR" "$PD_SYSTEMD_DIR" "$TEST_ROOT/bin"

# shellcheck source=../install.sh
source "$TEST_SCRIPT"
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || _PD_TMPFILES+=("")
test_cleanup() {
    local rc=$?
    cleanup_tmpfiles || true
    rm -rf "$TEST_ROOT" || true
    exit "$rc"
}
trap test_cleanup EXIT

passes=0
failures=0

pass() { echo "ok - $1"; passes=$((passes + 1)); }
fail() { echo "not ok - $1" >&2; failures=$((failures + 1)); }
run_test() {
    local name="$1" fn="$2"
    if ( "$fn" ); then pass "$name"; else fail "$name"; fi
}

test_transaction_control_flow() {
    local marker="$TEST_ROOT/rollback-called"
    transaction_rollback() { printf rollback > "$marker"; _PD_TXN_DIR=""; _PD_TXN_PROTO=""; return 0; }
    transaction_commit() { return 99; }
    fails_with_die() { die "intentional transaction failure"; }
    _PD_TXN_DIR="$TEST_ROOT/fake-txn"
    _PD_TXN_PROTO=anytls
    set +e
    transaction_run fails_with_die >/dev/null 2>&1
    local rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ -f "$marker" ]
}

test_no_err_rollback_trap() {
    [ -z "$(trap -p ERR)" ]
}

test_mktemp_tracking() {
    local before=${#_PD_TMPFILES[@]} temp_file
    mktemp_pd temp_file
    [ -f "$temp_file" ] && [ "${#_PD_TMPFILES[@]}" -eq $((before + 1)) ]
}

test_multiline_port_matching_and_recheck() {
    local mock="$TEST_ROOT/mock-port" counter="$TEST_ROOT/od-counter"
    mkdir -p "$mock"
    cat > "$mock/od" <<'MOCK'
#!/usr/bin/env bash
counter=${PD_TEST_OD_COUNTER:?}
n=0
[ ! -f "$counter" ] || n=$(cat "$counter")
n=$((n + 1)); echo "$n" > "$counter"
if [ "$n" -eq 1 ]; then echo 13456; else echo 13457; fi
MOCK
    chmod +x "$mock/od"
    export PD_TEST_OD_COUNTER="$counter"
    printf 'snell port=12000 status=installed\nhy2 port=23456 status=installed hop=1\n' > "$STATE_FILE"
    port_in_use() { return 1; }
    local picked
    picked=$(PATH="$mock:$PATH" rand_port)
    [ "$picked" = 23457 ] && state_port_range_conflict 23456 23456 ""
}

test_transport_specific_verification() {
    local mock="$TEST_ROOT/mock-transport"
    mkdir -p "$mock"
    cat > "$mock/systemctl" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = is-active ] && exit 0
[ "${1:-}" = show ] && { echo 4242; exit 0; }
exit 1
MOCK
    cat > "$mock/ss" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *-ltnp*) echo 'LISTEN 0 128 0.0.0.0:12345 0.0.0.0:* users:(("demo",pid=4242,fd=3))' ;;
  *-lunp*) echo 'UNCONN 0 0 0.0.0.0:23456 0.0.0.0:* users:(("demo",pid=4242,fd=3))' ;;
  *-ltn*) echo 'LISTEN 0 128 0.0.0.0:12345 0.0.0.0:*' ;;
  *-lun*) echo 'UNCONN 0 0 0.0.0.0:23456 0.0.0.0:*' ;;
esac
MOCK
    chmod +x "$mock/systemctl" "$mock/ss"
    sleep() { :; }
    PATH="$mock:$PATH" verify_port 12345 demo tcp >/dev/null
    PATH="$mock:$PATH" verify_port 23456 demo udp >/dev/null
    if PATH="$mock:$PATH" ss_port_listening 12345 udp; then return 1; fi
    if PATH="$mock:$PATH" verify_port 9999 demo udp >/dev/null 2>&1; then return 1; fi
}

test_layered_transport_verification() {
    local calls="$TEST_ROOT/layer-calls" mock="$TEST_ROOT/mock-hop"
    verify_port() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$calls"; return 0; }
    verify_shadowtls_stack 443 53000
    grep -q '^53000 snell tcp$' "$calls"
    grep -q '^443 shadowtls-snell tcp$' "$calls"

    mkdir -p "$mock"
    cat > "$mock/systemctl" <<'MOCK'
#!/usr/bin/env bash
[ "${1:-}" = is-active ] && exit 0
exit 1
MOCK
    cat > "$mock/nft" <<'MOCK'
#!/usr/bin/env bash
echo 'table inet pd_hy2_hop { chain prerouting { udp dport 30000-30002 redirect to :30000; } }'
MOCK
    chmod +x "$mock/systemctl" "$mock/nft"
    PATH="$mock:$PATH" verify_hy2_hop 30000 3
    if PATH="$mock:$PATH" verify_hy2_hop 30000 4 >/dev/null 2>&1; then return 1; fi
}

test_clear_hop_unit_without_nft() {
    local mock="$TEST_ROOT/mock-clear-hop" unit="$SYSTEMD_DIR/pd-hy2-hop.service"
    mkdir -p "$mock"
    cat > "$mock/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod +x "$mock/systemctl"
    printf '[Unit]\nDescription=PD-proxy: test\n' > "$unit"
    nft() { return 1; }
    PATH="$mock:/usr/bin:/bin" clear_hy2_hop_rules
    [ ! -e "$unit" ]
}

test_unowned_firewall_rule_is_untouched() {
    local log="$TEST_ROOT/firewall-log"
    STATE_FILE="$PD_BASE_DIR/firewall-state"
    printf 'anytls fw_backend=ufw fw_spec=443 fw_proto=tcp fw_owned= status=installed\n' > "$STATE_FILE"
    ufw() { printf called >> "$log"; return 0; }
    firewall_remove_owned anytls
    [ ! -e "$log" ]
}

test_upgrade_rejects_stale_backup_before_stop() {
    local dir="$TEST_ROOT/stale-upgrade" log="$TEST_ROOT/stale-systemctl" output rc
    mkdir -p "$dir"
    printf old > "$dir/anytls-server"
    printf stale > "$dir/anytls-server.bak"
    pkey() { echo anytls; }; pname() { echo AnyTLS; }; psvc() { echo anytls; }
    pbin() { echo "$dir/anytls-server"; }; pdisk() { echo 1; }
    check_disk() { :; }; anytls_get_version() { echo v2.0.0; }
    state_get() { [ "$2" = version ] && echo v1.0.0 || echo ""; }
    systemctl() { printf '%s\n' "$*" >> "$log"; return 1; }
    set +e
    output=$(upgrade_protocol_impl anytls 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    grep -q '发现陈旧备份，拒绝升级' <<< "$output"
    ! grep -q '^stop ' "$log"
    [ "$(cat "$dir/anytls-server.bak")" = stale ]
}

test_upgrade_stops_when_backup_creation_fails() {
    local dir="$TEST_ROOT/failed-backup" log="$TEST_ROOT/failed-backup-systemctl" output rc
    mkdir -p "$dir"; printf old > "$dir/anytls-server"
    pkey() { echo anytls; }; pname() { echo AnyTLS; }; psvc() { echo anytls; }
    pbin() { echo "$dir/anytls-server"; }; pdisk() { echo 1; }
    check_disk() { :; }; anytls_get_version() { echo v2.0.0; }
    state_get() { [ "$2" = version ] && echo v1.0.0 || echo ""; }
    systemctl() { printf '%s\n' "$*" >> "$log"; return 1; }
    cp() { return 1; }
    set +e
    output=$(upgrade_protocol_impl anytls 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    grep -q '创建升级备份失败，已停止' <<< "$output"
    ! grep -q '^stop ' "$log"
}

test_unknown_resource_protection() {
    local guarded="$TEST_ROOT/foreign-anytls"
    pdir() { echo "$guarded"; }
    pbin() { echo "$guarded/anytls-server"; }
    psvc() { echo anytls; }
    mkdir -p "$guarded"
    printf foreign > "$guarded/keep"
    if assert_install_target_available anytls >/dev/null 2>&1; then return 1; fi
    [ "$(cat "$guarded/keep")" = foreign ]
}

test_state_symlink_rejected() {
    local victim="$TEST_ROOT/victim" link="$TEST_ROOT/state-link"
    printf keep > "$victim"
    ln -s "$victim" "$link"
    STATE_FILE="$link"
    if state_set anytls status installed >/dev/null 2>&1; then return 1; fi
    [ "$(cat "$victim")" = keep ]
}

test_lock_symlink_rejected() {
    local real="$TEST_ROOT/real-lock-dir" link="$TEST_ROOT/link-lock-dir"
    mkdir -p "$real"; ln -s "$real" "$link"
    flock() { return 0; }
    if ( LOCK_FILE="$link/pd.lock"; write_lock_acquire ) >/dev/null 2>&1; then return 1; fi
    [ -L "$link" ]
}

test_anytls_surge_output() {
    local dir="$TEST_ROOT/anytls-output" output
    pdir() { echo "$dir"; }
    mkdir -p "$dir"; printf standard > "$dir/.padding"
    IP=203.0.113.10; IP6=""
    state_get() { [ "$2" = listen_ipv4 ] && echo 1 || echo 0; }
    output_header() { :; }; output_footer() { :; }; gen_qr() { :; }
    output=$(anytls_output 443 secret)
    grep -q '^Proxy = anytls, 203\.0\.113\.10, 443, password=secret$' <<< "$output"
}

test_ip_https_consensus_and_overrides() {
    local calls="$TEST_ROOT/ip-calls" output rc
    curl_https() {
        printf '%s\n' "$*" >> "$calls"
        case "$*" in *ifconfig.me*) echo 203.0.113.10 ;; *api.ipify.org*) echo 203.0.113.10 ;; *) echo 198.51.100.9 ;; esac
    }
    set +e
    output=$(fetch_public_ip 4 valid_ipv4 2>/dev/null)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] && [ -z "$output" ]
    ! grep -Ev -- 'https://' "$calls" | grep -q .
    PD_PUBLIC_HOST=proxy.example.com PD_PUBLIC_IPV4=203.0.113.7 PD_PUBLIC_IPV6=2001:db8::7 get_ip
    [ "$PUBLIC_HOST" = proxy.example.com ] && [ "$IP" = 203.0.113.7 ] && [ "$IP6" = 2001:db8::7 ]
}

test_no_unknown_endpoint_output() {
    IP=""; IP6=""; PUBLIC_HOST=""
    state_get() { echo 1; }
    if output_hosts anytls >/dev/null 2>&1; then return 1; fi
}

test_cli_arity_is_exit_2() {
    local rc output
    set +e
    output=$(PD_TEST_MODE=0 "$TEST_SCRIPT" --install anytls extra 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && grep -q '不接受\|需要且只接受' <<< "$output"
}

test_listen_family_respects_bindv6only() {
    has_ipv6() { return 0; }
    bindv6only_value() { echo 1; }
    unset PD_LISTEN_FAMILY
    prepare_listen_family
    [ "$PD_EFFECTIVE_LISTEN_FAMILY" = ipv4 ] && [ "$PD_LISTEN_HOST" = 0.0.0.0 ]
    PD_LISTEN_FAMILY=dual prepare_listen_family >/dev/null
    [ "$PD_EFFECTIVE_LISTEN_FAMILY" = dual ] && [ "$PD_LISTEN_HOST" = :: ]
}

test_verified_families_are_recorded_and_enforced() {
    local recorded="$TEST_ROOT/family-state"
    service_port_family_listening() { return 0; }
    state_set() { printf '%s=%s\n' "$2" "$3" >> "$recorded"; }
    PD_EFFECTIVE_LISTEN_FAMILY=dual
    verify_and_record_listen_families anytls 443 tcp anytls || return 1
    grep -q '^listen_ipv4=1$' "$recorded" || { sed -n '1,20p' "$recorded" >&2; return 1; }
    grep -q '^listen_ipv6=1$' "$recorded" || { sed -n '1,20p' "$recorded" >&2; return 1; }
    return 0
}

test_shadowtls_log_reads_both_units() {
    local calls="$TEST_ROOT/journal-calls"
    pkey() { echo snell; }; psvc() { echo snell; }
    state_installed() { return 0; }
    mkdir -p "$SYSTEMD_DIR"
    printf '[Unit]\nDescription=PD-proxy: ShadowTLS\n' > "$SYSTEMD_DIR/shadowtls-snell.service"
    journalctl() { printf '%s\n' "$*" > "$calls"; }
    show_log snell
    grep -q -- '-u snell -u shadowtls-snell' "$calls"
}

test_checksum_strict_mode_rejects_missing_digest() {
    local f="$TEST_ROOT/no-digest"
    printf data > "$f"
    PD_STRICT_CHECKSUM=1
    if verify_release_checksum "$f" demo >/dev/null 2>&1; then return 1; fi
}

test_archive_traversal_is_rejected() {
    printf '%s\n' binary nested/file | archive_paths_are_safe
    if printf '%s\n' '../escape' | archive_paths_are_safe >/dev/null 2>&1; then return 1; fi
}

test_custom_update_requires_sha256() {
    local f="$TEST_ROOT/update-script" called="$TEST_ROOT/curl-called"
    SCRIPT_URL=https://mirror.example.com/install.sh
    DEFAULT_SCRIPT_URL=https://official.example.com/install.sh
    unset PD_SCRIPT_SHA256
    curl_https() { : > "$called"; }
    if fetch_self_update "$f" >/dev/null 2>&1; then return 1; fi
    [ ! -e "$called" ]
}

test_sensitive_units_are_mode_600_and_sandboxed() {
    local unit
    SYSTEMD_DIR="$TEST_ROOT/secret-systemd"
    mkdir -p "$SYSTEMD_DIR"
    write_systemd anytls /opt/anytls/anytls-server '-l 0.0.0.0:443 -p secret'
    unit="$SYSTEMD_DIR/anytls.service"
    [ "$(stat -f%Lp "$unit" 2>/dev/null || stat -c%a "$unit")" = 600 ]
    grep -q '^DynamicUser=yes$' "$unit"
    grep -q '^ProtectSystem=strict$' "$unit"
}

test_bbr_unsupported_is_nonzero() {
    sysctl() { [ "${1:-}" = -n ] && echo cubic || return 0; }
    uname() { [ "${1:-}" = -r ] && echo 4.8.0 || command uname "$@"; }
    if enable_bbr >/dev/null 2>&1; then return 1; fi
}

test_mss_rule_has_ownership_marker() {
    local log="$TEST_ROOT/mss-log" state="$TEST_ROOT/mss-state"
    command() { [ "${1:-}" = -v ] && [ "${2:-}" = iptables ]; }
    iptables() {
        printf '%s\n' "$*" >> "$log"
        [ "${3:-}" != -C ]
    }
    state_set() { printf '%s=%s\n' "$2" "$3" > "$state"; }
    apply_mss_clamp
    grep -q -- '--comment PD-proxy:mss' "$log"
    grep -q '^mss_owned=1$' "$state"
}

test_bbrv3_unsupported_is_nonzero() {
    detect_virt() { echo lxc; }
    if enable_bbrv3_kernel >/dev/null 2>&1; then return 1; fi
}

test_bbrv3_user_cancel_is_zero() {
    detect_virt() { echo none; }
    uname() { [ "${1:-}" = -m ] && echo x86_64 || command uname "$@"; }
    enable_bbrv3_kernel >/dev/null 2>&1 <<< n
}

test_entry_umask_is_private() {
    [ "$(umask)" = 0077 ] || [ "$(umask)" = 077 ]
}

test_doctor_json_is_read_only() {
    local output rc marker="$TEST_ROOT/doctor-write"
    state_set() { : > "$marker"; return 1; }
    state_installed() { return 1; }
    pkey() { echo "$1"; }; psvc() { echo "$1"; }; pdir() { echo "$TEST_ROOT/$1"; }; pbin() { echo "$TEST_ROOT/$1/bin"; }
    get_ip() { IP=203.0.113.1; IP6=""; PUBLIC_HOST=""; }
    set +e
    output=$(doctor_run 1)
    rc=$?
    set -e
    [ -n "$output" ] && grep -q '^{' <<< "$output" && grep -q '"checks"' <<< "$output"
    [ ! -e "$marker" ]
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
}

test_unknown_cli_parameter_framework() {
    local output rc
    set +e
    output=$(PD_TEST_MODE=0 "$TEST_SCRIPT" --future-reserved-flag 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ] && grep -q '未知参数: --future-reserved-flag' <<< "$output"
}

run_test "explicit transaction rollback survives die/exit" test_transaction_control_flow
run_test "no ERR rollback trap is installed" test_no_err_rollback_trap
run_test "mktemp tracking remains in the caller shell" test_mktemp_tracking
run_test "multiline installed ports are matched exactly and rechecked" test_multiline_port_matching_and_recheck
run_test "verify_port enforces the requested transport" test_transport_specific_verification
run_test "ShadowTLS layers and HY2 hop are strictly verified" test_layered_transport_verification
run_test "HY2 hop unit is removed even when nft is unavailable" test_clear_hop_unit_without_nft
run_test "unowned firewall rules are never deleted" test_unowned_firewall_rule_is_untouched
run_test "stale upgrade backups are rejected before service stop" test_upgrade_rejects_stale_backup_before_stop
run_test "backup creation failure stops upgrade before service stop" test_upgrade_stops_when_backup_creation_fails
run_test "foreign same-name resources are preserved" test_unknown_resource_protection
run_test "atomic state writer rejects symlinks" test_state_symlink_rejected
run_test "write lock rejects symlink paths" test_lock_symlink_rejected
run_test "AnyTLS emits Surge Proxy = anytls" test_anytls_surge_output
run_test "unknown CLI parameters have a reserved rejection test" test_unknown_cli_parameter_framework
run_test "public IP discovery is HTTPS-consistent and supports overrides" test_ip_https_consensus_and_overrides
run_test "unknown public endpoints never generate configuration" test_no_unknown_endpoint_output
run_test "extra CLI arguments exit 2 before privileged work" test_cli_arity_is_exit_2
run_test "listen-family auto handles bindv6only" test_listen_family_respects_bindv6only
run_test "verified address families are persisted" test_verified_families_are_recorded_and_enforced
run_test "Snell logs include both ShadowTLS layers" test_shadowtls_log_reads_both_units
run_test "strict checksum mode rejects unavailable digests" test_checksum_strict_mode_rejects_missing_digest
run_test "archive traversal paths are rejected" test_archive_traversal_is_rejected
run_test "custom update URLs require a pinned SHA-256" test_custom_update_requires_sha256
run_test "argv credential units are private and sandboxed" test_sensitive_units_are_mode_600_and_sandboxed
run_test "unsupported BBR returns nonzero" test_bbr_unsupported_is_nonzero
run_test "MSS rules carry an explicit ownership marker" test_mss_rule_has_ownership_marker
run_test "unsupported BBRv3 returns nonzero" test_bbrv3_unsupported_is_nonzero
run_test "BBRv3 user cancellation returns zero" test_bbrv3_user_cancel_is_zero
run_test "script entry applies umask 077" test_entry_umask_is_private
run_test "doctor JSON remains read-only" test_doctor_json_is_read_only

echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
