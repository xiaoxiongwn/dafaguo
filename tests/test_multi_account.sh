#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$REPO_DIR/multi-account.sh"
SANDBOX="$REPO_DIR/.test-multi-account"
DATA_DIR="$SANDBOX/data"
SYSTEMD_DIR="$SANDBOX/systemd"
SOURCE_ENV="$SANDBOX/source.env"

cleanup() {
  pkill -f "dafaguo-test-runner" 2>/dev/null || true
  pkill -f "fake_sing_box" 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT
cleanup
mkdir -p "$DATA_DIR" "$SYSTEMD_DIR"
cat > "$SANDBOX/fake_runner.sh" <<'FAKE'
#!/usr/bin/env bash
exec -a dafaguo-test-runner sleep 600
FAKE
chmod 700 "$SANDBOX/fake_runner.sh"

fail() {
  printf '失败: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "文件不存在: $1"
}

assert_not_file() {
  [[ ! -e "$1" ]] || fail "文件不应存在: $1"
}

assert_contains() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "$file 不包含: $text"
}

assert_mode() {
  local file=$1 expected=$2 actual
  actual=$(stat -c '%a' "$file")
  [[ "$actual" == "$expected" ]] || fail "$file 权限为 $actual，预期 $expected"
}

run_multi() {
  DAFAGUO_MULTI_HOME="$DATA_DIR" \
  DAFAGUO_SYSTEMD_USER_DIR="$SYSTEMD_DIR" \
  DAFAGUO_PYTHON_BIN="$SANDBOX/fake_runner.sh" \
  "$SCRIPT" "$@"
}

[[ -x "$SCRIPT" ]] || fail "multi-account.sh 不存在或不可执行"

cat > "$SOURCE_ENV" <<'ENV'
EMAIL=test@example.com
PASSWORD=not-a-real-password
TG_BOT_TOKEN=
TG_CHAT_ID=
NOTIFY_NAME=测试账号
PROXY=
NH_WAIT=30
ENV
chmod 600 "$SOURCE_ENV"

run_multi add account_a 06:30 "$SOURCE_ENV"
assert_file "$DATA_DIR/accounts/account_a/account.env"
assert_mode "$DATA_DIR/accounts/account_a/account.env" 600
assert_file "$DATA_DIR/accounts/account_a/schedule"
assert_contains "$DATA_DIR/accounts/account_a/schedule" '06:30'
mkdir -p "$DATA_DIR/accounts/account_a/logs" "$DATA_DIR/accounts/account_a/firefox-profile" "$DATA_DIR/accounts/account_a/state"

output=$(run_multi status account_a)
[[ "$output" != *'not-a-real-password'* ]] || fail 'status 泄露了密码'

run_multi start account_a
assert_file "$DATA_DIR/accounts/account_a/run.pid"
run_multi stop account_a
assert_not_file "$DATA_DIR/accounts/account_a/run.pid"

run_multi install-timers
assert_file "$SYSTEMD_DIR/dafaguo-account_a.service"
assert_file "$SYSTEMD_DIR/dafaguo-account_a.timer"
assert_contains "$SYSTEMD_DIR/dafaguo-account_a.timer" 'OnCalendar=*-*-* 06:30:00'
assert_contains "$SYSTEMD_DIR/dafaguo-account_a.service" 'account_a'

run_multi remove-timers
assert_not_file "$SYSTEMD_DIR/dafaguo-account_a.service"
assert_not_file "$SYSTEMD_DIR/dafaguo-account_a.timer"

if run_multi add '../escape' 07:00 "$SOURCE_ENV" >/dev/null 2>&1; then
  fail '接受了不安全的账号名'
fi
if run_multi add account_b 25:99 "$SOURCE_ENV" >/dev/null 2>&1; then
  fail '接受了无效启动时间'
fi

run_multi delete account_a
assert_not_file "$DATA_DIR/accounts/account_a"

# ---- 批量多账号操作 ----
run_multi add account_a 06:30 "$SOURCE_ENV"
run_multi add account_b 09:00 "$SOURCE_ENV"
run_multi add account_c 10:15 "$SOURCE_ENV"

list_out=$(run_multi list)
[[ "$list_out" == *account_a* && "$list_out" == *account_b* && "$list_out" == *account_c* ]] \
  || fail "list 未列出全部账号：$list_out"

# 批量启动全部
out=$(run_multi start)
[[ "$out" == *account_a* && "$out" == *account_b* && "$out" == *account_c* ]] \
  || fail "start（全部）输出异常：$out"
assert_file "$DATA_DIR/accounts/account_a/run.pid"
assert_file "$DATA_DIR/accounts/account_b/run.pid"
assert_file "$DATA_DIR/accounts/account_c/run.pid"

# 重复启动应提示已在运行
out=$(run_multi start)
[[ "$out" == *'已在运行'* ]] || fail "重复 start 未提示已在运行：$out"

# 批量启动指定子集
out=$(run_multi start account_a account_b)
[[ "$out" != *account_c* ]] || fail "start 子集不应输出 account_c：$out"

# 不存在的账号跳过并报错，其余正常
if out=$(run_multi start account_x 2>&1); then
  fail "start 不存在的账号不应返回 0"
fi
[[ "$out" == *'账号不存在：account_x'* ]] || fail "缺少不存在账号的报错：$out"
assert_file "$DATA_DIR/accounts/account_a/run.pid"

# 批量重启
out=$(run_multi restart)
[[ "$out" == *'已停止账号：account_a'* && "$out" == *'已启动账号：account_a'* ]] \
  || fail "restart 输出异常：$out"
assert_file "$DATA_DIR/accounts/account_a/run.pid"
assert_file "$DATA_DIR/accounts/account_b/run.pid"
assert_file "$DATA_DIR/accounts/account_c/run.pid"

# 批量停止全部
out=$(run_multi stop)
[[ "$out" == *'已停止账号：account_a'* && "$out" == *'已停止账号：account_c'* ]] \
  || fail "stop（全部）输出异常：$out"
assert_not_file "$DATA_DIR/accounts/account_a/run.pid"
assert_not_file "$DATA_DIR/accounts/account_b/run.pid"
assert_not_file "$DATA_DIR/accounts/account_c/run.pid"

# 停止未运行的账号应正常返回
run_multi stop
out=$(run_multi stop account_x 2>&1 || true)
[[ "$out" == *'账号不存在：account_x'* ]] || fail "stop 不存在账号缺少报错：$out"

run_multi delete account_a
run_multi delete account_b
run_multi delete account_c
assert_not_file "$DATA_DIR/accounts/account_a"
assert_not_file "$DATA_DIR/accounts/account_b"
assert_not_file "$DATA_DIR/accounts/account_c"
# 空状态下批量操作应友好提示
out=$(run_multi start)
[[ "$out" == '尚未添加账号' ]] || fail "空状态 start 输出异常：$out"
out=$(run_multi stop)
[[ "$out" == '尚未添加账号' ]] || fail "空状态 stop 输出异常：$out"

# ---- 代理设置 ----
run_multi add account_d 11:00 "$SOURCE_ENV"
# 源 env 无 PROXY → status 显示 (无)
out=$(run_multi status account_d)
[[ "$out" == *'代理 (无)'* ]] || fail "无代理时 status 显示异常：$out"
# 设置代理（输出应脱敏，env 文件存真实值）
out=$(run_multi set-proxy account_d 'socks5://u:p@1.2.3.4:1080')
[[ "$out" == *'代理已设置：socks5://u:****@1.2.3.4:1080'* ]] || fail "set-proxy 输出异常：$out"
[[ "$out" != *'u:p@'* ]] || fail 'set-proxy 输出泄漏了代理密码'
assert_contains "$DATA_DIR/accounts/account_d/account.env" 'PROXY=socks5://u:p@1.2.3.4:1080'
assert_mode "$DATA_DIR/accounts/account_d/account.env" 600
# status 应显示脱敏代理
out=$(run_multi status account_d)
[[ "$out" == *'代理 socks5://u:****@1.2.3.4:1080'* ]] || fail "有代理时 status 显示异常：$out"
[[ "$out" != *'u:p@'* ]] || fail 'status 输出泄漏了代理密码'
# 重复设置应替换而不是追加
run_multi set-proxy account_d 'socks5://a:b@5.6.7.8:9050'
count=$(grep -c '^PROXY=' "$DATA_DIR/accounts/account_d/account.env")
[[ "$count" == "1" ]] || fail "重复 set-proxy 后 PROXY 行数应为 1，实际 $count"
assert_contains "$DATA_DIR/accounts/account_d/account.env" 'PROXY=socks5://a:b@5.6.7.8:9050'
# 清除代理
out=$(run_multi set-proxy account_d)
[[ "$out" == *'代理已清除'* ]] || fail "清除代理输出异常：$out"
if grep -qE '^[[:space:]]*PROXY[[:space:]]*=[^[:space:]]' "$DATA_DIR/accounts/account_d/account.env"; then
  fail "清除代理后 PROXY 仍有值"
fi
# 不存在的账号设置代理应失败
if run_multi set-proxy ghost x >/dev/null 2>&1; then
  fail "对不存在账号设置代理不应成功"
fi
# 凭证其余字段不受影响
assert_contains "$DATA_DIR/accounts/account_d/account.env" 'EMAIL=test@example.com'
assert_contains "$DATA_DIR/accounts/account_d/account.env" 'NH_WAIT=30'
run_multi delete account_d

# ---- vless:// 节点（sing-box 转本地 SOCKS5）----
cat > "$SANDBOX/fake_sing_box" <<'FB'
#!/usr/bin/env bash
sleep 600
FB
chmod 700 "$SANDBOX/fake_sing_box"
export DAFAGUO_SING_BOX_BIN="$SANDBOX/fake_sing_box"

VLESS_URL='vless://bm9uZTpkMDE4MTZlMS1hNWFlLTQ2NWYtODZlOC05NWNjNzA3ODExZDdAc2Fhcy5zaW4uZmFuOjQ0Mw?path=/%3Fed%3D2560%26socks%3D12%26VnbCGymL&remarks=x&obfsParam=stt.de8.de5.net&obfs=websocket&tls=1&peer=stt.de8.de5.net&udp=1'
run_multi add account_v 12:00 "$SOURCE_ENV"
out=$(run_multi set-proxy account_v "$VLESS_URL")
[[ "$out" == *'vless 节点'* && "$out" == *'127.0.0.1'* ]] || fail "set-proxy vless 输出异常：$out"
env_v="$DATA_DIR/accounts/account_v/account.env"
proxy_line=$(grep -E '^PROXY=' "$env_v" | tail -1)
[[ "$proxy_line" =~ ^PROXY=socks5://127\.0\.0\.1:[0-9]+$ ]] || fail "vless 未转换为本地 socks5：$proxy_line"
vport=${proxy_line##*:}
[[ -f "$DATA_DIR/accounts/account_v/vless-source" ]] || fail '缺少 vless-source'
cfg=$(ls "$DATA_DIR/sing-box/vless-"*.json 2>/dev/null | head -1)
[[ -n "$cfg" && -f "$cfg" ]] || fail '缺少 sing-box 配置'
grep -q 'd01816e1-a5ae-465f-86e8-95cc707811d7' "$cfg" || fail '配置缺少 uuid'
grep -q 'saas.sin.fan' "$cfg" || fail '配置缺少服务器'
grep -q 'stt.de8.de5.net' "$cfg" || fail '配置缺少 SNI/Host'
grep -q '/?ed=2560&socks=12&VnbCGymL' "$cfg" || fail '配置 path 未 URL 解码'
grep -q "\"listen_port\": $vport" "$cfg" || fail "配置端口不是 $vport"
# status 显示 vless，且不泄漏 uuid
out=$(run_multi status account_v)
[[ "$out" == *'vless→socks5://127.0.0.1:'* && "$out" != *'d01816e1'* ]] || fail "status vless 显示异常：$out"
# 重复设置同一节点：端口不变（幂等，不重复起进程）
run_multi set-proxy account_v "$VLESS_URL" >/dev/null
port2=$(grep -E '^PROXY=' "$env_v" | tail -1 | grep -o '[0-9]*$')
[[ "$port2" == "$vport" ]] || fail "重复 set-proxy 端口应不变：$vport -> $port2"
n_cfg=$(ls "$DATA_DIR/sing-box/vless-"*.json | wc -l)
[[ "$n_cfg" == "1" ]] || fail "同一节点应只有一份配置，实际 $n_cfg"
# 清除代理
run_multi set-proxy account_v >/dev/null
[[ ! -f "$DATA_DIR/accounts/account_v/vless-source" ]] || fail '清除后 vless-source 应删除'
if grep -qE '^PROXY=.' "$env_v"; then
  fail '清除后 PROXY 仍有值'
fi
run_multi delete account_v
pkill -f "fake_sing_box" 2>/dev/null || true
unset DAFAGUO_SING_BOX_BIN

printf '全部多账号功能测试通过\n'
