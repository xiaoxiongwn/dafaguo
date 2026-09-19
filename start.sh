#!/bin/bash
# 在容器内启动挂机（禁沙箱 + 脱离会话）
# 启动前强制清理所有旧实例，避免多实例并发导致兑换不结算。
cd "$APP_DIR" || exit 1

# ── 1. 杀掉所有旧实例（python 主程序 + xvfb-run 包装进程）──
pkill -9 -f "venv/bin/python.*neoheberg.py" 2>/dev/null
sleep 1
pkill -9 -f "xvfb-run.*neoheberg.py" 2>/dev/null
sleep 1
pkill -9 -f "neoheberg.py" 2>/dev/null
sleep 1
# ── 2. 清理残留 Xvfb（僵尸显示会占用内存且可能抢占 display）──
pkill -9 -f "Xvfb :" 2>/dev/null
pkill -f firefox 2>/dev/null
sleep 1

# ── 3. 验证杀干净了；还有残留就等一会儿再杀一次 ──
_LEFT=$(pgrep -f "neoheberg.py" | wc -l)
if [ "$_LEFT" -gt 0 ]; then
    echo "[warn] 仍有 $_LEFT 个残留进程，二次清理..."
    sleep 2
    pkill -9 -f "neoheberg.py" 2>/dev/null
    pkill -9 -f "Xvfb :" 2>/dev/null
    sleep 1
fi
echo "[info] 清理完成，残留实例数: $(pgrep -f 'neoheberg.py' | wc -l)"

# ── 4. 启动单实例 ──
set -a
. ./env
set +a

export MOZ_DISABLE_CONTENT_SANDBOX=1
export MOZ_DISABLE_GMP_SANDBOX=1
export MOZ_DISABLE_RDD_SANDBOX=1
export MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1
export MOZ_DISABLE_GPU_SANDBOX=1

rm -f neoheberg.log

setsid nohup xvfb-run -a -s "-screen 0 1024x768x24" ./venv/bin/python ./neoheberg.py \
    </dev/null >>neoheberg.log 2>&1 &

echo "launched pid=$!"
sleep 8

echo "[info] 当前实例列表（应只 1 组）:"
ps -eo pid,ppid,cmd | grep "[n]eoheberg.py" || echo NOT_STARTED
