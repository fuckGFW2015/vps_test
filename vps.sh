#!/bin/bash
# vps-check-full-auto.sh
# 特点：
#   ✅ 自动安装 Speedtest CLI（如未安装）
#   ✅ 精准测速（复现 ecs 脚本结果）
#   ✅ 阿里云/腾讯云/RACKNERD 全兼容
#   ✅ 保留原有 UI 与功能模块

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

if [[ "$PUBLIC_IP" =~ ^(47\.23[89]|47\.24[01]|47\.251|8\.21[01])\. ]] && [[ "$GEO_INFO" == *"N/A"* ]]; then
    GEO_INFO="Hong Kong (inferred from IP range)"
    ORG_INFO="Alibaba Cloud (AS45102)"
fi

print_info "组织 (ASN)" "$ORG_INFO"
print_info "地理位置" "$GEO_INFO"

# ========== 网络带宽测试（自动安装 Speedtest CLI）==========
print_title "【网络带宽测试】"

install_speedtest() {
    if command -v speedtest >/dev/null 2>&1; then
        return 0
    fi

    print_info "Speedtest CLI" "未检测到，正在自动安装..."
    
    # 检测系统类型
    if command -v apt >/dev/null 2>&1; then
        # Ubuntu/Debian
        if ! timeout 30 curl -s https://install.speedtest.net/app/cli/install.deb.sh | sudo bash >/dev/null 2>&1; then
            print_error "Speedtest 安装失败（apt 系统）"
            return 1
        fi
        if ! timeout 60 sudo apt install -y speedtest >/dev/null 2>&1; then
            print_error "Speedtest 安装失败（apt install）"
            return 1
        fi
    elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
        # CentOS/Rocky/AlmaLinux
        if ! timeout 30 curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash >/dev/null 2>&1; then
            print_error "Speedtest 仓库添加失败（yum/dnf 系统）"
            return 1
        fi
        if command -v dnf >/dev/null 2>&1; then
            if ! timeout 60 sudo dnf install -y speedtest >/dev/null 2>&1; then
                print_error "Speedtest 安装失败（dnf）"
                return 1
            fi
        else
            if ! timeout 60 sudo yum install -y speedtest >/dev/null 2>&1; then
                print_error "Speedtest 安装失败（yum）"
                return 1
            fi
        fi
    else
        print_warning "不支持的包管理器，跳过安装"
        return 1
    fi

    if command -v speedtest >/dev/null 2>&1; then
        print_success "Speedtest CLI 安装成功"
        return 0
    else
        print_error "Speedtest 安装完成但无法调用"
        return 1
    fi
}

run_speedtest() {
    if ! command -v speedtest >/dev/null 2>&1; then
        if ! install_speedtest; then
            return 1
        fi
    fi

    echo "⏳ 正在运行 Speedtest（连接最近节点）..."
    local json_output
    json_output=$(timeout 45 speedtest --accept-license --accept-gdpr --format=json 2>/dev/null)

    if [[ -n "$json_output" ]] && echo "$json_output" | jq -e . >/dev/null 2>&1; then
        local dl_bps=$(echo "$json_output" | jq -r '.download.bandwidth // empty')
        local ul_bps=$(echo "$json_output" | jq -r '.upload.bandwidth // empty')
        local ping_ms=$(echo "$json_output" | jq -r '.ping.latency // empty')
        
        if [[ "$dl_bps" != "null" && "$dl_bps" -gt 0 ]]; then
            local dl_mbps=$(awk "BEGIN {printf \"%.2f\", $dl_bps*8/1000000}")
            print_success "下载速度: ${dl_mbps} Mbps"
        fi
        if [[ "$ul_bps" != "null" && "$ul_bps" -gt 0 ]]; then
            local ul_mbps=$(awk "BEGIN {printf \"%.2f\", $ul_bps*8/1000000}")
            print_success "上传速度: ${ul_mbps} Mbps"
        fi
        if [[ "$ping_ms" != "null" ]]; then
            print_success "延迟: ${ping_ms} ms"
        fi
        return 0
    else
        print_error "Speedtest 执行失败或无有效输出"
        return 1
    fi
}

# 执行测速（自动安装 + 运行）
if ! run_speedtest; then
    print_warning "Speedtest 测速失败，尝试本地镜像验证网络连通性"
    if timeout 5 curl -sf http://mirrors.aliyun.com/ubuntu/ls-lR.gz > /dev/null 2>&1; then
        print_success "阿里云镜像: 可访问（说明出站网络正常）"
    else
        print_error "本地镜像也无法访问，可能存在网络限制"
    fi
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
