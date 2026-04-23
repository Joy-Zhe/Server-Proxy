#!/bin/bash
# sing-box Clash 订阅自动更新脚本
# 用法: ./update-subscription.sh <订阅URL>
# 或: SUBSCRIPTION_URL=<订阅URL> ./update-subscription.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

SUBSCRIPTION_URL="${1:-$SUBSCRIPTION_URL}"
SUBSCRIPTION_UA="${SUBSCRIPTION_UA:-Mozilla/5.0}"
RUN_MODE="${RUN_MODE:-tun}"
ENABLE_LOCAL_PROXY="${ENABLE_LOCAL_PROXY:-true}"
LOCAL_HTTP_PORT="${LOCAL_HTTP_PORT:-7897}"
LOCAL_SOCKS_PORT="${LOCAL_SOCKS_PORT:-7891}"
CLASH_API_HOST="${CLASH_API_HOST:-0.0.0.0:9090}"
CLASH_API_SECRET="${CLASH_API_SECRET:-}"
TUN_INTERFACE_NAME="${TUN_INTERFACE_NAME:-sb-tun}"
TUN_IPV4_CIDR="${TUN_IPV4_CIDR:-172.19.0.1/30}"
TUN_IPV6_CIDR="${TUN_IPV6_CIDR:-fdfe:dcba:9876::1/126}"
TUN_MTU="${TUN_MTU:-1500}"
TUN_AUTO_REDIRECT="${TUN_AUTO_REDIRECT:-false}"
DIRECT_FALLBACK_USED=false

generate_direct_config() {
    python3 - <<'PY'
import json
import os

run_mode = os.environ.get('RUN_MODE', 'tun').lower()
enable_local_proxy = os.environ.get('ENABLE_LOCAL_PROXY', 'true').lower() in ('1', 'true', 'yes', 'on')
http_port = int(os.environ.get('LOCAL_HTTP_PORT', '7897'))
socks_port = int(os.environ.get('LOCAL_SOCKS_PORT', '7891'))
clash_api_host = os.environ.get('CLASH_API_HOST', '0.0.0.0:9090')
clash_api_secret = os.environ.get('CLASH_API_SECRET', '')
tun_interface = os.environ.get('TUN_INTERFACE_NAME', 'sb-tun')
tun_ipv4 = os.environ.get('TUN_IPV4_CIDR', '172.19.0.1/30')
tun_ipv6 = os.environ.get('TUN_IPV6_CIDR', 'fdfe:dcba:9876::1/126')
tun_mtu = int(os.environ.get('TUN_MTU', '1500'))
tun_auto_redirect = os.environ.get('TUN_AUTO_REDIRECT', 'false').lower() in ('1', 'true', 'yes', 'on')

inbounds = []
if run_mode == 'tun':
    inbounds.append({
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': tun_interface,
        'address': [tun_ipv4, tun_ipv6],
        'stack': 'system',
        'mtu': tun_mtu,
        'auto_route': True,
        'auto_redirect': tun_auto_redirect,
        'strict_route': True,
        'sniff': True,
        'sniff_override_destination': True,
    })

if enable_local_proxy:
    inbounds.extend([
        {'type': 'http', 'tag': 'http-in', 'listen': '127.0.0.1', 'listen_port': http_port},
        {'type': 'socks', 'tag': 'socks-in', 'listen': '127.0.0.1', 'listen_port': socks_port},
    ])

config = {
    'log': {'level': 'info', 'timestamp': True},
    'dns': {
        'servers': [
            {'tag': 'localDnsPrimary', 'address': '10.10.0.21', 'detour': 'direct'},
            {'tag': 'localDnsSecondary', 'address': '10.10.2.21', 'detour': 'direct'},
        ],
        'final': 'localDnsPrimary',
        'strategy': 'ipv4_only',
    },
    'inbounds': inbounds,
    'outbounds': [
        {'tag': 'proxy', 'type': 'selector', 'outbounds': ['direct']},
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'},
    ],
    'route': {
        'auto_detect_interface': True,
        'final': 'direct',
        'rules': [
            {'geoip': ['private'], 'outbound': 'direct'},
        ],
    },
    'experimental': {
        'clash_api': {
            'external_controller': clash_api_host,
            'secret': clash_api_secret,
            'external_ui': 'ui',
            'external_ui_download_url': 'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip',
            'default_mode': 'rule',
        }
    },
}

print(json.dumps(config, indent=2, ensure_ascii=False))
PY
}

if [ -z "$SUBSCRIPTION_URL" ]; then
    echo "错误: 请提供 Clash 订阅 URL"
    echo "用法: $0 <订阅URL>"
    echo "或: SUBSCRIPTION_URL=<订阅URL> $0"
    exit 1
fi

# 订阅站可能拦截默认 Python/requests 请求头，优先在宿主机侧抓取原始 base64 订阅，
# 再通过 sub:// 直接交给 sing-box-subscribe 解析，避免容器二次请求被 403/402 拒绝。
SUBSCRIPTION_SOURCE="$SUBSCRIPTION_URL"
RAW_SUBSCRIPTION=$(curl -fsSL --noproxy '*' -A "$SUBSCRIPTION_UA" --connect-timeout 30 --max-time 90 "$SUBSCRIPTION_URL" 2>/dev/null || true)
if [ -n "$RAW_SUBSCRIPTION" ]; then
    B64_SUBSCRIPTION=$(echo -n "$RAW_SUBSCRIPTION" | base64 -w0)
    SUBSCRIPTION_SOURCE="sub://$B64_SUBSCRIPTION"
fi

# sing-box-subscribe 服务地址 (本机端口映射)
API_HOST="${API_HOST:-127.0.0.1:5000}"
# 配置模板 URL (从 sing-box-subscribe 容器内通过宿主机端口访问)
TEMPLATE_URL="${TEMPLATE_URL:-http://host.docker.internal:8080/config_template.json}"

# URL 编码
ENCODED_SUB=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$SUBSCRIPTION_SOURCE', safe=''))")
ENCODED_TEMPLATE=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TEMPLATE_URL', safe=''))")
ENCODED_UA=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$SUBSCRIPTION_UA', safe=''))")

CONFIG_URL="http://${API_HOST}/config/${ENCODED_SUB}&file=${ENCODED_TEMPLATE}&ua=${ENCODED_UA}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在获取订阅配置..."

CONFIG_JSON=$(curl -sf --connect-timeout 30 --max-time 90 "$CONFIG_URL" 2>/dev/null || true)

# 若自定义模板失败，尝试使用内置模板 file=3 (config_template_no_groups_tun_VN)
if [ -z "$CONFIG_JSON" ] || echo "$CONFIG_JSON" | grep -q '"status".*"error"'; then
    echo "自定义模板不可用，使用内置模板..."
    CONFIG_URL="http://${API_HOST}/config/${ENCODED_SUB}&file=3&ua=${ENCODED_UA}"
    CONFIG_JSON=$(curl -sf --connect-timeout 30 --max-time 90 "$CONFIG_URL" 2>/dev/null || true)
fi

if [ -z "$CONFIG_JSON" ] || echo "$CONFIG_JSON" | grep -q '"status".*"error"'; then
    echo "警告: 无法获取订阅配置，将生成直连配置作为回退"
    echo "请检查: 1) 订阅 URL 是否正确  2) docker compose up -d 是否已启动"
    FINAL_CONFIG="$(generate_direct_config)"
    DIRECT_FALLBACK_USED=true
fi

# 按运行模式整理 inbounds:
# - tun: 为宿主机提供 TUN 全局代理，并可保留本地 HTTP/SOCKS 入口
# - proxy: 仅保留本地 HTTP/SOCKS 入口
if [ "$DIRECT_FALLBACK_USED" != true ]; then
    FINAL_CONFIG=$(echo "$CONFIG_JSON" | python3 -c "
import json, os, sys
d = json.load(sys.stdin)

run_mode = os.environ.get('RUN_MODE', 'tun').lower()
enable_local_proxy = os.environ.get('ENABLE_LOCAL_PROXY', 'true').lower() in ('1', 'true', 'yes', 'on')
http_port = int(os.environ.get('LOCAL_HTTP_PORT', '7897'))
socks_port = int(os.environ.get('LOCAL_SOCKS_PORT', '7891'))
clash_api_host = os.environ.get('CLASH_API_HOST', '0.0.0.0:9090')
clash_api_secret = os.environ.get('CLASH_API_SECRET', '')
tun_interface = os.environ.get('TUN_INTERFACE_NAME', 'sb-tun')
tun_ipv4 = os.environ.get('TUN_IPV4_CIDR', '172.19.0.1/30')
tun_ipv6 = os.environ.get('TUN_IPV6_CIDR', 'fdfe:dcba:9876::1/126')
tun_mtu = int(os.environ.get('TUN_MTU', '1500'))
tun_auto_redirect = os.environ.get('TUN_AUTO_REDIRECT', 'false').lower() in ('1', 'true', 'yes', 'on')

new_inbounds = []
has_http, has_socks, has_tun = False, False, False

def build_tun():
    return {
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': tun_interface,
        'address': [tun_ipv4, tun_ipv6],
        'stack': 'system',
        'mtu': tun_mtu,
        'auto_route': True,
        'auto_redirect': tun_auto_redirect,
        'strict_route': True,
        'sniff': True,
        'sniff_override_destination': True,
    }

for ib in d.get('inbounds', []):
    if ib.get('type') == 'tun':
        if run_mode == 'tun':
            ib['interface_name'] = tun_interface
            ib['address'] = [tun_ipv4, tun_ipv6]
            ib['stack'] = ib.get('stack', 'system')
            ib['mtu'] = tun_mtu
            ib['auto_route'] = True
            ib['auto_redirect'] = tun_auto_redirect
            ib['strict_route'] = True
            ib['sniff'] = True
            ib['sniff_override_destination'] = True
            new_inbounds.append(ib)
            has_tun = True
        continue
    if ib.get('type') == 'mixed':
        if enable_local_proxy:
            new_inbounds.append({'type':'http','tag':'http-in','listen':'127.0.0.1','listen_port':http_port})
            new_inbounds.append({'type':'socks','tag':'socks-in','listen':'127.0.0.1','listen_port':socks_port})
            has_http = has_socks = True
        continue
    if ib.get('type') == 'http':
        if enable_local_proxy:
            ib['listen'] = '127.0.0.1'
            ib['listen_port'] = http_port
            has_http = True
            new_inbounds.append(ib)
        continue
    elif ib.get('type') == 'socks':
        if enable_local_proxy:
            ib['listen'] = '127.0.0.1'
            ib['listen_port'] = socks_port
            has_socks = True
            new_inbounds.append(ib)
        continue
    new_inbounds.append(ib)

if run_mode == 'tun' and not has_tun:
    new_inbounds.insert(0, build_tun())
if enable_local_proxy and not has_http:
    insert_at = 1 if run_mode == 'tun' else 0
    new_inbounds.insert(insert_at, {'type':'http','tag':'http-in','listen':'127.0.0.1','listen_port':http_port})
if enable_local_proxy and not has_socks:
    insert_at = 2 if run_mode == 'tun' else 1
    new_inbounds.insert(insert_at, {'type':'socks','tag':'socks-in','listen':'127.0.0.1','listen_port':socks_port})

d['inbounds'] = new_inbounds
d.setdefault('log', {})['level'] = 'info'
proxy_suffixes = [
    'chatgpt.com',
    'openai.com',
    'oaistatic.com',
    'google.com',
    'gstatic.com',
    'googleapis.com',
    'googleusercontent.com',
    'github.com',
    'githubusercontent.com',
    'githubassets.com',
    'githubstatus.com',
    'github.io',
    'cursor.sh',
]

dns = d.setdefault('dns', {})
dns['servers'] = [
    {'tag': 'proxyDns', 'address': 'tls://8.8.8.8', 'detour': 'proxy'},
    {'tag': 'localDnsPrimary', 'address': '10.10.0.21', 'detour': 'direct'},
    {'tag': 'localDnsSecondary', 'address': '10.10.2.21', 'detour': 'direct'},
]
existing_dns_rules = dns.get('rules', [])
dns['rules'] = [{'domain_suffix': proxy_suffixes, 'server': 'proxyDns'}]
for rule in existing_dns_rules:
    if rule not in dns['rules']:
        dns['rules'].append(rule)
dns['final'] = 'localDnsPrimary'
dns['strategy'] = 'ipv4_only'

route = d.setdefault('route', {})
route['auto_detect_interface'] = True
route['final'] = 'direct'
existing_route_rules = route.get('rules', [])
route['rules'] = [{'domain_suffix': proxy_suffixes, 'outbound': 'proxy'}] + existing_route_rules

clash_api = d.setdefault('experimental', {}).setdefault('clash_api', {})
clash_api['external_controller'] = clash_api_host
clash_api['secret'] = clash_api_secret
clash_api.setdefault('external_ui', 'ui')
clash_api.setdefault('external_ui_download_url', 'https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip')
clash_api.setdefault('default_mode', 'rule')
print(json.dumps(d, indent=2, ensure_ascii=False))
" 2>/dev/null || echo "$CONFIG_JSON")
fi

[ -f config.json ] && cp config.json config.json.bak
echo "$FINAL_CONFIG" > config.json

if ! python3 -c "import json; json.load(open('config.json'))" 2>/dev/null; then
    echo "错误: 配置 JSON 无效，已恢复备份"
    [ -f config.json.bak ] && mv config.json.bak config.json
    exit 1
fi

if [ "$DIRECT_FALLBACK_USED" != true ] && ! python3 - <<'PY'
import json
import sys

with open('config.json', encoding='utf-8') as f:
    config = json.load(f)

builtin_tags = {'proxy', 'auto', 'direct', 'block'}
builtin_types = {'selector', 'urltest', 'direct', 'block'}

real_nodes = [
    outbound for outbound in config.get('outbounds', [])
    if outbound.get('tag') not in builtin_tags and outbound.get('type') not in builtin_types
]

if not real_nodes:
    sys.exit(1)
PY
then
    echo "警告: 当前订阅没有成功生成任何代理节点，将切换为直连配置"
    echo "请检查订阅链接是否可用，或返回内容是否为有效的 Clash/Mihomo 订阅"
    FINAL_CONFIG="$(generate_direct_config)"
    echo "$FINAL_CONFIG" > config.json
    DIRECT_FALLBACK_USED=true

    if ! python3 -c "import json; json.load(open('config.json'))" 2>/dev/null; then
        echo "错误: 直连回退配置 JSON 无效，已恢复备份"
        [ -f config.json.bak ] && mv config.json.bak config.json
        exit 1
    fi
fi

docker restart sing-box 2>/dev/null || true
CLASH_API_PORT="${CLASH_API_HOST##*:}"
docker exec sing-box sh -lc "if [ -d /ui ]; then cat > /ui/config.js <<'EOF'
window.__METACUBEXD_CONFIG__ = {
  defaultBackendURL: window.location.origin,
}
EOF
fi" 2>/dev/null || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 订阅更新完成! 模式: ${RUN_MODE}, 本地 HTTP: ${LOCAL_HTTP_PORT}, 本地 SOCKS5: ${LOCAL_SOCKS_PORT}"
echo "Web UI: http://127.0.0.1:${CLASH_API_PORT}/ui/"
echo "Clash API: http://127.0.0.1:${CLASH_API_PORT}"
if [ -n "$CLASH_API_SECRET" ]; then
    echo "UI 如提示密钥，请填写 .env 中的 CLASH_API_SECRET"
fi
if [ "$DIRECT_FALLBACK_USED" = true ]; then
    echo "说明: 当前没有可用代理节点，已生成直连配置，所有出站流量会走 direct。"
fi
echo "说明: 当前仓库会把订阅展开成 sing-box outbounds，MetaCubeXD 的节点列表显示在 Proxies 页面，Providers 页面为空是正常现象。"
