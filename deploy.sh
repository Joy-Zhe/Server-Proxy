#!/bin/bash
# 启动 sing-box 代理栈，并在缺少 .env 时生成示例文件

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "已创建 .env，请把 SUBSCRIPTION_URL 改成你的订阅地址后再执行更新。"
fi

docker compose up -d --build

echo
echo "基础服务已启动。"
echo "宿主机本地 HTTP 代理: http://127.0.0.1:7897"
echo "宿主机本地 SOCKS5 代理: socks5://127.0.0.1:7891"
echo
echo "下一步："
echo "1. 编辑 $SCRIPT_DIR/.env，填入 SUBSCRIPTION_URL"
echo "2. 运行: $SCRIPT_DIR/update-subscription.sh"
echo "3. 更新成功后，宿主机会通过 TUN 接管默认出站流量"
