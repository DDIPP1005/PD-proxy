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
    set +e
    cleanup_tmpfiles
    rm -rf "$TEST_ROOT"
    exit "$rc"
}
trap test_cleanup EXIT

passes=0
failures=0

pass() { echo "ok - $1"; passes=$((passes + 1)); }
fail() { echo "not ok - $1" >&2; failures=$((failures + 1)); }
run_test_subshell() {
    local fn="$1"
    (
        set -e
        "$fn"
    )
}
run_test() {
    local name="$1" fn="$2" rc had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    run_test_subshell "$fn"
    rc=$?
    [ "$had_errexit" -eq 0 ] || set -e
    if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name"; fi
}

test_framework_errexit_self_check() {
    framework_false_then_true() {
        false
        true
    }
    local rc
    set +e
    run_test_subshell framework_false_then_true
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
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
    [ "$rc" -ne 0 ]
    [ -f "$marker" ]
}

test_no_err_rollback_trap() {
    [ -z "$(trap -p ERR)" ]
}

test_mktemp_tracking() {
    local before=${#_PD_TMPFILES[@]} temp_file
    mktemp_pd temp_file
    [ -f "$temp_file" ]
    [ "${#_PD_TMPFILES[@]}" -eq $((before + 1)) ]
}

test_transaction_tmpfiles_are_scoped_and_cleaned() {
    local tmp_root="$TEST_ROOT/transaction-tmp" snapshot rc
    mkdir -p "$tmp_root"
    TMPDIR="$tmp_root"
    export TMPDIR

    txn_make_success() {
        local f d
        mktemp_pd f
        mktemp_dir_pd d
        [ -f "$f" ]
        [ -d "$d" ]
    }
    txn_make_failure() {
        local f d
        mktemp_pd f
        mktemp_dir_pd d
        [ -f "$f" ]
        [ -d "$d" ]
        return 23
    }
    transaction_commit() {
        [ -d "$_PD_TXN_DIR" ] || return 1
        rm -rf -- "$_PD_TXN_DIR"
        _PD_TXN_DIR=""; _PD_TXN_PROTO=""
    }
    transaction_rollback() {
        [ -d "$_PD_TXN_DIR" ] || return 1
        rm -rf -- "$_PD_TXN_DIR"
        _PD_TXN_DIR=""; _PD_TXN_PROTO=""
    }

    mktemp_dir_pd snapshot
    _PD_TXN_DIR="$snapshot"; _PD_TXN_PROTO=anytls
    transaction_run txn_make_success
    if find "$tmp_root" -maxdepth 1 \( -name 'pd-*' -o -name 'pd-dir-*' \) -print -quit | grep -q .; then
        return 1
    fi

    mktemp_dir_pd snapshot
    _PD_TXN_DIR="$snapshot"; _PD_TXN_PROTO=anytls
    set +e
    transaction_run txn_make_failure
    rc=$?
    set -e
    [ "$rc" -eq 23 ]
    if find "$tmp_root" -maxdepth 1 \( -name 'pd-*' -o -name 'pd-dir-*' \) -print -quit | grep -q .; then
        return 1
    fi
}

test_extract_zip_binary_cleans_all_paths() {
    local tmp_root="$TEST_ROOT/extract-tmp" archive="$TEST_ROOT/fake.zip" target="$TEST_ROOT/extracted" rc
    mkdir -p "$tmp_root"
    : > "$archive"
    TMPDIR="$tmp_root"
    export TMPDIR
    TEST_UNZIP_FAIL=1
    unzip() {
        if [ "${1:-}" = -Z1 ]; then
            echo demo-bin
            return 0
        fi
        [ "$TEST_UNZIP_FAIL" = 0 ] || return 1
        local dest="${4:-}"
        printf binary > "$dest/demo-bin"
    }
    set +e
    extract_zip_binary "$archive" demo-bin "$target" demo
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    if find "$tmp_root" -maxdepth 1 -name 'pd-dir-*' -print -quit | grep -q .; then return 1; fi

    TEST_UNZIP_FAIL=0
    extract_zip_binary "$archive" demo-bin "$target" demo
    [ -x "$target" ]
    if find "$tmp_root" -maxdepth 1 -name 'pd-dir-*' -print -quit | grep -q .; then return 1; fi
}

test_speedtest_target_ownership_and_atomic_rollback() {
    local root="$TEST_ROOT/speedtest" target="$TEST_ROOT/speedtest/bin/speedtest" rc old_digest
    mkdir -p "$root/bin" "$root/state"
    SPEEDTEST_BIN="$target"
    BASE_DIR="$root/state"
    STATE_FILE="$BASE_DIR/state"
    PATH=/usr/bin:/bin

    download_https() { : > "$2"; }
    tar() {
        if [ "${1:-}" = -tzf ]; then
            echo speedtest
            return 0
        fi
        local dest="" previous="" arg
        for arg in "$@"; do
            if [ "$previous" = -C ]; then dest="$arg"; fi
            previous="$arg"
        done
        [ -n "$dest" ] || return 1
        printf '#!/bin/sh\necho new-speedtest\n' > "$dest/speedtest"
    }

    printf foreign > "$target"
    chmod 0644 "$target"
    set +e
    install_speedtest_cli >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    [ "$(cat "$target")" = foreign ]

    rm -f "$target"
    ln -s "$root/missing" "$target"
    set +e
    install_speedtest_cli >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    [ -L "$target" ]

    rm -f "$target"
    printf owned-old > "$target"
    chmod 0644 "$target"
    old_digest=$(sha256_file "$target")
    state_set_fields system "speedtest_owned=1" "speedtest_sha256=$old_digest"
    install_speedtest_cli
    [ -x "$target" ]
    grep -q new-speedtest "$target"
    [ "$(state_get system speedtest_owned)" = 1 ]
    [ "$(state_get system speedtest_sha256)" = "$(sha256_file "$target")" ]

    printf rollback-old > "$target"
    chmod 0644 "$target"
    old_digest=$(sha256_file "$target")
    state_set_fields system "speedtest_owned=1" "speedtest_sha256=$old_digest"
    state_set_fields() { return 1; }
    set +e
    install_speedtest_cli >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    [ "$(cat "$target")" = rollback-old ]
}

test_systemd_dollar_credentials_round_trip() {
    local raw='pre$VAR-${HOME}-$$-post' escaped unit dir="$TEST_ROOT/dollar-systemd"
    mkdir -p "$dir/anytls"
    SYSTEMD_DIR="$dir"
    PD_LISTEN_HOST=0.0.0.0
    escaped=$(systemd_escape_arg "$raw")
    [ "$escaped" = 'pre$$VAR-$${HOME}-$$$$-post' ]
    [ "$(systemd_unescape_arg "$escaped")" = "$raw" ]
    if systemd_unescape_arg '$VAR' >/dev/null 2>&1; then return 1; fi

    write_shadowtls_unit 443 53000 example.com:443 "$raw" --v3 /opt/shadowtls/shadow-tls
    unit="$SYSTEMD_DIR/shadowtls-snell.service"
    grep -Fq -- '--password pre$$VAR-$${HOME}-$$$$-post' "$unit"
    [ "$(unit_password_value "$unit")" = "$raw" ]

    pdir() { echo "$dir/anytls"; }
    printf '%s\n' "$raw" > "$dir/anytls/.password"
    write_systemd anytls /opt/anytls/anytls-server "$(anytls_service_args 8443)"
    unit="$SYSTEMD_DIR/anytls.service"
    grep -Fq -- '-p pre$$VAR-$${HOME}-$$$$-post' "$unit"
    [ "$(unit_arg_value -p "$unit")" = "$raw" ]
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
    [ "$picked" = 23457 ]
    state_port_range_conflict 23456 23456 ""
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

test_run_write_locked_isolates_errexit_and_releases() {
    local marker="$TEST_ROOT/locked-after-false" releases="$TEST_ROOT/lock-releases" rc e_was_preserved
    write_lock_acquire() { _PD_LOCK_DEPTH=1; }
    write_lock_release() { _PD_LOCK_DEPTH=0; printf 'released\n' >> "$releases"; }
    locked_failure() {
        false
        : > "$marker"
    }

    set -e
    if run_write_locked locked_failure; then
        return 1
    else
        rc=$?
    fi
    [ "$rc" -ne 0 ]
    [[ $- == *e* ]]
    [ ! -e "$marker" ]
    [ "$_PD_LOCK_DEPTH" -eq 0 ]

    set +e
    run_write_locked locked_failure
    rc=$?
    [[ $- == *e* ]] && e_was_preserved=0 || e_was_preserved=1
    set -e
    [ "$rc" -ne 0 ]
    [ "$e_was_preserved" -eq 1 ]
    [ ! -e "$marker" ]
    [ "$_PD_LOCK_DEPTH" -eq 0 ]
    [ "$(wc -l < "$releases" | tr -d ' ')" -eq 2 ]
}

test_run_write_locked_reports_release_failure() {
    local rc e_was_preserved
    LOCK_FILE="$TEST_ROOT/release-failure.lock"
    _PD_LOCK_DEPTH=0
    flock() {
        [ "${1:-}" != -u ] || return 37
        return 0
    }
    locked_success() { return 0; }
    locked_failure_code() { return 23; }
    fd_200_is_closed() { ! { : >&200; } 2>/dev/null; }

    set +e
    run_write_locked locked_success >/dev/null 2>&1
    rc=$?
    [[ $- == *e* ]] && e_was_preserved=0 || e_was_preserved=1
    set -e
    [ "$rc" -eq 37 ]
    [ "$e_was_preserved" -eq 1 ]
    [ "$_PD_LOCK_DEPTH" -eq 0 ]
    fd_200_is_closed

    set +e
    run_write_locked locked_failure_code >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -eq 23 ]
    [ "$_PD_LOCK_DEPTH" -eq 0 ]
    fd_200_is_closed
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

test_ipv6_only_protocol_outputs() {
    local dir="$TEST_ROOT/ipv6-outputs" ipv6="2001:db8::42"
    local snell_standard snell_shadow hy2_single hy2_hop vless anytls all_output
    mkdir -p "$dir/snell" "$dir/hy2" "$dir/vless" "$dir/anytls" "$dir/systemd"
    printf public-key > "$dir/vless/.pubkey"
    printf short-id > "$dir/vless/.shortid"
    printf 'addons.mozilla.org:443' > "$dir/vless/.dest"
    printf tcp > "$dir/vless/.transport"
    printf chrome > "$dir/vless/.fp"
    printf standard > "$dir/anytls/.padding"

    pdir() { echo "$dir/$1"; }
    output_header() { :; }
    output_footer() { :; }
    gen_qr() { printf 'QR: %s\n' "$1"; }
    state_get() {
        case "$2" in
            listen_ipv4) echo 0 ;;
            listen_ipv6) echo 1 ;;
            hop) echo "${TEST_HY2_HOP:-0}" ;;
            *) echo "" ;;
        esac
    }
    snell_shadowtls_unit_values() {
        [ "${TEST_SNELL_SHADOW:-0}" = 1 ] || return 1
        printf 'tls-secret\ntls.example.com:443\n3\n'
    }

    PUBLIC_HOST=""; IP=""; IP6="$ipv6"
    SYSTEMD_DIR="$dir/systemd"

    snell_standard=$(snell_output 443 snell-secret)
    TEST_SNELL_SHADOW=1
    printf '[Unit]\nDescription=PD-proxy: ShadowTLS\n' > "$SYSTEMD_DIR/shadowtls-snell.service"
    snell_shadow=$(snell_output 444 snell-secret)

    TEST_HY2_HOP=0
    hy2_single=$(hy2_output 8443 hy2-secret)
    TEST_HY2_HOP=3
    hy2_hop=$(hy2_output 9443 hy2-secret)
    vless=$(vless_output 10443 00000000-0000-0000-0000-000000000001)
    anytls=$(anytls_output 11443 anytls-secret)

    all_output=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
        "$snell_standard" "$snell_shadow" "$hy2_single" "$hy2_hop" "$vless" "$anytls")

    ! grep -Eq '@:[0-9]' <<< "$all_output"
    ! grep -Eq ',[[:space:]]*,[[:space:]]*[0-9]' <<< "$all_output"
    ! grep -q -- '-IPv6' <<< "$all_output"

    grep -Fq "Proxy = snell, [$ipv6], 443, psk=snell-secret, version=5" <<< "$snell_standard"
    grep -Fq "Proxy = snell, [$ipv6], 444, psk=snell-secret, version=4" <<< "$snell_shadow"
    grep -Fq "Proxy = hysteria2, [$ipv6], 8443, password=hy2-secret" <<< "$hy2_single"
    grep -Fq "QR: hysteria2://hy2-secret@[$ipv6]:8443?" <<< "$hy2_single"
    grep -Fq "Proxy = hysteria2, [$ipv6], 9443-9445, password=hy2-secret" <<< "$hy2_hop"
    grep -Fq "QR: hysteria2://hy2-secret@[$ipv6]:9443?" <<< "$hy2_hop"
    grep -Fq "QR: vless://00000000-0000-0000-0000-000000000001@[$ipv6]:10443?" <<< "$vless"
    grep -Fq "vless://00000000-0000-0000-0000-000000000001@[$ipv6]:10443?" <<< "$vless"
    grep -Fq "Proxy = anytls, [$ipv6], 11443, password=anytls-secret" <<< "$anytls"
    grep -Fq "QR: anytls://anytls-secret@[$ipv6]:11443" <<< "$anytls"
    grep -Fq "anytls://anytls-secret@[$ipv6]:11443" <<< "$anytls"
}

test_dual_stack_output_is_not_duplicated() {
    local dir="$TEST_ROOT/dual-output" output
    mkdir -p "$dir"
    printf standard > "$dir/.padding"
    pdir() { echo "$dir"; }
    state_get() {
        case "$2" in listen_ipv4|listen_ipv6) echo 1 ;; *) echo 0 ;; esac
    }
    output_header() { :; }; output_footer() { :; }; gen_qr() { :; }
    PUBLIC_HOST=""; IP=203.0.113.10; IP6=2001:db8::10
    output=$(anytls_output 443 secret)
    [ "$(grep -c '^Proxy = anytls, 203\.0\.113\.10, 443' <<< "$output")" -eq 1 ]
    [ "$(grep -c '^Proxy-IPv6 = anytls, \[2001:db8::10\], 443' <<< "$output")" -eq 1 ]
    [ "$(grep -c '^anytls://secret@203\.0\.113\.10:443' <<< "$output")" -eq 1 ]
    [ "$(grep -c '^anytls://secret@\[2001:db8::10\]:443' <<< "$output")" -eq 1 ]
}

test_uninstall_failure_exit_is_preserved() {
    local script="$TEST_ROOT/uninstall-cli.sh" output rc
    awk '
        /^check_root\(\) \{/ {
            print "check_root() { :; }"
            skip=1
            next
        }
        /^detect_os\(\) \{/ {
            print "detect_os() { :; }"
            skip=1
            next
        }
        /^run_write_locked\(\) \{/ {
            print "run_write_locked() { return 23; }"
            skip=1
            next
        }
        skip {
            if ($0 == "}") skip=0
            next
        }
        { print }
    ' "$TEST_SCRIPT" > "$script"
    chmod +x "$script"
    set +e
    output=$(PD_TEST_MODE=0 "$script" --uninstall anytls 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 23 ]
    [ -z "$output" ]
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
    [ "$rc" -ne 0 ]
    [ -z "$output" ]
    ! grep -Ev -- 'https://' "$calls" | grep -q .
    PD_PUBLIC_HOST=proxy.example.com PD_PUBLIC_IPV4=203.0.113.7 PD_PUBLIC_IPV6=2001:db8::7 get_ip
    [ "$PUBLIC_HOST" = proxy.example.com ]
    [ "$IP" = 203.0.113.7 ]
    [ "$IP6" = 2001:db8::7 ]
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
    [ "$rc" -eq 2 ]
    grep -q '不接受\|需要且只接受' <<< "$output"
}

test_listen_family_respects_bindv6only() {
    has_ipv6() { return 0; }
    bindv6only_value() { echo 1; }
    unset PD_LISTEN_FAMILY
    prepare_listen_family
    [ "$PD_EFFECTIVE_LISTEN_FAMILY" = ipv4 ]
    [ "$PD_LISTEN_HOST" = 0.0.0.0 ]
    PD_LISTEN_FAMILY=dual prepare_listen_family >/dev/null
    [ "$PD_EFFECTIVE_LISTEN_FAMILY" = dual ]
    [ "$PD_LISTEN_HOST" = :: ]
}

test_service_listener_uses_ss_family_filters() {
    local TEST_SS4="" TEST_SS6="" TEST_BINDONLY=1 rc
    systemctl() {
        [ "${1:-}" = show ] || return 1
        echo 4242
    }
    bindv6only_value() { echo "$TEST_BINDONLY"; }
    bindv6only_confirmed_value() { echo "$TEST_BINDONLY"; }
    ss() {
        case " $* " in
            *' -4 '*) [ -z "$TEST_SS4" ] || printf '%s\n' "$TEST_SS4" ;;
            *' -6 '*) [ -z "$TEST_SS6" ] || printf '%s\n' "$TEST_SS6" ;;
            *) return 1 ;;
        esac
    }
    family_is() {
        local expected="$1" family="$2" got
        set +e
        service_port_family_listening 443 tcp demo "$family"
        got=$?
        set -e
        if [ "$expected" = yes ]; then
            [ "$got" -eq 0 ]
        else
            [ "$got" -ne 0 ]
        fi
    }

    TEST_SS4='LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("demo",pid=4242,fd=3))'
    TEST_SS6=""; TEST_BINDONLY=1
    family_is yes ipv4
    family_is no ipv6

    TEST_SS4=""
    TEST_SS6='LISTEN 0 128 [::]:443 [::]:* users:(("demo",pid=4242,fd=3))'
    TEST_BINDONLY=1
    family_is no ipv4
    family_is yes ipv6
    TEST_BINDONLY=0
    family_is yes ipv4
    family_is yes ipv6

    TEST_SS6='LISTEN 0 128 *:443 *:* users:(("demo",pid=4242,fd=3))'
    family_is yes ipv4
    family_is yes ipv6

    TEST_SS6='LISTEN 0 128 [2001:db8::1]:443 [::]:* users:(("demo",pid=4242,fd=3))'
    family_is no ipv4
    family_is yes ipv6

    TEST_SS4='LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("demo",pid=4242,fd=3))'
    TEST_SS6='LISTEN 0 128 [::]:443 [::]:* users:(("demo",pid=4242,fd=3))'
    TEST_BINDONLY=1
    family_is yes ipv4
    family_is yes ipv6
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

test_doctor_checks_each_owned_iptables_family() {
    local TEST_OWNED=iptables4,iptables6 TEST_IP4_RC=0 TEST_IP6_RC=1 status message
    state_get() {
        case "$2" in
            fw_backend) echo iptables ;;
            fw_spec) echo 443 ;;
            fw_proto) echo tcp ;;
            fw_owned) echo "$TEST_OWNED" ;;
        esac
    }
    command() {
        if [ "${1:-}" = -v ]; then
            case "${2:-}" in iptables|ip6tables) return 0 ;; esac
        fi
        builtin command "$@"
    }
    iptables() { return "$TEST_IP4_RC"; }
    ip6tables() { return "$TEST_IP6_RC"; }
    doctor_add() { status="$2"; message="$3"; }

    doctor_firewall anytls
    [ "$status" = fail ]
    grep -q 'iptables6' <<< "$message"

    TEST_OWNED=iptables4
    TEST_IP4_RC=0
    TEST_IP6_RC=1
    status=""; message=""
    doctor_firewall anytls
    [ "$status" = ok ]

    TEST_OWNED=""
    TEST_IP4_RC=0
    status=""; message=""
    doctor_firewall anytls
    [ "$status" = ok ]
    grep -q 'legacy-ipv4' <<< "$message"
}

test_doctor_confirmed_family_drift_fails_json() {
    local dir="$TEST_ROOT/doctor-drift" output rc
    local ALL_PROTOS=anytls
    TEST_DOCTOR_DIR="$dir"
    mkdir -p "$dir" "$SYSTEMD_DIR"
    printf '#!/bin/sh\n' > "$dir/anytls-server"
    chmod +x "$dir/anytls-server"
    printf '[Unit]\nDescription=PD-proxy: AnyTLS\n' > "$SYSTEMD_DIR/anytls.service"

    id() { [ "${1:-}" = -u ] && echo 0 || return 1; }
    uname() { [ "${1:-}" = -m ] && echo x86_64 || command uname "$@"; }
    sysctl() { [ "${1:-}" = -n ] && echo bbr || return 1; }
    systemctl() {
        case "${1:-}" in
            is-active) return 0 ;;
            is-system-running) echo running ;;
            show) echo 4242 ;;
            *) return 1 ;;
        esac
    }
    state_installed() { [ "$1" = anytls ]; }
    state_get() {
        case "$2" in
            port) echo 443 ;;
            listen_ipv4) echo 0 ;;
            listen_ipv6) echo 1 ;;
        esac
    }
    pkey() { echo anytls; }
    psvc() { echo anytls; }
    pdir() { echo "$TEST_DOCTOR_DIR"; }
    pbin() { echo "$TEST_DOCTOR_DIR/anytls-server"; }
    unit_is_pd_owned() { return 0; }
    service_port_listening() { return 0; }
    ss() {
        case " $* " in
            *' -4 '*) printf '%s\n' 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:(("anytls",pid=4242,fd=3))' ;;
            *' -6 '*) : ;;
            *) return 1 ;;
        esac
    }
    doctor_firewall() { doctor_add anytls.firewall warn "mock firewall"; }
    get_ip() { IP=203.0.113.1; IP6=""; PUBLIC_HOST=""; }

    set +e
    output=$(doctor_run 1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ]
    grep -q '"ok":false' <<< "$output"
    grep -q '"id":"anytls.family","status":"fail"' <<< "$output"
}

test_doctor_ipv6_wildcard_ipv4_is_unknown() {
    local dir="$TEST_ROOT/doctor-wildcard" family_status="" family_message=""
    local bindonly_read="$TEST_ROOT/doctor-wildcard-bindonly-read"
    TEST_DOCTOR_DIR="$dir"
    mkdir -p "$dir" "$SYSTEMD_DIR"
    printf '#!/bin/sh\n' > "$dir/anytls-server"
    chmod +x "$dir/anytls-server"
    printf '[Unit]\nDescription=PD-proxy: AnyTLS\n' > "$SYSTEMD_DIR/anytls.service"

    id() { [ "${1:-}" = -u ] && echo 0 || return 1; }
    systemctl() {
        case "${1:-}" in
            is-active) return 0 ;;
            show) echo 4242 ;;
            *) return 1 ;;
        esac
    }
    state_installed() { return 0; }
    state_get() {
        case "$2" in
            port) echo 443 ;;
            listen_ipv4|listen_ipv6) echo 1 ;;
        esac
    }
    pkey() { echo anytls; }
    psvc() { echo anytls; }
    pdir() { echo "$TEST_DOCTOR_DIR"; }
    pbin() { echo "$TEST_DOCTOR_DIR/anytls-server"; }
    unit_is_pd_owned() { return 0; }
    service_port_listening() { return 0; }
    ss() {
        case " $* " in
            *' -4 '*) : ;;
            *' -6 '*) printf '%s\n' 'LISTEN 0 128 [::]:443 [::]:* users:(("anytls",pid=4242,fd=3))' ;;
            *) return 1 ;;
        esac
    }
    bindv6only_confirmed_value() { : > "$bindonly_read"; echo 1; }
    doctor_firewall() { :; }
    doctor_add() {
        if [ "$1" = anytls.family ]; then
            family_status=$2
            family_message=$3
        fi
    }

    doctor_protocol anytls
    [ "$family_status" = warn ]
    grep -q '无法可靠确认' <<< "$family_message"
    [ ! -e "$bindonly_read" ]
}

test_doctor_unconfirmed_family_probe_warns() {
    local dir="$TEST_ROOT/doctor-unconfirmed" family_status="" family_message=""
    TEST_DOCTOR_DIR="$dir"
    mkdir -p "$dir" "$SYSTEMD_DIR"
    printf '#!/bin/sh\n' > "$dir/anytls-server"
    chmod +x "$dir/anytls-server"
    printf '[Unit]\nDescription=PD-proxy: AnyTLS\n' > "$SYSTEMD_DIR/anytls.service"

    id() { [ "${1:-}" = -u ] && echo 0 || return 1; }
    systemctl() { [ "${1:-}" = is-active ]; }
    state_installed() { return 0; }
    state_get() {
        case "$2" in
            port) echo 443 ;;
            listen_ipv4) echo 1 ;;
            listen_ipv6) echo 0 ;;
        esac
    }
    pkey() { echo anytls; }
    psvc() { echo anytls; }
    pdir() { echo "$TEST_DOCTOR_DIR"; }
    pbin() { echo "$TEST_DOCTOR_DIR/anytls-server"; }
    unit_is_pd_owned() { return 0; }
    service_port_listening() { return 0; }
    service_port_family_probe() { return 2; }
    doctor_firewall() { :; }
    doctor_add() {
        if [ "$1" = anytls.family ]; then
            family_status=$2
            family_message=$3
        fi
    }

    doctor_protocol anytls
    [ "$family_status" = warn ]
    grep -q '无法可靠确认' <<< "$family_message"
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

test_stop_service_failure_paths() {
    local output rc TEST_STOP_FAIL="" TEST_ACTIVE_SERVICE="" TEST_CLEAR_FAIL=0
    mkdir -p "$SYSTEMD_DIR"
    printf '[Unit]\nDescription=PD-proxy: ShadowTLS\n' > "$SYSTEMD_DIR/shadowtls-snell.service"
    pkey() { echo "$1"; }
    psvc() { [ "$1" = hy2 ] && echo hysteria2 || echo "$1"; }
    pname() { [ "$1" = snell ] && echo Snell || echo Hysteria2; }
    state_installed() { return 0; }
    clear_hy2_hop_rules() { [ "$TEST_CLEAR_FAIL" -eq 0 ]; }
    systemctl() {
        case "${1:-}" in
            stop) [ "${2:-}" != "$TEST_STOP_FAIL" ] ;;
            is-active) [ "${3:-}" = "$TEST_ACTIVE_SERVICE" ] ;;
            *) return 0 ;;
        esac
    }
    assert_stop_failure() {
        local proto="$1" success="$2"
        set +e
        output=$(stop_service "$proto" 2>&1)
        rc=$?
        set -e
        [ "$rc" -ne 0 ]
        ! grep -Fq "$success" <<< "$output"
    }

    TEST_STOP_FAIL=shadowtls-snell
    assert_stop_failure snell 'Snell 已停止'
    TEST_STOP_FAIL=snell
    assert_stop_failure snell 'Snell 已停止'
    TEST_STOP_FAIL=""; TEST_ACTIVE_SERVICE=snell
    assert_stop_failure snell 'Snell 已停止'
    TEST_ACTIVE_SERVICE=""; TEST_CLEAR_FAIL=1
    assert_stop_failure hy2 'Hysteria2 已停止'
}

test_start_service_failure_paths() {
    local output rc calls="$TEST_ROOT/start-service-calls"
    local TEST_SETUP_FAIL=0 TEST_HOP_FAIL=0 TEST_PORT_FAIL=0 TEST_STACK_FAIL=0 TEST_FAMILY_FAIL=0
    mkdir -p "$SYSTEMD_DIR"
    printf '[Unit]\nDescription=PD-proxy: ShadowTLS\n' > "$SYSTEMD_DIR/shadowtls-snell.service"
    pkey() { echo "$1"; }
    psvc() { [ "$1" = hy2 ] && echo hysteria2 || echo "$1"; }
    pname() { case "$1" in snell) echo Snell ;; hy2) echo Hysteria2 ;; *) echo AnyTLS ;; esac; }
    pdir() { echo "$TEST_ROOT/$1"; }
    state_installed() { return 0; }
    state_get() {
        case "$2" in
            port) [ "$1" = snell ] && echo 443 || echo 30000 ;;
            hop) [ "$1" = hy2 ] && echo 3 || echo 0 ;;
            listen_family) echo auto ;;
        esac
    }
    conf_value() { echo 127.0.0.1:53000; }
    systemctl() { [ "${1:-}" = start ]; }
    setup_hy2_hop_rules() { printf 'setup\n' >> "$calls"; [ "$TEST_SETUP_FAIL" -eq 0 ]; }
    verify_hy2_hop() { printf 'hop\n' >> "$calls"; [ "$TEST_HOP_FAIL" -eq 0 ]; }
    verify_port() { printf 'port %s %s %s\n' "$1" "$2" "$3" >> "$calls"; [ "$TEST_PORT_FAIL" -eq 0 ]; }
    verify_shadowtls_stack() { printf 'stack %s %s\n' "$1" "$2" >> "$calls"; [ "$TEST_STACK_FAIL" -eq 0 ]; }
    verify_and_record_listen_families() { printf 'family\n' >> "$calls"; [ "$TEST_FAMILY_FAIL" -eq 0 ]; }
    assert_start_failure() {
        local proto="$1" success="$2"
        set +e
        output=$(start_service "$proto" 2>&1)
        rc=$?
        set -e
        [ "$rc" -ne 0 ]
        ! grep -Fq "$success" <<< "$output"
    }

    TEST_SETUP_FAIL=1
    assert_start_failure hy2 'Hysteria2 已启动'
    ! grep -q '^hop$' "$calls"
    : > "$calls"; TEST_SETUP_FAIL=0; TEST_HOP_FAIL=1
    assert_start_failure hy2 'Hysteria2 已启动'
    grep -q '^hop$' "$calls"
    : > "$calls"; TEST_HOP_FAIL=0; TEST_STACK_FAIL=1
    assert_start_failure snell 'Snell 已启动'
    grep -q '^stack 443 53000$' "$calls"
    : > "$calls"; TEST_STACK_FAIL=0; TEST_PORT_FAIL=1
    assert_start_failure anytls 'AnyTLS 已启动'
    grep -q '^port 30000 anytls tcp$' "$calls"
    : > "$calls"; TEST_PORT_FAIL=0; TEST_FAMILY_FAIL=1
    assert_start_failure anytls 'AnyTLS 已启动'
    grep -q '^family$' "$calls"
}

test_restart_service_failure_paths() {
    local output rc calls="$TEST_ROOT/restart-service-calls" repair="$TEST_ROOT/restart-repair-called"
    local TEST_SETUP_FAIL=0 TEST_HOP_FAIL=0 TEST_STACK_FAIL=0 TEST_FAMILY_FAIL=0
    mkdir -p "$SYSTEMD_DIR"
    printf '[Unit]\nDescription=PD-proxy: ShadowTLS\n' > "$SYSTEMD_DIR/shadowtls-snell.service"
    pkey() { echo "$1"; }
    psvc() { [ "$1" = hy2 ] && echo hysteria2 || echo "$1"; }
    pname() { case "$1" in snell) echo Snell ;; hy2) echo Hysteria2 ;; *) echo AnyTLS ;; esac; }
    pdir() { echo "$TEST_ROOT/$1"; }
    state_installed() { return 0; }
    state_get() {
        case "$2" in
            port) [ "$1" = snell ] && echo 443 || echo 30000 ;;
            hop) [ "$1" = hy2 ] && echo 3 || echo 0 ;;
            listen_family) echo auto ;;
        esac
    }
    conf_value() { echo 127.0.0.1:53000; }
    systemctl() { [ "${1:-}" = restart ]; }
    setup_hy2_hop_rules() { printf 'setup\n' >> "$calls"; [ "$TEST_SETUP_FAIL" -eq 0 ]; }
    verify_hy2_hop() { printf 'hop\n' >> "$calls"; [ "$TEST_HOP_FAIL" -eq 0 ]; }
    verify_port() { return 0; }
    verify_shadowtls_stack() { printf 'stack %s %s\n' "$1" "$2" >> "$calls"; [ "$TEST_STACK_FAIL" -eq 0 ]; }
    verify_and_record_listen_families() { printf 'family\n' >> "$calls"; [ "$TEST_FAMILY_FAIL" -eq 0 ]; }
    repair_snell_ipv6() { : > "$repair"; }
    repair_vless_ipv6() { : > "$repair"; }
    repair_anytls_ipv6() { : > "$repair"; }
    assert_restart_failure() {
        local proto="$1" success="$2"
        set +e
        output=$(restart_service "$proto" 2>&1)
        rc=$?
        set -e
        [ "$rc" -ne 0 ]
        ! grep -Fq "$success" <<< "$output"
    }

    TEST_SETUP_FAIL=1
    assert_restart_failure hy2 'Hysteria2 已重启'
    ! grep -q '^hop$' "$calls"
    : > "$calls"; TEST_SETUP_FAIL=0; TEST_HOP_FAIL=1
    assert_restart_failure hy2 'Hysteria2 已重启'
    grep -q '^hop$' "$calls"
    : > "$calls"; TEST_HOP_FAIL=0; TEST_STACK_FAIL=1
    assert_restart_failure snell 'Snell 已重启'
    grep -q '^stack 443 53000$' "$calls"
    : > "$calls"; TEST_STACK_FAIL=0; TEST_FAMILY_FAIL=1
    assert_restart_failure anytls 'AnyTLS 已重启'
    grep -q '^family$' "$calls"
    [ ! -e "$repair" ]
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
    command() {
        [ "${1:-}" = -v ]
        [ "${2:-}" = iptables ]
    }
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
    [ -n "$output" ]
    grep -q '^{' <<< "$output"
    grep -q '"checks"' <<< "$output"
    [ ! -e "$marker" ]
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
}

test_unknown_cli_parameter_framework() {
    local output rc
    set +e
    output=$(PD_TEST_MODE=0 "$TEST_SCRIPT" --future-reserved-flag 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq 2 ]
    grep -q '未知参数: --future-reserved-flag' <<< "$output"
}

run_test "test runner preserves errexit after an earlier failed assertion" test_framework_errexit_self_check
run_test "explicit transaction rollback survives die/exit" test_transaction_control_flow
run_test "no ERR rollback trap is installed" test_no_err_rollback_trap
run_test "mktemp tracking remains in the caller shell" test_mktemp_tracking
run_test "transaction subshell tempfiles are scoped and cleaned" test_transaction_tmpfiles_are_scoped_and_cleaned
run_test "zip extraction cleans temp directories on every path" test_extract_zip_binary_cleans_all_paths
run_test "speedtest install protects ownership and rolls back atomically" test_speedtest_target_ownership_and_atomic_rollback
run_test "systemd dollar credentials round-trip literally" test_systemd_dollar_credentials_round_trip
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
run_test "write lock isolates errexit and preserves caller state" test_run_write_locked_isolates_errexit_and_releases
run_test "write lock reports release failure after a successful operation" test_run_write_locked_reports_release_failure
run_test "AnyTLS emits Surge Proxy = anytls" test_anytls_surge_output
run_test "IPv6-only protocol outputs always use a bracketed primary host" test_ipv6_only_protocol_outputs
run_test "dual-stack output keeps one primary and one IPv6 addition" test_dual_stack_output_is_not_duplicated
run_test "uninstall CLI preserves a failing operation exit code" test_uninstall_failure_exit_is_preserved
run_test "unknown CLI parameters have a reserved rejection test" test_unknown_cli_parameter_framework
run_test "public IP discovery is HTTPS-consistent and supports overrides" test_ip_https_consensus_and_overrides
run_test "unknown public endpoints never generate configuration" test_no_unknown_endpoint_output
run_test "extra CLI arguments exit 2 before privileged work" test_cli_arity_is_exit_2
run_test "listen-family auto handles bindv6only" test_listen_family_respects_bindv6only
run_test "service listeners use ss address-family filters" test_service_listener_uses_ss_family_filters
run_test "verified address families are persisted" test_verified_families_are_recorded_and_enforced
run_test "doctor checks every owned iptables family" test_doctor_checks_each_owned_iptables_family
run_test "doctor JSON fails on confirmed listen-family drift" test_doctor_confirmed_family_drift_fails_json
run_test "doctor treats IPv6 wildcard IPv4 reachability as unknown" test_doctor_ipv6_wildcard_ipv4_is_unknown
run_test "doctor warns when listen families cannot be confirmed" test_doctor_unconfirmed_family_probe_warns
run_test "Snell logs include both ShadowTLS layers" test_shadowtls_log_reads_both_units
run_test "stop failures never report a stopped service" test_stop_service_failure_paths
run_test "start verification failures never report a started service" test_start_service_failure_paths
run_test "restart verification failures never report a restarted service" test_restart_service_failure_paths
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
