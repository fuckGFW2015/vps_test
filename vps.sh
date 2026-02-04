#!/bin/bash
# vps-check-ultimate.sh - 终极 VPS 检测脚本（高精度 ASN + 多源测速）
# 特点：
#   ✅ 使用 ipapi.co 精准识别阿里云香港等节点
#   ✅ 下载测速自动验证 + fallback 到 Linode/CacheFly
#   ✅ 明确提示“VPS 到国内” ≠ “你本地到 VPS”
#   ✅ 无 jq 依赖，仅需 curl/ip/ping

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

# 默认启用全部
ENABLE_SPEED=true; ENABLE_LATENCY=true; ENABLE_AI=true; ENABLE_ASN=true
if [[ $# -gt 0 ]]; then
    ENABLE_SPEED=false; ENABLE_LATENCY=false; ENABLE_AI=false; ENABLE_ASN=false
    for arg in "$@"; do
        case $arg in
            -speed)     ENABLE_SPEED=true ;;
            -latency)   ENABLE_LATENCY=true ;;
            -ai)        ENABLE_AI=true ;;
            -asn)       ENABLE_ASN=true ;;
            *) echo "用法: $0 [可选: -speed -latency -ai -asn]"; exit 1 ;;
        esac
    done
fi

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

# ========== 高精度 ASN 查询（使用 ipapi.co）==========
if $ENABLE_ASN && [[ "$PUBLIC_IP" != "N/A" ]] && command -v curl >/dev/null; then
    print_title "【IP 归属信息】"
    RESPONSE=$(timeout 6 curl -s "https://ipapi.co/${PUBLIC_IP}/json/" 2>/dev/null)
    
    if [[ -n "$RESPONSE" && "$RESPONSE" != *"error"* && "$RESPONSE" != *"reserved"* && "$RESPONSE" != *"private"* ]]; then
        ORG=$(echo "$RESPONSE" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
        COUNTRY=$(echo "$RESPONSE" | grep -o '"country_name":"[^"]*"' | cut -d'"' -f4)
        REGION=$(echo "$RESPONSE" | grep -o '"region":"[^"]*"' | cut -d'"' -f4)
        
        # 特殊处理：若 country_name 为空但 IP 属于知名云厂商
        if [[ -z "$COUNTRY" ]]; then
            if [[ "$ORG" == *"Alibaba"* || "$ORG" == *"Tencent"* || "$ORG" == *"Huawei"* ]]; then
                COUNTRY="Hong Kong (inferred from org)"
            fi
        fi
        
        print_info "组织 (ASN)" "${ORG:-N/A}"
        print_info "地理位置" "${COUNTRY:-N/A} ${REGION:-}"
    else
        print_warning "ASN 查询失败（IP 可能为内网或受限）"
    fi
fi

# ========== 带宽测试（增强版）==========
if $ENABLE_SPEED; then
    print_title "【网络带宽测试】"
    
    test_download() {
        local url=$1; local name=$2; local bytes=${3:-10485760}
        local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        
        RESULT=$(timeout 20 curl -4 -s -w "%{http_code}:%{size_download}:%{speed_download}" \
            -H "User-Agent: $ua" \
            "${url}?bytes=${bytes}" --connect-timeout 10 2>/dev/null || echo "0:0:0")
        
        HTTP=$(echo "$RESULT" | cut -d: -f1)
        SIZE=$(echo "$RESULT" | cut -d: -f2)
        SPEED=$(echo "$RESULT" | cut -d: -f3)
        
        if [[ "$HTTP" == "200" && "$SIZE" -gt 1000000 ]]; then
            MBPS=$(awk "BEGIN {printf \"%.2f\", $SPEED/1024/1024}")
            print_success "${name}: ${MBPS} MB/s"
            return 0
        fi
        return 1
    }

    if ! test_download "https://speed.cloudflare.com/__down" "Cloudflare 下载"; then
        if ! test_download "https://speedtest.fremont.linode.com/100MB" "Linode 下载" "104857600"; then
            if ! test_download "http://cachefly.cachefly.net/10mb.test" "CacheFly 下载" ""; then
                print_error "所有下载测速源均失败"
            fi
        fi
    fi

    # 上传测试
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
fi

# ========== 国内延迟（带明确提示）==========
if $ENABLE_LATENCY; then
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
fi

# ========== AI 可用性 ==========
if $ENABLE_AI; then
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
fi

print_title "【检测完成】"
print_success "所有结果仅在本地显示，未上传任何数据。"
