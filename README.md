# Docker + sing-box 宿主机全局代理

基于 Docker 部署 sing-box，支持从 Clash 订阅自动转换，并通过 `TUN` 模式让宿主机全局走代理。

## 公开仓库说明

这个仓库已经按公开上传场景整理：

- `.env`、`config.json`、`config.json.bak` 会被 `.gitignore` 忽略，不会提交到 GitHub
- `.env.example` 是环境变量模板，克隆后复制为 `.env` 再填入你自己的订阅地址
- `config_template.example.json` 是公开模板文件，会直接挂载给 `template-server` 使用
- `config.json.example` 仅用于展示生成后的配置结构，不参与实际运行

## 架构

- `sing-box`: 代理核心，通过 `TUN` 接管宿主机默认出站流量，并保留本地 HTTP `7897` / SOCKS5 `7891`
- `sing-box-subscribe`: 将 Clash 订阅转换为 sing-box 配置
- `template-server`: 对外提供自定义配置模板

## 快速开始

### 1. 初始化环境文件

```bash
cp .env.example .env
```

编辑 `.env`，至少设置：

```bash
SUBSCRIPTION_URL=https://subscription.example.invalid/subscribe?token=replace-me
CLASH_API_SECRET=replace-with-a-random-secret
```

建议使用随机字符串作为 `CLASH_API_SECRET`，例如：

```bash
python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(24))
PY
```

### 2. 按需调整模板

默认模板是 `config_template.example.json`。如果你需要修改代理规则、DNS 或路由逻辑，直接编辑这个文件即可。

### 3. 启动服务

```bash
chmod +x deploy.sh
./deploy.sh
docker compose ps
```

`deploy.sh` 在缺少 `.env` 时会自动从 `.env.example` 复制一份。

### 4. 首次更新订阅

```bash
chmod +x update-subscription.sh

# 优先读取 .env 中的 SUBSCRIPTION_URL
./update-subscription.sh

# 或者临时传入订阅地址
./update-subscription.sh "https://subscription.example.invalid/subscribe?token=replace-me"
```

### 5. 配置自动更新

```bash
chmod +x setup-cron.sh
./setup-cron.sh
```

## 使用代理

- 宿主机全局代理: 更新订阅后，宿主机会通过 `sb-tun` 接管默认出站流量
- 本地 HTTP 代理: `http://127.0.0.1:7897`
- 本地 SOCKS5 代理: `socks5://127.0.0.1:7891`

## Web UI

这套配置启用了 `Clash API + MetaCubeXD` 图形界面。

- 默认本机访问: `http://127.0.0.1:9090/ui/`
- 默认局域网访问: `http://<服务器局域网IP>:9090/ui/`
- 默认后端地址: `http://<服务器局域网IP>:9090`

如果你把 `.env` 里的 `CLASH_API_HOST` 改成了别的端口，比如 `0.0.0.0:9091`，那 UI 和后端地址也要同步改成 `9091`。

如果 UI 页面要求填写密钥，使用 `.env` 中的 `CLASH_API_SECRET`。

MetaCubeXD 中的订阅节点会显示在 `Proxies` 页面；当前仓库会把订阅转换结果直接展开为 sing-box `outbounds`，所以 `Providers` 页面为空属于正常现象，不代表订阅拉取失败。

修改 `CLASH_API_SECRET` 或 `CLASH_API_HOST` 后，重新执行：

```bash
./update-subscription.sh
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `docker-compose.yml` | Docker 编排配置 |
| `.env.example` | 环境变量模板 |
| `config_template.example.json` | 公开的订阅转换模板，会被容器直接挂载使用 |
| `config.json.example` | 生成后配置的脱敏示例，仅供参考 |
| `config.json` | sing-box 运行配置，由脚本自动生成，不提交到 Git |
| `update-subscription.sh` | 订阅更新脚本 |
| `setup-cron.sh` | 配置定时任务 |

## 自定义

- `RUN_MODE=tun` 表示启用宿主机全局代理，改成 `proxy` 可退回仅本地 HTTP/SOCKS 代理
- `ENABLE_LOCAL_PROXY=true` 表示在 TUN 模式下继续保留 `127.0.0.1:7897/7891` 入口
- `CLASH_API_HOST=0.0.0.0:9090` 可让局域网访问 Web UI 与 Clash API
- `TUN_AUTO_REDIRECT=false` 是当前主机的兼容设置；若内核支持 nftables/netlink，可再改成 `true`
- `SUBSCRIPTION_UA=Mozilla/5.0` 用于兼容会拦截默认 Python/requests 请求头的订阅站
- `setup-cron.sh` 默认使用 `0 */6 * * *`，可按需调整更新频率

## 故障排查

1. 订阅更新失败: 确认订阅 URL 可访问，且 `docker compose up -d` 已启动相关容器
2. 模板获取失败: 脚本会自动回退到内置模板 `file=3`
3. 订阅没有可用节点: 脚本会生成直连配置，保留 TUN/本地 HTTP/SOCKS 入口，但所有出站流量走 `direct`
4. 代理无法连接: 检查本地 `config.json` 是否生成成功，以及 `sing-box` 容器状态
5. 镜像构建卡住: `Dockerfile.subscribe` 已改为直接下载 GitHub 压缩包，不依赖 `apt` 安装 `git`
6. 宿主机网络异常: 将 `.env` 中的 `RUN_MODE` 改回 `proxy` 后重新执行 `./update-subscription.sh`
