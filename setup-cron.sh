#!/bin/bash
# 配置 crontab 定时更新 Clash 订阅
# 默认每 6 小时更新一次

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/update-subscription.sh"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "请先创建 .env 文件并设置 SUBSCRIPTION_URL"
    echo "  cp .env.example .env"
    echo "  编辑 .env 填入你的 Clash 订阅 URL"
    exit 1
fi

# 加载 .env
set -a
source "$SCRIPT_DIR/.env"
set +a

if [ -z "$SUBSCRIPTION_URL" ]; then
    echo "错误: .env 中未设置 SUBSCRIPTION_URL"
    exit 1
fi

# 添加 crontab 条目 (每 6 小时)
CRON_LINE="0 */6 * * * SUBSCRIPTION_URL='$SUBSCRIPTION_URL' $UPDATE_SCRIPT"
(crontab -l 2>/dev/null | grep -v "update-subscription.sh"; echo "$CRON_LINE") | crontab -

echo "已添加定时任务: 每 6 小时更新一次订阅"
echo "当前 crontab:"
crontab -l | grep update-subscription
