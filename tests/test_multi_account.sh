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

printf '全部多账号功能测试通过\n'
