# NeoHeberg AFK 一键脚本

自动登录 [NeoHeberg](https://dash.neoheberg.fr) 并挂机刷广告额度，支持 Telegram 余额播报。

- 全程前台浏览器（Firefox）执行，与真实用户一致
- 自动过 Cloudflare 验证、Cap 验证码、【打地鼠】防刷小游戏
- 实时读取余额与今日进度（N/100），每轮打印单轮收益
- 刷满 100/100 后自动汇总并退出
- 支持 Telegram 播报（启动、收盘、异常）

> 仅供学习交流，使用风险自负。

## 环境要求

- Linux（测试于 Debian/Ubuntu），需能访问目标站点
- **出口 IP 非数据中心（推荐住宅 / WARP 类出口）**。数据中心 IP 会被广告网络直接甩走、跳过结算流程，导致「能运行但不涨币」。

## 依赖

```bash
python3 -m venv venv
venv/bin/pip install ruyipage
venv/bin/python -m ruyipage install   # 下载 Firefox 运行时（约百兆）
apt install -y xvfb
```

脚本会自动定位 `~/.cache/ruyipage/browsers/firefox-*/firefox/firefox`，无需硬编码路径。

## 运行

```bash
set -a && . ./env && set +a
xvfb-run -a -s "-screen 0 1024x768x24" ./venv/bin/python ./neoheberg.py
```

后台运行：

```bash
cd /opt/neoheberg-afk && setsid nohup xvfb-run -a -s "-screen 0 1024x768x24" \
  ./venv/bin/python ./neoheberg.py > neoheberg.log 2>&1 < /dev/null &
```

## 环境变量

写入 `env` 文件（权限 600），或直接导出：

| 变量 | 必填 | 说明 |
|------|------|------|
| `EMAIL` | 是 | NeoHeberg 登录账号 |
| `PASSWORD` | 是 | 登录密码 |
| `TG_BOT_TOKEN` | 否 | Telegram 机器人 Token |
| `TG_CHAT_ID` | 否 | Telegram chat id |
| `PROXY` | 否 | 如 `socks5://user:pass@host:port` |
| `BROWSER_WORK_DIR` | 否 | 工作目录，默认 `/home/browser/browser-work` |
| `BROWSER_USER_DATA_DIR` | 否 | 指定 Firefox profile 目录（保留登录态）|

## 日志样例

```
✅ 纯物理火狐挂机任务开始！余额 13.740000 coins，今日已看 66/100
🎲 触发【打地鼠】防刷游戏，启动自瞄外挂！
🔫 开火 [3/5]
✅ 打地鼠完成，靶子已消失
🎉 历劫归来！第 29 轮完成！余额 14.244600 coins（本轮 +0.034600）已看 67/100
```

## 常用命令

```bash
tail -f /opt/neoheberg-afk/neoheberg.log   # 实时日志
pkill -9 -f neoheberg.py                   # 停止
```
