#!/usr/bin/env bash
# ============================================================
# NeoHeberg AFK 交互式管理脚本
# 1 安装依赖
# 2 配置 Telegram 通知
# 3 查余额（实时刷新）
# 4 每日定时挂机
# 5 运行状态
# 6 卸载
# 8 多账号管理
# 0 退出
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/xxbb678/dafaguo/main/install.sh)
# ============================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/xxbb678/dafaguo/main"
NEOHEBERG_DIR="${NEOHEBERG_DIR:-/root/dafaguo}"
APP_DIR="${NEOHEBERG_DIR:-/root/dafaguo}"
VENV="$APP_DIR/venv"
SCRIPT="$APP_DIR/neoheberg.py"
# 进程匹配模式：兼容「相对路径启动」(start.sh： ./venv/bin/python ./neoheberg.py)
#           与「绝对路径启动」(菜单： $VENV/bin/python $SCRIPT)，避免状态误报为「已安装未运行」
RUN_PATTERN='venv/bin/python.*neoheberg\\.py'
LOG="$APP_DIR/neoheberg.log"
ENV_FILE="$APP_DIR/env"
PID_FILE="$APP_DIR/neoheberg.pid"
SERVICE="neoheberg-afk"
MULTI_SCRIPT="$APP_DIR/multi-account.sh"
MULTI_HOME="${MULTI_HOME:-$HOME/.local/share/dafaguo-multi}"

GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'

info() { echo "${GREEN}[*]${NC} $*"; }
warn() { echo "${YELLOW}[!]${NC} $*"; }
err()  { echo "${RED}[x]${NC} $*"; }
ok()   { echo "${GREEN}[✓]${NC} $*"; }


need_root() {
    [ "$(id -u)" = "0" ] || { err "请用 root 运行（sudo -i 后重试）"; exit 1; }
}

# ---------- 环境适配（老系统） ----------
# 拆出系统代号（bullseye=11 / bookworm=12 / jammy / focal ...）
os_codename() {
    ( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}" )
}

os_id() {
    ( . /etc/os-release 2>/dev/null; echo "${ID:-}" )
}

# 判断某个 apt 源是否真的可用（Release 文件能拉到）
apt_repo_alive() {
    local url="$1"
    curl -fsS --max-time 12 -o /dev/null "${url}/dists/${2}/Release" 2>/dev/null
}

# 失效的 security 源：索引仍可拉取，但包体已 404（指数会优先选中这些不存在的新版，导致整个 install 失败）。
# 常见于 bullseye 等 EOL 发行版：security 池子被清理，但 InRelease 还在。
# 处理：无条件移除 security 源（仅 Debian），让 apt 只从主源取基准版本。
# 主源一般包含同等或旧一点的安全补丁（如 xvfb u13），足够满足依赖。
drop_dead_security_source() {
    [ "$(os_id)" = "debian" ] || return 0
    command -v apt-get >/dev/null 2>&1 || return 0

    local codename
    codename=$(os_codename)
    # 仅处理已 EOL 的老发行版；bookworm 之后 security 源仍正常，动了反而有安全风险
    case "$codename" in
        bullseye|buster|stretch|jessie) ;;
        *) return 0 ;;
    esac

    # 已处理过就不重复（用 marker 文件记录）
    [ -f /etc/apt/apt.conf.d/99neoheberg-dead-security-dropped ] && return 0

    local changed=0
    if [ -f /etc/apt/sources.list ] && grep -qE 'security\.debian\.org|debian-security' /etc/apt/sources.list 2>/dev/null; then
        cp -n /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)" 2>/dev/null || true
        sed -i '/security\.debian\.org/d; /debian-security/d' /etc/apt/sources.list
        changed=1
    fi

    if [ -d /etc/apt/sources.list.d ]; then
        local _f
        for _f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$_f" ] || continue
            if grep -qE 'security\.debian\.org|debian-security' "$_f" 2>/dev/null; then
                sed -i '/security\.debian\.org/d; /debian-security/d' "$_f" 2>/dev/null || true
                grep -qE '^[[:space:]]*deb' "$_f" 2>/dev/null || rm -f "$_f"
                changed=1
            fi
        done
    fi

    if [ "$changed" = "1" ]; then
        warn "已移除失效的 ${codename}-security 源（EOL 后包体已 404，保留只会导致安装失败）"
        rm -rf /var/lib/apt/lists/* 2>/dev/null || true
    fi
    : > /etc/apt/apt.conf.d/99neoheberg-dead-security-dropped 2>/dev/null || true
    return 0
}

# 老系统（已 EOL）自动改用 archive.debian.org 归档源
# 仅处理 Debian 官方源行，不碰第三方源；且仅在原源已失效时改写
fix_legacy_apt_sources() {
    [ "$(os_id)" = "debian" ] || return 0
    command -v apt-get >/dev/null 2>&1 || return 0

    local codename
    codename=$(os_codename)
    [ -z "$codename" ] && return 0

    # 关掉 Valid-Until 校验（归档源签名时间很旧）——这一步无条件做，不依赖探测
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99neoheberg-no-valid-until

    # 先试一次 apt update：成功则不动源，失败（EOL/过期/404）则无条件切归档站
    if apt-get update -qq >/dev/null 2>&1; then
        return 0
    fi

    warn "检测到 Debian $codename 官方源不可用，自动切换到 archive.debian.org"
    [ -f /etc/apt/sources.list ] && cp -n /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)" 2>/dev/null || true

    # 将 sources.list 中的官方域名替换为归档站，并关掉过期校验
    if [ -f /etc/apt/sources.list ]; then
        # 1) 将主源域名换为归档站（兼容 /debian 与无后缀两种写法）
        sed -i \
            -e "s|https\?://deb\.debian\.org|http://archive.debian.org|g" \
            /etc/apt/sources.list
        # 2) security 行直接删除：无论域名如何写，归档站都不再提供可用的 security Release
        sed -i "/security\.debian\.org/d; /debian-security/d" /etc/apt/sources.list
        # 3) 删除 backports 行
        sed -i "/backports/d" /etc/apt/sources.list
    fi

    # 子目录里的旧源（backports、security 等）一并处理：已不存在于归档站，保留只会让 apt update 报错
    if [ -d /etc/apt/sources.list.d ]; then
        local _f
        for _f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
            [ -f "$_f" ] || continue
            # 将子文件里的官方域名也改为归档站，并删除 backports/security 行
            sed -i -e "s|https\?://deb\.debian\.org|http://archive.debian.org|g" -e "/security\.debian\.org/d" -e "/backports/d" -e "/debian-security/d" "$_f" 2>/dev/null || true
            # 内容空了就删掉整个文件
            if ! grep -qE "^[[:space:]]*deb" "$_f" 2>/dev/null; then
                rm -f "$_f"
            fi
        done
    fi
    return 0
}

# 系统依赖（含老系统兼容）
# libgtk 是否可用：同时看 ldconfig 与文件系统（部分系统 ldconfig 缓存未刷新）
have_libgtk() {
    # 注意：本函数在 set -euo pipefail 环境下调用，所有判断必须显式 return，
    # 否则管道或 grep 的非零状态会被上层当作函数返回值。
    # 不用管道：ldconfig -p | grep -q 在 set -o pipefail 下会因 SIGPIPE 返回 141，
    # 而 set -e 会直接终止脚本。改为先取出输出再字符串匹配。
    if ldconfig -p 2>/dev/null | grep "libgtk-3\.so\.0" >/dev/null 2>&1; then
        return 0
    fi
    if ls /usr/lib/*/libgtk-3.so.0 /usr/lib/libgtk-3.so.0 /lib/*/libgtk-3.so.0 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# bullseye 已 EOL：security 池子被清理后，会出现一种伪健康状态：
#   - apt-get update 成功（索引还在）
#   - 但 apt-get install 下载包体时 404，或因版本断层报 held broken packages
# 典型例子：python3.9 已装 3.9.2-1+deb11u7（来自已失效的 security 源），
# 而 deb.debian.org 上的 python3.9-venv 只有 3.9.2-1，它要求 python3.9 (= 3.9.2-1)
# → 版本对不上 → venv 永远装不上。
# 处理：检测到这种 mismatch 时，把带 +debXXuY 后缀的包降级到基准版本，使依赖重新对齐。
fix_eol_version_mismatch() {
    command -v apt-get >/dev/null 2>&1 || return 0
    command -v dpkg >/dev/null 2>&1 || return 0

    # 只针对 Debian bullseye（其他版本不做，避免误伤）
    local codename
    codename=$(os_codename)
    [ "$codename" = "bullseye" ] || return 0

    # 检测：python3.9-venv 是否因版本不匹配而装不上
    local want have
    have=$(dpkg-query -W -f='${Version}' python3.9 2>/dev/null || echo "")
    case "$have" in
        *"+deb11u"*) ;;
        *) return 0 ;;   # 已是基准版本或未安装，无需处理
    esac

    # 已有 venv 就不动
    dpkg-query -W python3.9-venv >/dev/null 2>&1 && return 0

    # 目标基准版本：去掉 +debXXuY 后缀
    local base="${have%%+*}"
    [ -n "$base" ] || return 0

    warn "检测到 bullseye security 源失效导致的版本断层（python3.9=${have}）"
    info "将 python3.9 降级到 ${base} 以恢复依赖对齐..."

    apt-get install -y --allow-downgrades -qq \
        "python3.9=${base}" "python3.9-minimal=${base}" \
        "libpython3.9-stdlib=${base}" "libpython3.9-minimal=${base}" \
        >/dev/null 2>&1 || true

    if dpkg-query -W python3.9-venv >/dev/null 2>&1; then
        ok "版本对齐完成，python3.9-venv 已可安装"
    fi
    return 0
}

do_install_system_pkgs() {
    command -v apt-get >/dev/null 2>&1 || { err "未检测到 apt-get，仅支持 Debian/Ubuntu"; return 1; }

    export DEBIAN_FRONTEND=noninteractive
    fix_legacy_apt_sources

    # EOL security 源清理后常见：索引可用但包体 404 / 版本断层
    # 先把失效的 security 源摘掉，避免 apt 优选到已不存在的新版包
    drop_dead_security_source
    fix_eol_version_mismatch

    # 归档源域名在老系统上可能走 IPv6，确保 apt 不因网络报错而卡死
    apt-get update -qq 2>/tmp/neoheberg-apt-update.log || true
    if [ -s /tmp/neoheberg-apt-update.log ]; then
        warn "apt update 有警告（可能是无效源），详见 /tmp/neoheberg-apt-update.log"
    fi

    info "安装基础软件包..."
    apt-get install -y -qq python3 python3-pip curl ca-certificates xauth >/dev/null 2>&1 || true

    # venv 与 distutils（老 Python 3.9 必需）
    # 若因版本断层装不上，重试一次并显式告警（而非静默 || true）
    if ! apt-get install -y -qq python3-venv python3-distutils python3-setuptools >/dev/null 2>&1; then
        warn "python3-venv/distutils 安装失败，尝试修复依赖..."
        fix_eol_version_mismatch
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq python3-venv python3-distutils python3-setuptools >/dev/null 2>&1 || true
    fi

    # Debian 11 常见冲突：python3-setuptools 要求 pkg-resources=52.0.0-4，而系统已装 52.0.0-4+deb11u2。
    # 用 --allow-downgrades 将两者同步到归档版，否则安装器一直报 held broken packages。
    if ! python3 -c 'import distutils.cmd' >/dev/null 2>&1 || ! python3 -c 'import setuptools' >/dev/null 2>&1; then
        apt-get install -y --allow-downgrades -qq \            python3-distutils=3.9.2-1 python3-lib2to3=3.9.2-1 \            python3-pkg-resources=52.0.0-4 python3-setuptools=52.0.0-4 \            >/dev/null 2>&1 || true
    fi

    # xvfb（某些源里包名不同）
    if ! command -v xvfb-run >/dev/null 2>&1; then
        apt-get install -y -qq xvfb >/dev/null 2>&1 || true
    fi

    # Firefox 运行时所需的 GUI 库（老系统默认不安装，导致 libgtk-3.so.0 缺失）
    if ! have_libgtk; then
        info "补齐 Firefox 所需 GUI 库..."
        install_gui_libs
    fi

    # 校验关键依赖：缺失则重试一次，仍缺则报错并给出排查提示
    if ! command -v xvfb-run >/dev/null 2>&1; then
        warn "xvfb-run 缺失，重试安装..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y -qq xvfb >/dev/null 2>&1 || true
    fi
    if ! have_libgtk; then
        warn "libgtk-3 缺失，重试安装..."
        do_install_firefox_libs >/dev/null 2>&1 || true
    fi

    command -v xvfb-run >/dev/null 2>&1 || { err "xvfb-run 安装失败（apt 源可能仍不可用）"; err "请检查: cat /etc/apt/sources.list ; apt-get update"; return 1; }
    have_libgtk || { err "libgtk-3 安装失败，Firefox 无法启动"; err "请检查 apt 源是否可用"; return 1; }
    return 0
}

# 创建虚拟环境：优先用 venv，老系统 ensurepip 缺失时用 get-pip.py 引导
ensure_venv() {
    mkdir -p "$APP_DIR"; chmod 700 "$APP_DIR"
    [ -x "$VENV/bin/python" ] && return 0

    rm -rf "$VENV"
    info "创建 Python 虚拟环境..."
    if python3 -m venv "$VENV" >/dev/null 2>&1 && [ -x "$VENV/bin/pip" ]; then
        ok "虚拟环境就绪"
        return 0
    fi

    # 老系统（如 Debian 11 + Python 3.9）：ensurepip 缺失，venv --without-pip + get-pip.py
    warn "常规 venv 创建失败（可能 ensurepip 缺失），改用 get-pip.py 引导..."

    # get-pip.py 自身依赖 distutils.cmd，先确保它在
    if ! python3 -c 'import distutils.cmd' >/dev/null 2>&1; then
        apt-get install -y --allow-downgrades -qq python3-distutils=3.9.2-1 python3-lib2to3=3.9.2-1 >/dev/null 2>&1 || true
    fi
    rm -rf "$VENV"
    python3 -m venv "$VENV" --without-pip >/dev/null 2>&1 || true

    local pyver gp
    pyver=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "3.9")
    gp="/tmp/neoheberg-get-pip.py"
    case "$pyver" in
        3.6|3.7|3.8|3.9) curl -fsSL "https://bootstrap.pypa.io/pip/${pyver}/get-pip.py" -o "$gp" ;;
        *)               curl -fsSL "https://bootstrap.pypa.io/get-pip.py" -o "$gp" ;;
    esac || { err "get-pip.py 下载失败"; return 1; }

    if [ -x "$VENV/bin/python" ]; then
        "$VENV/bin/python" "$gp" --no-warn-script-location >/dev/null 2>&1 || { err "pip 安装失败"; return 1; }
    else
        python3 "$gp" --no-warn-script-location >/dev/null 2>&1 || { err "pip 安装失败"; return 1; }
        # 全局 pip 安好后再试 venv（无 pip 模式 + 复制）
        rm -rf "$VENV"
        python3 -m venv "$VENV" >/dev/null 2>&1 || python3 -m venv "$VENV" --without-pip >/dev/null 2>&1 || true
    fi

    rm -f "$gp"
    [ -x "$VENV/bin/python" ] || { err "虚拟环境创建失败"; return 1; }
    ok "虚拟环境就绪（兼容模式）"
    return 0
}

# 在虚拟环境里安装 Python 依赖
do_install_py_deps() {
    local pip="$VENV/bin/pip"
    if [ ! -x "$pip" ]; then
        # venv 内无 pip：用 python -m pip 或重新引导
        if "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
            pip="$VENV/bin/python -m pip"
        else
            local gp="/tmp/neoheberg-get-pip.py"
            local pyver
            pyver=$("$VENV/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "3.9")
            case "$pyver" in
                3.6|3.7|3.8|3.9) curl -fsSL "https://bootstrap.pypa.io/pip/${pyver}/get-pip.py" -o "$gp" ;;
                *)               curl -fsSL "https://bootstrap.pypa.io/get-pip.py" -o "$gp" ;;
            esac || { err "get-pip.py 下载失败"; return 1; }
            "$VENV/bin/python" "$gp" --no-warn-script-location >/dev/null 2>&1 || { err "venv 内 pip 安装失败"; return 1; }
            rm -f "$gp"
            pip="$VENV/bin/pip"
        fi
    fi

    info "升级 pip 并安装 ruyipage（首次较慢）..."
    $pip install --quiet --upgrade pip >/dev/null 2>&1 || true
    $pip install --quiet ruyipage || { err "Python 依赖安装失败"; return 1; }

    # 提前验证导入，避免后续运行才报错
    "$VENV/bin/python" -c 'import ruyipage' 2>/dev/null || { err "依赖导入失败，请看上方 pip 输出"; return 1; }
    ok "Python 依赖就绪"
    return 0
}

# 主脚本语法适配：Python < 3.10 不支持 X | Y 类型注解，自动降级为 object
# 用 venv 的 Python 判版本（而非系统 python3），避免系统/虚拟环境版本不一致时误判
adapt_script_for_old_python() {
    [ -f "$SCRIPT" ] || return 0

    local pybin pyver
    if [ -x "$VENV/bin/python" ]; then
        pybin="$VENV/bin/python"
    else
        pybin="python3"
    fi
    pyver=$("$pybin" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "3.9")

    case "$pyver" in
        3.9|3.8|3.7|3.6)
            # 通用化：匹配任意 "X | Y" 返回注解（str | None、int | None、list[str] | None 等），
            # 统一降级为 object。原来只匹配字面量 'str | None'，脚本一改注解就会漏掉。
            if grep -qE -- '->[[:space:]]*[A-Za-z_][A-Za-z0-9_.\[\], ]*[[:space:]]*\|[[:space:]]*[A-Za-z_]' "$SCRIPT" 2>/dev/null; then
                sed -i -E 's/->[[:space:]]*([A-Za-z_][A-Za-z0-9_.\[\], ]*)[[:space:]]*\|[[:space:]]*([A-Za-z_][A-Za-z0-9_.\[\], ]*)/-> object/g' "$SCRIPT"
                info "已适配 Python ${pyver}（X | Y 注解 → object）"
            fi
            ;;
    esac
    return 0
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a; . "$ENV_FILE" 2>/dev/null || true; set +a
    fi
    return 0
}

write_env_file() {
    mkdir -p "$APP_DIR"
    : > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    [ -n "${EMAIL:-}" ]        && echo "EMAIL='${EMAIL}'"               >> "$ENV_FILE"
    [ -n "${PASSWORD:-}" ]     && echo "PASSWORD='${PASSWORD}'"         >> "$ENV_FILE"
    [ -n "${TG_BOT_TOKEN:-}" ] && echo "TG_BOT_TOKEN='${TG_BOT_TOKEN}'" >> "$ENV_FILE"
    [ -n "${TG_CHAT_ID:-}" ]   && echo "TG_CHAT_ID='${TG_CHAT_ID}'"     >> "$ENV_FILE"
    [ -n "${NOTIFY_NAME:-}" ]  && echo "NOTIFY_NAME='${NOTIFY_NAME}'"   >> "$ENV_FILE"
    [ -n "${PROXY:-}" ]        && echo "PROXY='${PROXY}'"               >> "$ENV_FILE"
    [ -n "${NH_WAIT:-}" ]      && echo "NH_WAIT='${NH_WAIT}'"           >> "$ENV_FILE"
    return 0
}

# ---------------- 1. 安装与添加账号密码 ----------------
menu_install() {
    echo ""
    echo "${CYAN}=== 安装依赖与环境 ===${NC}"

    if [ -x "$VENV/bin/python" ] && [ -f "$SCRIPT" ]; then
        ok "依赖与主脚本已存在"
        printf "是否重新检查/补齐？[y/N]: "
        local ans
        read -r ans || ans=""
        case "$ans" in
            y|Y|yes|YES) ;;
            *) return 0 ;;
        esac
    fi

    do_install_deps || return 1
    ok "安装完成"
    echo "    下一步：选菜单 [8] 多账号管理 或直接运行 multi-account.sh add"
}

# ---------- 账号密码 ----------
menu_account() {
    echo ""
    echo "${CYAN}=== 账号密码 ===${NC}"
    load_env

    local def_email="${EMAIL:-}" in_email in_pass
    printf "NeoHeberg 登录邮箱"
    [ -n "$def_email" ] && printf " [当前: %s]" "$def_email"
    printf ": "
    read -r in_email || in_email=""
    [ -z "$in_email" ] && in_email="$def_email"

    if [ -n "${PASSWORD:-}" ]; then
        printf "登录密码 [直接回车沿用已保存的]: "
    else
        printf "登录密码: "
    fi
    read -r in_pass || in_pass=""
    [ -z "$in_pass" ] && in_pass="${PASSWORD:-}"

    if [ -z "$in_email" ] || [ -z "$in_pass" ]; then
        err "邮箱与密码不能为空"
        return 1
    fi
    EMAIL="$in_email"; PASSWORD="$in_pass"
    write_env_file
    ok "账号密码已保存到 $ENV_FILE"

    if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
        printf "账号修改需重启才生效，是否立即重启？[y/N]: "
        local rr
        read -r rr || rr=""
        case "$rr" in
            y|Y|yes|YES) stop_bot; start_bot ;;
            *) info "请选菜单 [6] 重启使其生效" ;;
        esac
    fi
    return 0
}

do_install_deps() {
    do_install_system_pkgs || return 1
    ensure_venv || return 1
    do_install_py_deps || return 1

    if ! ls -d /root/.cache/ruyipage/browsers/firefox-* >/dev/null 2>&1; then
        info "下载 Firefox 运行时（约百兆，首次较慢）..."
        "$VENV/bin/python" -m ruyipage install || { err "Firefox 运行时下载失败"; return 1; }
    else
        ok "Firefox 运行时已存在"
    fi

    info "下载主脚本..."
    if [ -f "$APP_DIR/neoheberg.py.local" ]; then
        cp "$APP_DIR/neoheberg.py.local" "$SCRIPT"
    else
        curl -fsSL "$REPO_RAW/neoheberg.py" -o "$SCRIPT" || { err "脚本下载失败"; return 1; }
    fi

    # 多账号管理脚本（菜单 [9] 使用；缺失不影响单账号功能）
    if ! curl -fsSL "$REPO_RAW/multi-account.sh" -o "$MULTI_SCRIPT" 2>/dev/null; then
        warn "multi-account.sh 下载失败，多账号菜单暂不可用"
    else
        chmod +x "$MULTI_SCRIPT"
    fi

    # 下载后必须先适配老 Python 注解，否则语法检查/启动会直接报错
    adapt_script_for_old_python || true

    # 提前做一次语法自检：老 Python 注解、缩进等问题在这里暴露，而不是启动时才炸
    if ! "$VENV/bin/python" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$SCRIPT" >/dev/null 2>&1; then
        err "主脚本语法自检失败（Python $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)）：$SCRIPT"
        err "查看详情: $VENV/bin/python -c 'import ast;ast.parse(open(\"$SCRIPT\").read())'"
        return 1
    fi
    ok "主脚本语法自检通过"

    # 实测 Firefox 能否启动，提前暴露缺库问题
    if ! xvfb-run -a "$VENV/bin/python" -c '
import subprocess, sys, time, os, glob
ff = glob.glob("/root/.cache/ruyipage/browsers/firefox-*/firefox/firefox")
if not ff:
    sys.exit(1)
subprocess.run([ff[0], "--headless", "--version"], capture_output=True, timeout=60)
' >/dev/null 2>&1; then
        warn "Firefox 启动自检未通过（可能缺 GUI 库），将尝试补齐..."
        do_install_firefox_libs >/dev/null 2>&1 || true
    fi

    # 安装后自检：验证 Firefox 在 xvfb 下能启动并开放调试端口（提前暴露沙箱/缺库问题）
    info "运行安装自检..."
    if xvfb-run -a "$VENV/bin/python" - <<'PYEOF' >/dev/null 2>&1
import glob, subprocess, sys, time, socket
ff = glob.glob("/root/.cache/ruyipage/browsers/firefox-*/firefox/firefox")
if not ff:
    sys.exit(1)
port = 28901
env = dict(__import__("os").environ)
for k in ("MOZ_DISABLE_CONTENT_SANDBOX","MOZ_DISABLE_GMP_SANDBOX","MOZ_DISABLE_RDD_SANDBOX","MOZ_DISABLE_SOCKET_PROCESS_SANDBOX","MOZ_DISABLE_GPU_SANDBOX"):
    env[k] = "1"
p = subprocess.Popen([ff[0], f"--remote-debugging-port={port}", "--no-remote", "--marionette", "--profile", "/tmp/nh_selfcheck"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
ok = False
for _ in range(60):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=1)
        s.close(); ok = True; break
    except Exception:
        time.sleep(1)
p.terminate()
try: p.wait(timeout=10)
except Exception: p.kill()
sys.exit(0 if ok else 1)
PYEOF
    then
        ok "自检通过：Firefox 可正常启动"
    else
        warn "自检未通过（Firefox 可能无法启动），将尝试补齐 GUI 库后重试"
        do_install_firefox_libs >/dev/null 2>&1 || true
    fi

    ok "安装完成"
    return 0
}

# 补齐 Firefox GUI 库（独立函数，供自检失败时调用）
do_install_firefox_libs() {
    install_gui_libs
}

# 逐包安装 GUI 库：避免因单个包名不存在导致整条 apt install 失败（Debian 13 的 t64 改名）
install_gui_libs() {
    command -v apt-get >/dev/null 2>&1 || return 0
    export DEBIAN_FRONTEND=noninteractive

    local pkg alt
    for pkg in \
        libgtk-3-0 libdbus-glib-1-2 libasound2 libxt6 libx11-xcb1 \
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 \
        libpango-1.0-0 libcairo2 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
        libxkbcommon0 libxshmfence1 libdrm2 libxcb1 libnspr4 libnss3
    do
        apt-get install -y -qq "$pkg" >/dev/null 2>&1 && continue
        # 失败则尝试 Debian 13 的 t64 名称
        alt="${pkg}t64"
        apt-get install -y -qq "$alt" >/dev/null 2>&1 || true
    done
    return 0
}

# ---------------- 启停 ----------------
start_bot() {
    if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
        warn "已在运行中，无需重复启动"
        return 0
    fi
    load_env
    if [ -z "${EMAIL:-}" ] || [ -z "${PASSWORD:-}" ]; then
        err "未配置账号密码，请先选菜单 [1]"
        return 1
    fi
    if [ ! -x "$VENV/bin/python" ] || [ ! -f "$SCRIPT" ]; then
        err "尚未安装，请先选菜单 [1]"
        return 1
    fi
    cd "$APP_DIR"
    # LXC/容器内 Firefox 沙箱会导致调试端口不开，必须禁用
    export _NH_SANDBOX_OFF=1
    # setsid 脱离会话：SSH 断开也不会把挂机进程带走
    if command -v setsid >/dev/null 2>&1; then
        setsid xvfb-run -a -s "-screen 0 1024x768x24" env \
            MOZ_DISABLE_CONTENT_SANDBOX=1 \
            MOZ_DISABLE_GMP_SANDBOX=1 \
            MOZ_DISABLE_RDD_SANDBOX=1 \
            MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 \
            MOZ_DISABLE_GPU_SANDBOX=1 \
            "$VENV/bin/python" "$SCRIPT" >> "$LOG" 2>&1 < /dev/null &
    else
        nohup env MOZ_DISABLE_CONTENT_SANDBOX=1 MOZ_DISABLE_GMP_SANDBOX=1 MOZ_DISABLE_RDD_SANDBOX=1 MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 MOZ_DISABLE_GPU_SANDBOX=1 xvfb-run -a "$VENV/bin/python" "$SCRIPT" >> "$LOG" 2>&1 &
    fi
    echo $! > "$PID_FILE"
    sleep 3
    if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
        ok "已后台启动（PID $(cat "$PID_FILE" 2>/dev/null)）"
    else
        err "启动失败，请看日志: tail -20 $LOG"
    fi
}

stop_bot() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    pkill -f "$RUN_PATTERN" 2>/dev/null || true
    pkill -f "xvfb-run.*neoheberg\.py" 2>/dev/null || true
    ok "已停止"
}

# ---------------- 2. 配置 Telegram 通知 ----------------
menu_tg() {
    echo ""
    echo "${CYAN}=== 配置 Telegram 通知 ===${NC}"
    load_env

    printf "Bot Token"
    if [ -n "${TG_BOT_TOKEN:-}" ]; then
        printf " [当前: %s...%s]" "$(echo "$TG_BOT_TOKEN" | cut -c1-10)" "$(echo "$TG_BOT_TOKEN" | rev | cut -c1-4 | rev)"
    fi
    printf ": "
    local in_token in_chat
    read -r in_token || in_token=""
    [ -z "$in_token" ] && in_token="${TG_BOT_TOKEN:-}"

    printf "Chat ID"
    [ -n "${TG_CHAT_ID:-}" ] && printf " [当前: %s]" "$TG_CHAT_ID"
    printf ": "
    read -r in_chat || in_chat=""
    [ -z "$in_chat" ] && in_chat="${TG_CHAT_ID:-}"

    printf "节点名称（多台机器区分用，可留空）"
    [ -n "${NOTIFY_NAME:-}" ] && printf " [当前: %s]" "$NOTIFY_NAME"
    printf ": "
    local in_name
    read -r in_name || in_name=""
    [ -z "$in_name" ] && in_name="${NOTIFY_NAME:-}"

    TG_BOT_TOKEN="$in_token"; TG_CHAT_ID="$in_chat"; NOTIFY_NAME="$in_name"
    write_env_file

    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local _test_text="✅ NeoHeberg 通知已配置成功"
        [ -n "$NOTIFY_NAME" ] && _test_text="🖥️ ${NOTIFY_NAME}
${_test_text}"
        info "正在发送测试消息..."
        if curl -fsS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${_test_text}" >/dev/null 2>&1; then
            ok "测试消息已发送，请查看 Telegram"
        else
            err "发送失败，请检查 Token 与 Chat ID"
        fi
    else
        warn "未填写完整，已清空 TG 配置"
    fi

    if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
        printf "通知修改需重启才生效，是否立即重启？[y/N]: "
        local rr
        read -r rr || rr=""
        case "$rr" in
            y|Y|yes|YES) stop_bot; start_bot ;;
            *) info "请手动重启使其生效" ;;
        esac
    fi
}

# ---------------- 3. 查看运行状态 ----------------
menu_status() {
    echo ""
    echo "${CYAN}=== 运行状态 ===${NC}"

    if [ ! -d "$APP_DIR" ]; then
        warn "未安装（$APP_DIR 不存在）"
        return 0
    fi

    load_env
    if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
        ok "进程：运行中 (PID: $(pgrep -f "$RUN_PATTERN" | tr '\n' ' '))"
    else
        warn "进程：未运行"
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
        echo "    systemd: $(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown) / $(systemctl is-enabled "$SERVICE" 2>/dev/null || echo unknown)"
    fi

    if schedule_installed; then
        local _next
        _next=$(systemctl list-timers "${SCHED_SERVICE}.timer" --no-pager 2>/dev/null | awk 'NR==2{print $1, $2, $3}')
        echo "    定时:   每日自动挂机已启用 (下次: ${_next:-?})"
    else
        echo "    定时:   未设置"
    fi

    echo "    账号：${EMAIL:-<未配置>}"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        echo "    TG 通知：已配置 (chat ${TG_CHAT_ID})"
        echo "    节点名：${NOTIFY_NAME:-<未设置，通知里不带标识>}"
    else
        echo "    TG 通知：未配置"
    fi

    if [ -f "$LOG" ]; then
        local rounds bal bj
        rounds=$(grep -c '轮完成' "$LOG" 2>/dev/null || echo 0)
        bal=$(grep -E 'TG 报告: 余额=' "$LOG" 2>/dev/null | tail -1 | sed 's/.*余额=//' | awk '{print $1}' || echo "-")
        [ -z "$bal" ] && bal="-"
        echo "────────────────────────────"
        echo "    今日轮次：$rounds"
        echo "    最新余额：$bal"
        echo "    最近日志（北京时间）："
        tail -n 6 "$LOG" | sed 's/^/      /'
    fi

    echo ""
    echo "${CYAN}--- 操作 ---${NC}"
    echo "  [s] 启动 / [k] 停止 / [r] 重启 / [l] 实时日志 / 回车返回"
    local op
    read -r op || op=""
    case "$op" in
        s|S) start_bot ;;
        k|K) stop_bot ;;
        r|R) stop_bot; start_bot ;;
        l|L) tail -f "$LOG" ;;
        *) : ;;
    esac
}

# ---------- 4. 查余额（实时刷新） ----------
# 直接调用主脚本的余额接口（导入函数），避免重复实现登录与 CSRF 逻辑
menu_balance() {
    echo ""
    echo "${CYAN}=== 余额查询（实时） ===${NC}"

    if [ ! -f "$SCRIPT" ] || [ ! -x "$VENV/bin/python" ]; then
        err "尚未安装，请先选菜单 [1]"
        return 1
    fi
    if [ ! -f "$ENV_FILE" ]; then
        err "未配置账号密码，请先进入多账号管理添加账号"
        return 1
    fi

    load_env
    export EMAIL PASSWORD TG_BOT_TOKEN TG_CHAT_ID NOTIFY_NAME PROXY NH_WAIT

    info "正在查询，首次可能需要几秒（若 Cookie 失效会自动拉起浏览器登录）..."
    echo "    按 Ctrl+C 退出"
    echo ""

    cd "$APP_DIR"
    _BALPY="$APP_DIR/.balance_check.py"
    cat > "$_BALPY" <<'PYEOF'
import os, sys, time, glob

# 直接执行主脚本源码，但先设 __name__ 非 __main__，避开 main() 与 sys.exit
_script = os.environ.get("NH_SCRIPT", "neoheberg.py")
with open(_script, encoding="utf-8") as _f:
    _code = compile(_f.read(), _script, "exec")
_ns = {"__name__": "nh_module", "__file__": _script}
exec(_code, _ns)

class _NH:
    pass
nh = _NH()
for _k, _v in _ns.items():
    if not _k.startswith("__"):
        setattr(nh, _k, _v)

def fmt(v):
    return f"{v:.6f}" if isinstance(v, (int, float)) else str(v)


def _merge_save(state, updates):
    """只合并本进程负责的字段：先重读磁盘再写回，避免用旧快照把主脚本的 rounds 覆盖掉。"""
    try:
        disk = nh.load_state()
    except Exception:
        disk = dict(state)
    disk.update(updates)
    nh.save_state(disk)
    state.update(updates)


state = nh.load_state()
page = None
last = None
start = None

try:
    opts = nh.FirefoxOptions()
    _ff = sorted(glob.glob("/root/.cache/ruyipage/browsers/firefox-*/firefox/firefox"))
    if _ff:
        opts.set_browser_path(_ff[-1])
    if nh.PROFILE_DIR:
        opts.set_profile(nh.PROFILE_DIR)
    if nh.PROXY_URL:
        opts.set_proxy(nh.PROXY_URL)
    opts.headless(False)
    page = nh.FirefoxPage(opts)

    page.get(nh.ADS_URL)
    time.sleep(5)
    nh.wait_for_cloudflare(page, timeout=60)
    nh.ensure_logged_in(page)

    bal = nh.get_balance_dom(page, wait=25)
    seen = nh.get_seen_today(page)
    if bal <= 0:
        raise RuntimeError("未能读取余额")
    start = bal
    last = bal
    _merge_save(state, {"last_balance": bal})
    print(f"初始余额: {fmt(bal)} 🪙    今日已看 {seen}/100", flush=True)
    print("─" * 36, flush=True)
except Exception as e:
    print(f"❌ 查询失败: {type(e).__name__}: {e}", flush=True)
    if page:
        try: page.quit()
        except Exception: pass
    sys.exit(1)

try:
    while True:
        time.sleep(5)
        ts = time.strftime("%H:%M:%S")
        try:
            page.get(nh.ADS_URL)
            time.sleep(3)
            bal = nh.get_balance_dom(page, wait=15)
            seen = nh.get_seen_today(page)
            delta = bal - last if last is not None else 0.0
            total = bal - start if start is not None else 0.0
            arrow = "↑" if delta > 0 else ("↓" if delta < 0 else "─")
            print(f"[{ts}] 余额 {fmt(bal)} 🪙  ({arrow}{fmt(abs(delta))})  本次累计 +{fmt(total)}  已看 {seen}/100", flush=True)
            last = bal
            _merge_save(state, {"last_balance": bal})
        except Exception as e:
            print(f"[{ts}] 读取失败: {type(e).__name__}", flush=True)
except KeyboardInterrupt:
    pass
finally:
    if page:
        try: page.quit()
        except Exception: pass
PYEOF

    xvfb-run -a -s "-screen 0 1024x768x24" env \
        MOZ_DISABLE_CONTENT_SANDBOX=1 \
        MOZ_DISABLE_GMP_SANDBOX=1 \
        MOZ_DISABLE_RDD_SANDBOX=1 \
        MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 \
        MOZ_DISABLE_GPU_SANDBOX=1 \
        NH_SCRIPT="$SCRIPT" \
        "$VENV/bin/python" "$_BALPY"
    rm -f "$_BALPY"
    return 0
}

# ---------------- 每日 09:00 自动挂机（systemd timer） ----------------
# 设计：每天 09:00 拉起挂机，刷满额度后脚本自行退出；次日 09:00 再次拉起。
SCHED_SERVICE="neoheberg-afk-daily"

schedule_installed() {
    [ -f "/etc/systemd/system/${SCHED_SERVICE}.service" ] && [ -f "/etc/systemd/system/${SCHED_SERVICE}.timer" ]
}

schedule_install() {
    command -v systemctl >/dev/null 2>&1 || { err "未检测到 systemd，无法设置定时"; return 1; }

    if [ ! -x "$VENV/bin/python" ] || [ ! -f "$SCRIPT" ]; then
        err "尚未安装，请先选菜单 [1]"
        return 1
    fi
    if [ ! -f "$ENV_FILE" ]; then
        err "未配置账号密码，请先选菜单 [1]"
        return 1
    fi

    local hour minute tm
    printf "每日几点开始挂机 [默认 09:00]: "
    read -r tm || tm=""
    hour="09"; minute="00"
    case "$tm" in
        "") : ;;
        *:*)
            hour=$(echo "$tm" | cut -d: -f1 | sed 's/^0*//')
            minute=$(echo "$tm" | cut -d: -f2 | cut -c1-2 | sed 's/^0*//')
            [ -z "$hour" ] && hour=0
            [ -z "$minute" ] && minute=0
            [ "$hour" -ge 0 ] 2>/dev/null && [ "$hour" -le 23 ] 2>/dev/null || { err "小时应为 0-23"; return 1; }
            [ "$minute" -ge 0 ] 2>/dev/null && [ "$minute" -le 59 ] 2>/dev/null || { err "分钟应为 0-59"; return 1; }
            ;;
        *) err "格式应为 HH:MM，例 09:00"; return 1 ;;
    esac
    # 强制十进制：bash 中 09 会被当作无效八进制数，导致 default 变 00
    hour=$((10#$hour))
    minute=$((10#$minute))
    printf -v hour "%02d" "$hour"
    printf -v minute "%02d" "$minute"

    # 生成 start.sh（启动前强制清理旧实例，防止多实例并发导致兑换不结算）
    cat > "$APP_DIR/start.sh" <<'SHEOF'
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
SHEOF
    chmod +x "$APP_DIR/start.sh"

    cat > "/etc/systemd/system/${SCHED_SERVICE}.service" <<EOF
[Unit]
Description=NeoHeberg AFK daily run
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
Environment=MOZ_DISABLE_CONTENT_SANDBOX=1
Environment=MOZ_DISABLE_GMP_SANDBOX=1
Environment=MOZ_DISABLE_RDD_SANDBOX=1
Environment=MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1
Environment=MOZ_DISABLE_GPU_SANDBOX=1
# KillMode=none：脚本用 setsid 脱离后台运行，不能让 systemd 在
# oneshot 结束时清理整个 cgroup（否则会把挂机进程一并杀掉）。
KillMode=none
# 统一走 start.sh：启动前会强制清理旧实例，避免多实例并发导致兑换不结算
ExecStart=/bin/bash $APP_DIR/start.sh
EOF

    cat > "/etc/systemd/system/${SCHED_SERVICE}.timer" <<EOF
[Unit]
Description=Run NeoHeberg AFK every day at ${hour}:${minute}

[Timer]
OnCalendar=*-*-* ${hour}:${minute}:00
Persistent=true
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SCHED_SERVICE}.timer" >/dev/null 2>&1 || { err "启用定时器失败"; return 1; }
    ok "已设置每日 ${hour}:${minute} 自动挂机"
    echo "    下次执行: $(systemctl list-timers "${SCHED_SERVICE}.timer" --no-pager 2>/dev/null | awk 'NR==2{print $1, $2, $3}')"
    echo "    查看状态: systemctl status ${SCHED_SERVICE}.timer"
    echo "    立即跑一次: systemctl start ${SCHED_SERVICE}.service"
    return 0
}

schedule_remove() {
    if ! schedule_installed; then
        warn "未设置定时挂机"
        return 0
    fi
    systemctl disable --now "${SCHED_SERVICE}.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SCHED_SERVICE}.service" "/etc/systemd/system/${SCHED_SERVICE}.timer"
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "已取消每日定时挂机"
    return 0
}

schedule_show() {
    if ! schedule_installed; then
        warn "未设置定时挂机"
        return 0
    fi
    echo "    定时器: $(systemctl is-active "${SCHED_SERVICE}.timer" 2>/dev/null || echo unknown) / $(systemctl is-enabled "${SCHED_SERVICE}.timer" 2>/dev/null || echo unknown)"
    systemctl list-timers "${SCHED_SERVICE}.timer" --no-pager 2>/dev/null | sed -n '1,2p' | sed 's/^/    /'
    return 0
}

menu_schedule() {
    echo ""
    echo "${CYAN}=== 每日定时挂机 ===${NC}"
    schedule_show
    echo ""
    echo "  [1] 设置/修改每日自动挂机"
    echo "  [2] 取消定时挂机"
    echo "  [3] 立即执行一次"
    echo "  [0] 返回"
    printf "请选择 [0-3]: "
    local c
    read -r c || c="0"
    case "$c" in
        1) schedule_install ;;
        2) schedule_remove ;;
        3)
            systemctl start "${SCHED_SERVICE}.service" 2>/dev/null && ok "已触发一次执行" || err "触发失败（需先设置定时）"
            ;;
        *) : ;;
    esac
}

# ---------------- 多账号管理 ----------------
require_multi() {
    [ -x "$MULTI_SCRIPT" ] || {
        err "multi-account.sh 不存在（安装时下载失败？）"
        info "可重新执行菜单 [1] 或菜单 [7] 更新后重试"
        return 1
    }
    return 0
}

# 添加账号：交互式填写，env 文件可输入路径，留空则直接填邮箱密码
menu_multi_add() {
    local name schedule envpath email pass proxy tmp
    printf "账号名（字母/数字/下划线/连字符，如 acc-a）: "
    read -r name || name=""
    if ! [[ ${name:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
        err "账号名不合法，已取消"; return 1
    fi
    printf "每日启动时间 HH:MM（如 06:30）: "
    read -r schedule || schedule=""
    if ! [[ ${schedule:-} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        err "时间格式不合法，已取消"; return 1
    fi
    printf "代理地址（可选，如 socks5://user:pass@host:port，留空=不走代理）: "
    read -r proxy || proxy=""
    printf "环境文件路径（留空则直接输入邮箱密码；env 文件自带 PROXY 时以文件为准）: "
    read -r envpath || envpath=""
    if [ -n "$envpath" ]; then
        [ -f "$envpath" ] || { err "环境文件不存在：$envpath"; return 1; }
        DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" add "$name" "$schedule" "$envpath"
        local rc=$?
        if [ $rc -eq 0 ] && [ -n "$proxy" ]; then
            DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" set-proxy "$name" "$proxy"
        fi
        return $rc
    fi
    printf "邮箱: "
    read -r email || email=""
    printf "密码: "
    read -rs pass || pass=""; echo ""
    if [ -z "$email" ] || [ -z "$pass" ]; then
        err "邮箱或密码为空，已取消"; return 1
    fi
    tmp=$(mktemp) || return 1
    umask 077
    {
        printf "EMAIL=%q\n" "$email"
        printf "PASSWORD=%q\n" "$pass"
        printf "TG_BOT_TOKEN=\n"
        printf "TG_CHAT_ID=\n"
        printf "NOTIFY_NAME=%q\n" "$name"
        if [ -n "$proxy" ]; then
            printf "PROXY=%q\n" "$proxy"
        fi
    } > "$tmp"
    DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" add "$name" "$schedule" "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

menu_multi_setproxy() {
    local name proxy
    printf "账号名: "
    read -r name || name=""
    if ! [[ ${name:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
        err "账号名不合法，已取消"; return 1
    fi
    printf "代理地址（留空=清除代理）: "
    read -r proxy || proxy=""
    DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" set-proxy "$name" "$proxy"
    local rc=$?
    if [ $rc -eq 0 ] && [ -n "$proxy" ]; then
        printf "是否立即重启该账号使代理生效？[y/N]: "
        local rr
        read -r rr || rr=""
        case "$rr" in
            y|Y|yes|YES) DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" restart "$name" ;;
            *) info "未重启，可稍后选 [5] 重启" ;;
        esac
    fi
    return $rc
}

menu_multi() {
    require_multi || return 1
    local c s name rc=0
    while true; do
        echo ""
        echo "${CYAN}=== 多账号管理 ===${NC}"
        DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" status || true
        echo ""
        echo "  [1] 添加账号（设每日启动时间/代理）"
        echo "  [2] 删除账号"
        echo "  [3] 启动全部账号"
        echo "  [4] 停止全部账号"
        echo "  [5] 重启全部账号"
        echo "  [6] 启动/停止指定账号"
        echo "  [7] 设置/清除账号代理"
        echo "  [8] 安装每日定时（systemd 用户定时器）"
        echo "  [9] 移除每日定时"
        echo "  [10] 查看日志（选账号）"
        echo "  [0] 返回"
        printf "请选择 [0-10]: "
        read -r c || continue
        case "$c" in
            1) menu_multi_add; rc=$? ;;
            2)
                printf "要删除的账号名: "
                read -r name || name=""
                [ -n "$name" ] || { err "未输入账号名"; }
                [ -z "$name" ] || DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" delete "$name"
                ;;
            3) DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" start ;;
            4) DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" stop ;;
            5) DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" restart ;;
            6)
                printf "操作 [s]tart 启动 / [t]op 停止: "
                read -r s || s=""
                printf "账号名（多个用空格分隔，留空=全部）: "
                read -r name || name=""
                case "$s" in
                    s|start)  DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" start $name ;;
                    t|stop)   DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" stop $name ;;
                    *) err "无效操作"; rc=1 ;;
                esac
                ;;
            7) menu_multi_setproxy; rc=$? ;;
            8) DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" install-timers
               info "注销后仍需执行，请确认已启用 linger: loginctl enable-linger $USER" ;;
            9) DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" remove-timers ;;
            10)
                printf "查看哪个账号的日志（留空=全部，f+账号名=实时跟踪，如 fa）: "
                read -r name || name=""
                if [ ! -d "${MULTI_HOME}/accounts" ]; then
                    info "还没有多账号数据（$MULTI_HOME）"
                elif [[ ${name:-} == f* && ${#name} -gt 1 ]]; then
                    tail -f "${MULTI_HOME}/accounts/${name#f}/logs/$(date +%F).log" 2>/dev/null || err "日志不存在（账号可能还没跑过）"
                elif [ -n "${name:-}" ]; then
                    ls -1t "${MULTI_HOME}/accounts/$name"/logs/*.log 2>/dev/null | head -3 | sed 's/^/    /'
                    tail -n 20 "${MULTI_HOME}/accounts/$name"/logs/$(date +%F).log 2>/dev/null || info "今日暂无日志"
                else
                    for d in "${MULTI_HOME}"/accounts/*/logs; do
                        [ -d "$d" ] || continue
                        echo "  --- ${d##*/accounts/}"
                        ls -1t "$d"/*.log 2>/dev/null | head -2 | sed 's/^/    /'
                    done
                fi
                ;;
            0) return 0 ;;
            *) err "无效选择" ;;
        esac
        echo ""
        printf "按回车返回多账号菜单..."
        read -r _pause || true
    done
}

# ---------------- 4. 卸载 ----------------
menu_uninstall() {
    echo ""
    echo "${CYAN}=== 卸载 ===${NC}"
    printf "确定卸载 NeoHeberg AFK 吗？进程、凭证、依赖都将删除；多账号定时器会移除，多账号数据会单独询问 [y/N]: "
    local c
    read -r c || c=""
    case "$c" in
        y|Y|yes|YES) ;;
        *) info "已取消"; return 0 ;;
    esac

    stop_bot >/dev/null 2>&1 || true

    if command -v systemctl >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${SERVICE}.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ok "systemd 服务已移除"
    fi

    if schedule_installed; then
        schedule_remove >/dev/null 2>&1 || true
    fi

    # 多账号：先移除每日定时器，再询问是否连同账号数据一起删
    if [ -x "$MULTI_SCRIPT" ]; then
        DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" stop >/dev/null 2>&1 || true
        DAFAGUO_MULTI_HOME="$MULTI_HOME" bash "$MULTI_SCRIPT" remove-timers >/dev/null 2>&1 || true
        ok "多账号定时器已移除"
        if [ -d "$MULTI_HOME/accounts" ]; then
            printf "是否同时删除多账号数据（账号凭证/浏览器profile/日志，$MULTI_HOME）？[y/N]: "
            local md
            read -r md || md=""
            case "$md" in
                y|Y|yes|YES)
                    rm -rf "$MULTI_HOME"
                    ok "多账号数据已删除"
                    ;;
                *) info "保留多账号数据于 $MULTI_HOME" ;;
            esac
        fi
    fi

    rm -rf "$APP_DIR"
    ok "已删除 $APP_DIR（含 venv、凭证、日志）"
    info "Firefox 运行时保留在 /root/.cache/ruyipage，如需彻底清理：rm -rf /root/.cache/ruyipage"
}

# ---------------- 更新主脚本（不动依赖） ----------------
menu_update() {
    echo ""
    echo "${CYAN}=== 更新主脚本 ===${NC}"

    if [ ! -d "$APP_DIR" ]; then
        err "尚未安装，请先选菜单 [1]"
        return 1
    fi

    local old_ver new_ver tmp="$APP_DIR/neoheberg.py.new"

    # 记录旧版本特征（方便对比是否变化）
    if [ -f "$SCRIPT" ]; then
        old_ver=$(md5sum "$SCRIPT" 2>/dev/null | awk '{print $1}')
    fi

    info "下载最新主脚本..."
    if ! curl -fsSL "$REPO_RAW/neoheberg.py" -o "$tmp"; then
        err "下载失败（检查网络）"
        return 1
    fi

    # 老 Python 注解适配 + 语法自检（失败就不替换，避免把坏脚本换上去）
    adapt_script_for_old_python_check "$tmp"
    if ! "$VENV/bin/python" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$tmp" >/dev/null 2>&1; then
        err "新脚本语法自检失败，已保留旧版本"
        rm -f "$tmp"
        return 1
    fi

    new_ver=$(md5sum "$tmp" 2>/dev/null | awk '{print $1}')
    if [ -n "$old_ver" ] && [ "$old_ver" = "$new_ver" ]; then
        ok "已是最新版本，无需更新"
        rm -f "$tmp"
        return 0
    fi

    # 备份旧版本后替换
    cp -f "$SCRIPT" "$SCRIPT.bak.$(date +%s)" 2>/dev/null || true
    mv -f "$tmp" "$SCRIPT"
    adapt_script_for_old_python || true
    ok "主脚本已更新"

    # 顺带更新多账号脚本（失败不影响主流程）
    if curl -fsSL "$REPO_RAW/multi-account.sh" -o "$APP_DIR/multi-account.sh.new" 2>/dev/null; then
        chmod +x "$APP_DIR/multi-account.sh.new"
        mv -f "$APP_DIR/multi-account.sh.new" "$MULTI_SCRIPT"
        ok "multi-account.sh 已更新"
    else
        warn "multi-account.sh 更新失败（保留旧版）"
    fi

    # 若在运行中，询问是否重启
    if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
        printf "脚本已更新，是否立即重启？[y/N]: "
        local rr
        read -r rr || rr=""
        case "$rr" in
            y|Y|yes|YES) stop_bot; start_bot ;;
            *) info "请选菜单 [6] 重启使其生效" ;;
        esac
    fi
    return 0
}

# 对任意路径的脚本做旧 Python 注解适配（不改全局 $SCRIPT）
adapt_script_for_old_python_check() {
    local f="$1"
    [ -f "$f" ] || return 0
    local pybin pyver
    if [ -x "$VENV/bin/python" ]; then pybin="$VENV/bin/python"; else pybin="python3"; fi
    pyver=$("$pybin" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "3.9")
    case "$pyver" in
        3.9|3.8|3.7|3.6)
            if grep -qE -- '->[[:space:]]*[A-Za-z_][A-Za-z0-9_.[], ]*[[:space:]]*[|][[:space:]]*[A-Za-z_]' "$f" 2>/dev/null; then
                sed -i -E 's/->[[:space:]]*([A-Za-z_][A-Za-z0-9_.[], ]*)[[:space:]]*[|][[:space:]]*([A-Za-z_][A-Za-z0-9_.[], ]*)/-> object/g' "$f"
            fi
            ;;
    esac
    return 0
}

# ---------------- 菜单 ----------------
menu() {
    while true; do
        local st
        if pgrep -f "$RUN_PATTERN" >/dev/null 2>&1; then
            st="${GREEN}运行中${NC}"
        elif [ -d "$APP_DIR" ]; then
            st="${YELLOW}已安装未运行${NC}"
        else
            st="${RED}未安装${NC}"
        fi

        clear 2>/dev/null || printf '\033[2J\033[H'
        echo -e "${GREEN}===============================================${NC}"
        echo -e " NeoHeberg AFK 管理脚本"
        echo -e " 服务状态: $st"
        echo -e " 安装目录: $APP_DIR"
        echo -e "${GREEN}===============================================${NC}"
        echo -e " ${CYAN}[1]${NC} 安装依赖"
        echo -e " ${CYAN}[2]${NC} 配置 Telegram 通知"
        echo -e " ${CYAN}[3]${NC} 查余额"
        echo -e " ${CYAN}[4]${NC} 每日定时挂机"
        echo -e " ${CYAN}[5]${NC} 运行状态"
        echo -e " ${CYAN}[6]${NC} 卸载"
        echo -e " ${CYAN}[8]${NC} 多账号管理"
        echo -e " ${CYAN}[0]${NC} 退出脚本"
        echo -e "${GREEN}===============================================${NC}"
        printf "请输入数字选择 [0-8]: "
        local choice
        read -r choice || continue

        case "$choice" in
            1) menu_install ;;
            2) menu_tg ;;
            3) menu_balance ;;
            4) menu_schedule ;;
            5) menu_status ;;
            6) menu_uninstall ;;
            8) menu_multi ;;
            0) echo "已退出"; exit 0 ;;
            *) err "无效选择"; sleep 1 ;;
        esac

        echo ""
        printf "按回车返回主菜单..."
        read -r _pause || true
    done
}

# ---------------- 入口（支持命令模式与交互模式） ----------------
need_root
case "${1:-}" in
    install)   menu_install ;;
    account)   menu_account ;;
    tg)        menu_tg ;;
    balance)   menu_balance ;;
    status)    menu_status ;;
    schedule)  menu_schedule ;;
    update|up) menu_update ;;
    uninstall|remove|del) menu_uninstall ;;
    *)
        if [ -t 0 ]; then
            menu
        else
            # SSH 非交互环境直接进菜单
            menu
        fi
        ;;
esac
