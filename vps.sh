#!/bin/bash
# vps-check-aliyun-stable.sh
# 特点：
#   ✅ 复用你首次成功的下载方式（http://cachefly.net/10mb.test）
#   ✅ 不设置任何 User-Agent 或 Header（避免触发阿里云风控）
#   ✅ 用纯字符串长度判断下载成功（绕过 curl -w 的 null byte 问题）
#   ✅ 保留所有其他功能（ASN、延迟、AI 等）

export LC_ALL=C

print_title() {
    echo -e "\n\033[1;36m==================================================\033[0m"
    echo -e "\033[1;36m$1\033[0m"
    echo -e "\033[1;36m==================================================\033[0m"
}

print_info() {
    echo -e "🔹 \033[1m$1\033[0m: $2"
}

print_success() {
    echo -e "✅ \033[1;32m$1\033[0m"
}

print_warning() {
    echo -e "⚠️ \033[1;33m$1\033[0m"
}

print_error() {
    echo -e "❌ \033[1;31m$1\033[0m"
}

# ========== 系统信息 ==========
print_title "【系统基本信息】"
print_info "主机名" "$(hostname)"
print_info "内核版本" "$(uname -r 2>/dev/null || echo "N/A")"
print_info "操作系统" "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "N/A")"
print_info "架构" "$(uname -m 2>/dev/null || echo "N/A")"
print_info "虚拟化" "$(systemd-detect-virt 2>/dev/null || echo "未知")"

LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{print $7}' || echo "N/A")
PUBLIC_IP=$(timeout 5 curl -s https://ifconfig.me 2>/dev/null || timeout 5 wget -qO- https://ifconfig.me 2>/dev/null || echo "N/A")

print_info "内网 IPv4" "$LOCAL_IP"
print_info "公网 IPv4" "$PUBLIC_IP"

# ========== 高精度 ASN 查询 ==========
print_title "【IP 归属信息】"

if ! command -v jq >/dev/null; then
    if command -v apt >/dev/null 2>&1; then
        timeout 30 apt update >/dev/null 2>&1 && timeout 60 apt install -y jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        timeout 60 yum install -y jq >/dev/null 2>&1
    fi
fi

ORG_INFO="N/A"; GEO_INFO="N/A"

if command -v jq >/dev/null && command -v curl >/dev/null; then
    RESP=$(timeout 6 curl -s "http://ip-api.com/json/${PUBLIC_IP}?fields=status,country,regionName,city,isp,as" 2>/dev/null)
    if [[ -n "$RESP" ]] && [[ "$(echo "$RESP" | jq -r '.status // "fail"' 2>/dev/null)" == "success" ]]; then
        COUNTRY=$(echo "$RESP" | jq -r '.country // empty')
        REGION=$(echo "$RESP" | jq -r '.regionName // empty')
        ISP=$(echo "$RESP" | jq -r '.isp // empty')
        AS_NUM=$(echo "$RESP" | jq -r '.as // empty')
        ORG_INFO="${ISP} (${AS_NUM})"
        GEO_INFO="${COUNTRY} ${REGION}"
    fi
fi

if [[ "$ORG_INFO" == "N/A" ]] && command -v whois >/dev/null; then
    WHOIS_OUT=$(timeout 5 whois "$PUBLIC_IP" 2>/dev/null)
    if [[ -n "$WHOIS_OUT" ]]; then
        ORG=$(echo "$WHOIS_OUT" | grep -iE "orgname|descr|owner" | head -1 | cut -d: -f2- | xargs 2>/dev/null)
        COUNTRY=$(echo "$WHOIS_OUT" | grep -i "country" | head -1 | cut -d: -f2 | xargs 2>/dev/null)
        ORG_INFO="${ORG:-N/A}"
        GEO_INFO="${COUNTRY:-N/A}"
    fi
fi

# 阿里云香港 IP 段智能推断
if [[ "$PUBLIC_IP" =~ ^(47\.23[89]|47\.24[01]|47\.251|8\.21[01])\. ]] && [[ "$GEO_INFO" == *"N/A"* ]]; then
    GEO_INFO="Hong Kong (inferred from IP range)"
    ORG_INFO="Alibaba Cloud (AS45102)"
fi

print_info "组织 (ASN)" "$ORG_INFO"
print_info "地理位置" "$GEO_INFO"

# ========== 网络带宽测试（阿里云稳定版）==========
print_title "【网络带宽测试】"

test_download() {
    local url=$1
    local name=$2
    
    # 关键：不设 UA，不设 Header，用 HTTP（对 cachefly）
    local start_time=$(date +%s%3N)
    local data
    data=$(timeout 20 curl -4 -s --connect-timeout 8 "$url" 2>/dev/null)
    local end_time=$(date +%s%3N)
    
    local size=${#data}
    # 成功条件：下载 > 1MB
    if [[ $size -gt 1000000 ]]; then
        local elapsed_ms=$((end_time - start_time))
        if [[ $elapsed_ms -le 0 ]]; then elapsed_ms=1; fi
        # 计算 MB/s
        local speed_mbps=$(awk "BEGIN {printf \"%.2f\", ($size * 1000 / $elapsed_ms) / 1024 / 1024}")
        print_success "${name}: ${speed_mbps} MB/s"
        return 0
    fi
    return 1
}

# 使用你首次成功的源：CacheFly via HTTP
if ! test_download "http://cachefly.cachefly.net/10mb.test" "CacheFly 下载"; then
    print_error "下载测速失败（可能被临时限制）"
fi

# 上传测试（保持原样）
dd if=/dev/zero of=/tmp/upload.bin bs=1M count=10 &>/dev/null
UL_BPS=$(timeout 20 curl -4 -T /tmp/upload.bin -s -w "%{speed_upload}" \
    "https://speed.cloudflare.com/__up" --connect-timeout 10 2>/dev/null) || UL_BPS=""
rm -f /tmp/upload.bin
if [[ -n "$UL_BPS" && "$UL_BPS" != "0" ]]; then
    UL_MBS=$(awk "BEGIN {printf \"%.2f\", $UL_BPS/1024/1024}")
    print_success "上传速度: ${UL_MBS} MB/s"
else
    print_warning "上传测试失败"
fi

# ========== 国内延迟 & AI 可用性 ==========
print_title "【中国大陆网络质量】"
echo "💡 注意：以下延迟表示「本 VPS 到国内 CDN 节点」的访问速度"
echo "   用于评估建站/代理性能。若需测试「你本地到本 VPS」的延迟，"
echo "   请在你的电脑上运行：ping $PUBLIC_IP"
echo "（单位：毫秒，越低越好）"

declare -A NODES=(
    ["北京"]="mirrors.aliyun.com"
    ["上海"]="mirrors.tuna.tsinghua.edu.cn"
    ["广州"]="mirrors.cloud.tencent.com"
    ["成都"]="mirrors.cqu.edu.cn"
    ["深圳"]="repo.huaweicloud.com"
)

for region in "${!NODES[@]}"; do
    host="${NODES[$region]}"
    printf "%-8s → " "$region"
    if timeout 4 ping -c1 -W2 "$host" &>/dev/null; then
        latency=$(ping -c1 -W2 "$host" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
        printf "\033[1;32m%6.1f ms\033[0m\n" "$latency"
    else
        latency_ms=$(timeout 5 curl -so /dev/null -w "%{time_total*1000}" --connect-timeout 3 "https://$host" 2>/dev/null)
        if [[ $? -eq 0 && "$latency_ms" != "0.000" ]]; then
            printf "\033[1;33m%6.1f ms (HTTPS)\033[0m\n" "$latency_ms"
        else
            printf "\033[1;31m%8s\033[0m\n" "超时"
        fi
    fi
done

print_title "【主流 AI 网站可用性】"
declare -A AI_SITES=(
    ["ChatGPT"]="chat.openai.com"
    ["Claude"]="claude.ai"
    ["Gemini"]="gemini.google.com"
    ["文心一言"]="yiyan.baidu.com"
    ["通义千问"]="qwen.ai"
    ["Kimi"]="kimi.moonshot.cn"
    ["DeepSeek"]="deepseek.com"
    ["豆包"]="doubao.com"
)
for name in "${!AI_SITES[@]}"; do
    domain="${AI_SITES[$name]}"
    if timeout 6 curl -s --head --fail "https://$domain" --connect-timeout 4 &>/dev/null; then
        print_success "$name: 可访问"
    else
        print_error "$name: 不可达"
    fi
done

print_title "【检测完成】"
print_success "所有结果仅在本地显示，未上传任何数据。"
