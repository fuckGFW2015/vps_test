#!/bin/bash
# vps.sh
# 专为阿里云等环境优化：自动安装官方 Speedtest CLI，精准测速

export LC_ALL=C

# ========== 1. 函数定义 ==========
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

# ========== 2. 环境兼容性检查 ==========
if ! command -v free >/dev/null || ! command -v df >/dev/null; then
    print_error "当前环境缺少基础工具（free/df），可能为容器或 Alpine 系统"
    echo "   请在标准 Ubuntu/Debian/CentOS 上运行"
    exit 1
fi

# ========== 3. 主逻辑开始 ==========
print_title "【系统基本信息】"
# ... 后续代码

# ========== 系统信息 ==========
print_title "【系统基本信息】"
print_info "主机名" "$(hostname)"
print_info "内核版本" "$(uname -r 2>/dev/null || echo "N/A")"
print_info "操作系统" "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "N/A")"
print_info "架构" "$(uname -m 2>/dev/null || echo "N/A")"
print_info "虚拟化" "$(systemd-detect-virt 2>/dev/null || echo "未知")"

LOCAL_IP=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{print $7}' || echo "N/A")
PUBLIC_IP=$(timeout 5 curl -s https://ifconfig.me 2>/dev/null || timeout 5 wget -qO- https://ifconfig.me 2>/dev/null || echo "N/A")

# ========== 内存 & 硬盘 & CPU ==========
print_title "【硬件资源概览】"

# --- 内存 ---
if command -v free >/dev/null; then
    mem_total=$(free -m | awk 'NR==2{printf "%.1f", $2/1024}')
    mem_used=$(free -m | awk 'NR==2{printf "%.1f", $3/1024}')
    mem_avail=$(free -m | awk 'NR==2{printf "%.1f", $7/1024}')
    swap_total=$(free -m | awk 'NR==3{printf "%.1f", $2/1024}')
    swap_used=$(free -m | awk 'NR==3{printf "%.1f", $3/1024}')
    
    print_info "内存 (RAM)" "${mem_used} GiB / ${mem_total} GiB (可用: ${mem_avail} GiB)"
    
    # 安全判断 Swap 是否 > 0（无需 bc）
    if (( $(awk "BEGIN {print ($swap_total > 0)}") )); then
        print_info "Swap" "${swap_used} GiB / ${swap_total} GiB"
    fi
else
    print_info "内存" "N/A (free 命令不可用)"
fi

# --- CPU 核心数 ---
cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "N/A")
print_info "CPU 核心数" "$cpu_cores"

# --- 硬盘（根分区）---
if command -v df >/dev/null; then
    root_fs=$(df -T / | awk 'NR==2{print $2}')
    root_size=$(df -h / | awk 'NR==2{print $2}')
    root_used=$(df -h / | awk 'NR==2{print $3}')
    root_avail=$(df -h / | awk 'NR==2{print $4}')
    root_use_pct=$(df -h / | awk 'NR==2{print $5}')
    print_info "硬盘 (/)" "${root_used} / ${root_size} (${root_use_pct} used, ${root_fs})"
else
    print_info "硬盘" "N/A (df 命令不可用)"
fi

# IP 信息放回原位
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

# ========== 网络带宽测试（修复版：自动安装官方 speedtest）==========
print_title "【网络带宽测试】"

install_speedtest_official() {
    print_info "Speedtest CLI" "正在下载官方二进制（安全安装）..."

    if ! command -v curl >/dev/null; then
        if command -v apt >/dev/null 2>&1; then
            timeout 30 apt update >/dev/null 2>&1 && timeout 60 apt install -y curl ca-certificates
        fi
    fi

    # 创建临时目录
    tmp_dir=$(mktemp -d)
    
    # 下载并解压
    if curl -L https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz | tar -xz -C "$tmp_dir"; then
        # 找到 speedtest 可执行文件（无论目录名是什么）
        bin_path=$(find "$tmp_dir" -name "speedtest" -type f | head -n1)
        
        if [[ -n "$bin_path" ]]; then
            sudo cp "$bin_path" /usr/local/bin/speedtest
            sudo chmod +x /usr/local/bin/speedtest
            
            if command -v speedtest >/dev/null 2>&1; then
                rm -rf "$tmp_dir"
                print_success "Speedtest CLI 安装成功"
                return 0
            fi
        fi
    fi

    rm -rf "$tmp_dir"
    print_error "Speedtest 安装失败"
    return 1
}
run_speedtest() {
    # 先检查是否已安装（PATH 中包含 /usr/local/bin）
    if ! command -v speedtest >/dev/null 2>&1; then
        if ! install_speedtest_official; then
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
        print_error "Speedtest 执行无有效输出"
        return 1
    fi
}

# 执行测速
if ! run_speedtest; then
    print_warning "回退：测试阿里云本地镜像连通性"
    if timeout 5 curl -sfI http://mirrors.aliyun.com/ubuntu/ > /dev/null 2>&1; then
        print_success "阿里云镜像: 可访问（网络出站正常）"
    else
        print_error "阿里云镜像也无法访问，可能存在网络限制"
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
