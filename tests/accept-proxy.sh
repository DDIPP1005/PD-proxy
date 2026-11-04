#!/usr/bin/env bash
# Explicit client-side acceptance; never run automatically by tests/run.sh.
set -euo pipefail
umask 077

if [ "$#" -ne 3 ]; then
    echo '用法: bash tests/accept-proxy.sh socks5h://127.0.0.1:端口 https://验收地址 响应正文SHA256' >&2
    exit 2
fi
proxy="$1"; url="$2"; expected="$3"
[[ "$proxy" =~ ^socks5h://127\.0\.0\.1:([0-9]+)$ ]] || { echo '仅接受本机无认证 SOCKS5 入口' >&2; exit 2; }
port="${BASH_REMATCH[1]}"
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] || exit 2
[[ "$url" == https://* ]] && [[ "$url" != *$'\n'* ]] && [[ "$url" != *$'\r'* ]] || exit 2
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { echo '需要预先确定的响应正文 SHA-256' >&2; exit 2; }
expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
command -v curl >/dev/null || exit 1
if command -v sha256sum >/dev/null; then
    digest_tool=sha256sum
elif command -v shasum >/dev/null; then
    digest_tool=shasum
else
    echo '缺少 SHA-256 校验工具' >&2; exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/pd-accept-XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
passes=0; failures=0
for attempt in 1 2 3; do
    # -q disables curlrc; explicit proxy + empty noproxy prevents direct bypass.
    # Separate curl processes require a new SOCKS connection for every request.
    if code=$(curl -q --silent --fail --proxy "$proxy" --noproxy '' \
        --proto '=https' --connect-timeout 10 --max-time 30 \
        --output "$work/body" --write-out '%{http_code}' "$url" 2>/dev/null) \
        && [ "$code" = 200 ]; then
        if [ "$digest_tool" = sha256sum ]; then
            actual=$(sha256sum "$work/body")
        else
            actual=$(shasum -a 256 "$work/body")
        fi
        actual="${actual%% *}"
        if [ "$actual" = "$expected" ]; then
            passes=$((passes + 1))
            echo "ok - 代理请求 ${attempt}，TLS 与响应内容校验通过"
            continue
        fi
    fi
    failures=$((failures + 1))
    echo "not ok - 代理请求 $attempt 失败或响应不匹配" >&2
done
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
