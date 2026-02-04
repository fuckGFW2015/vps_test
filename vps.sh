#!/bin/bash
# vps.sh - 阿里云/腾讯云/VPS 终极检测脚本（容错增强版）
# 特点：
#   ✅ 自动获取真实公网 IP（即使在 NAT/容器中）
#   ✅ 所有网络请求独立容错，失败不中断
#   ✅ 默认全功能开启，无需参数
#   ✅ 仅依赖 curl / ping / ip（几乎所有系统自带）

# ========== 工具函数 ==========
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

# ========== 参数处理 ==========
ENABLE_SPEED=true
ENABLE_LATENCY=true
ENABLE_AI=true
ENABLE_ASN=true

if [[ $# -gt 0 ]]; then
    ENABLE_SPEED=false; ENABLE_LATENCY=false; ENABLE_AI=false; ENABLE_ASN=false
    for arg in "$@"; do
        case $arg in
            -speed)     ENABLE_SPEED=true ;;
            -latency)   ENABLE_LATENCY=true ;;
            -ai)        ENABLE_AI=true ;;
            -asn)       ENABLE_ASN=true ;;
            *) 
                echo "用法: $0 [可选: -speed -latency -ai -asn]"; exit 1 ;;
        esac
    done
fi

# ========== 系统信息（本地命令，必成功）==========
print_title "【系统基本信息】"
print_info "主机名" "$(hostname)"
print_info "内核版本" "$(uname -r 2>/dev/null || echo "N/A")"
print_info "操作系统" "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "N/A")"
print_info "架构" "$(uname -m 2>/dev/null || echo "N/A")"
print_info "虚拟化" "$(systemd-detect-virt 2>/dev/null || echo "未知")"

# ========== 智能获取公网 IP ==========
print_info "内网 IPv4" "$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{print $7}' || echo "N/A")"

PUBLIC_IP=""
if command -v curl >/dev/null; then
    PUBLIC_IP=$(timeout 5 curl -s https://ifconfig.me 2>/dev/null)
fi
if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == *"html"* ]]; then
    if command -v wget >/dev/null; then
        PUBLIC_IP=$(timeout 5 wget -qO- https://ifconfig.me 2>/dev/null)
    fi
fi
print_info "公网 IPv4" "${PUBLIC_IP:-无法探测}"

# ========== ASN 查询 ==========
if $ENABLE_ASN && [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "无法探测" ]]; then
    print_title "【IP 归属信息】"
    if command -v curl >/dev/null; then
        ASN_JSON=$(timeout 6 curl -s "https://ipinfo.io/${PUBLIC_IP}/json" 2>/dev/null)
        if [[ -n "$ASN_JSON" && "$ASN_JSON" != *"rate limit"* && "$ASN_JSON" != *"Wrong IP"* ]]; then
            ORG=$(echo "$ASN_JSON" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
            COUNTRY=$(echo "$ASN_JSON" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
            REGION=$(echo "$ASN_JSON" | grep -o '"region":"[^"]*"' | cut -d'"' -f4)
            print_info "组织 (ASN)" "${ORG:-N/A}"
            print_info "地理位置" "${COUNTRY:-N/A} ${REGION:-}"
        else
            print_warning "ASN 查询失败（限速或无效 IP）"
        fi
    else
        print_warning "curl 未安装，跳过 ASN 查询"
    fi
fi

# ========== 带宽测试 ==========
if $ENABLE_SPEED; then
    print_title "【网络带宽测试】"
    if command -v curl >/dev/null; then
        echo "🌐 测速源: Cloudflare (100MB 下载 + 10MB 上传)"

        # 下载测试
        if DL_BPS=$(timeout 20 curl -4 -o /dev/null -s -w "%{speed_download}" \
            "https://speed.cloudflare.com/__down?bytes=104857600" --connect-timeout 10 2>/dev/null) && [[ -n "$DL_BPS" && "$DL_BPS" != "0" ]]; then
            DL_MBS=$(awk "BEGIN {printf \"%.2f\", $DL_BPS/1024/1024}")
            print_success "下载速度: ${DL_MBS} MB/s"
        else
            print_warning "下载测试失败（网络不通或超时）"
        fi

        # 上传测试
        dd if=/dev/zero of=/tmp/upload.bin bs=1M count=10 &>/dev/null
        if UL_BPS=$(timeout 20 curl -4 -T /tmp/upload.bin -s -w "%{speed_upload}" \
            "https://speed.cloudflare.com/__up" --connect-timeout 10 2>/dev/null) && [[ -n "$UL_BPS" && "$UL_BPS" != "0" ]]; then
            UL_MBS=$(awk "BEGIN {printf \"%.2f\", $UL_BPS/1024/1024}")
            print_success "上传速度: ${UL_MBS} MB/s"
        else
            print_warning "上传测试失败（部分云厂商限制 POST）"
        fi
        rm -f /tmp/upload.bin
    else
        print_warning "curl 未安装，跳过带宽测试"
    fi
fi

# ========== 中国大陆延迟 ==========
if $ENABLE_LATENCY; then
    print_title "【中国大陆网络质量】"
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

        # 优先 ping，否则 HTTPS 延迟
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

# ========== AI 网站可用性 ==========
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

# ========== 结束 ==========
print_title "【检测完成】"
print_success "所有结果仅在本地显示，未上传任何数据。"
