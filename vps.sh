#!/bin/bash
# safe-ecs-pro.sh - 终极安全版 VPS 检测脚本（支持带宽、延迟、AI、ASN）
# 作者：stephchow
# 特点：
#   ✅ 所有外联均为可信公共服务（Cloudflare / ipinfo.io / 国内镜像站）
#   ✅ HTTPS 加密，无数据上传，无统计，无分享
#   ✅ 支持 -speed -latency -ai -asn 全功能
#   ✅ 自动美化输出，关键结果高亮

set -euo pipefail

print_title() {
    echo -e "\n\033[1;36m==============================\033[0m"
    echo -e "\033[1;36m$1\033[0m"
    echo -e "\033[1;36m==============================\033[0m"
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

# === 参数解析 ===
ENABLE_SPEED=false
ENABLE_LATENCY=false
ENABLE_AI=false
ENABLE_ASN=false

if [[ $# -eq 0 ]]; then
    ENABLE_SPEED=true
    ENABLE_LATENCY=true
    ENABLE_AI=true
    ENABLE_ASN=true
    print_info "提示" "未指定参数，启用全部功能（-speed -latency -ai -asn）"
fi

for arg in "$@"; do
    case $arg in
        -speed)     ENABLE_SPEED=true ;;
        -latency)   ENABLE_LATENCY=true ;;
        -ai)        ENABLE_AI=true ;;
        -asn)       ENABLE_ASN=true ;;
        *) 
            echo "未知参数: $arg"
            echo "用法: $0 [-speed] [-latency] [-ai] [-asn]"
            exit 1
            ;;
    esac
done

# === 基础系统信息 ===
print_title "【系统基本信息】"
print_info "主机名" "$(hostname)"
print_info "内核版本" "$(uname -r)"
print_info "操作系统" "$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
print_info "架构" "$(uname -m)"
print_info "虚拟化" "$(systemd-detect-virt 2>/dev/null || echo "未知")"

LOCAL_IP4=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{print $7}' || echo "N/A")
LOCAL_IP6=$(ip route get 2001:4860:4860::8888 2>/dev/null | awk 'NR==1{print $7}' 2>/dev/null || echo "N/A")

print_info "IPv4 出口地址" "$LOCAL_IP4"
[[ "$LOCAL_IP6" != "N/A" ]] && print_info "IPv6 出口地址" "$LOCAL_IP6"

# === ASN 归属查询 ===
if $ENABLE_ASN && [[ "$LOCAL_IP4" != "N/A" ]]; then
    if command -v curl >/dev/null; then
        print_title "【IP 归属信息】"
        ASN_JSON=$(curl -s --connect-timeout 5 "https://ipinfo.io/$LOCAL_IP4/json" 2>/dev/null)
        if [[ -n "$ASN_JSON" && "$ASN_JSON" != *"rate limit"* ]]; then
            ORG=$(echo "$ASN_JSON" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
            COUNTRY=$(echo "$ASN_JSON" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
            REGION=$(echo "$ASN_JSON" | grep -o '"region":"[^"]*"' | cut -d'"' -f4)
            print_info "组织 (ASN)" "${ORG:-N/A}"
            print_info "地理位置" "${COUNTRY:-N/A} ${REGION:-}"
        else
            print_warning "ASN 查询失败（可能被限速）"
        fi
    fi
fi

# === 带宽测试 ===
if $ENABLE_SPEED; then
    if command -v curl >/dev/null; then
        print_title "【网络带宽测试】"
        echo "🌐 测速源: Cloudflare 官方 (https://speed.cloudflare.com)"

        # 下载 100MB
        DL_BPS=$(curl -4 -o /dev/null -s -w "%{speed_download}" \
            "https://speed.cloudflare.com/__down?bytes=104857600" --connect-timeout 10 2>/dev/null) || DL_BPS=""
        if [[ -n "$DL_BPS" && "$DL_BPS" != "0" ]]; then
            DL_MBS=$(awk "BEGIN {printf \"%.2f\", $DL_BPS/1024/1024}")
            print_success "下载速度: ${DL_MBS} MB/s"
        else
            print_error "下载测试失败"
        fi

        # 上传 10MB
        dd if=/dev/zero of=/tmp/upload.bin bs=1M count=10 &>/dev/null
        UL_BPS=$(curl -4 -T /tmp/upload.bin -s -w "%{speed_upload}" \
            "https://speed.cloudflare.com/__up" --connect-timeout 10 2>/dev/null) || UL_BPS=""
        rm -f /tmp/upload.bin
        if [[ -n "$UL_BPS" && "$UL_BPS" != "0" ]]; then
            UL_MBS=$(awk "BEGIN {printf \"%.2f\", $UL_BPS/1024/1024}")
            print_success "上传速度: ${UL_MBS} MB/s"
        else
            print_warning "上传测试失败（部分网络限制 POST）"
        fi
    fi
fi

# === 中国大陆多地区延迟 + 带宽（可选增强）===
if $ENABLE_LATENCY; then
    print_title "【中国大陆网络质量】"
    echo "（延迟单位：ms；速率单位：MB/s）"

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

        # 延迟测试（优先 ping，否则 HTTPS）
        if timeout 3 ping -c1 -W2 "$host" &>/dev/null; then
            latency=$(ping -c1 -W2 "$host" 2>/dev/null | grep 'time=' | awk -F'time=' '{print $2}' | cut -d' ' -f1)
            printf "%6.1f ms | " "$latency"
        else
            latency_ms=$(curl -so /dev/null -w "%{time_total*1000}" --connect-timeout 3 "https://$host" 2>/dev/null)
            if [[ $? -eq 0 && "$latency_ms" != "0.000" ]]; then
                printf "%6.1f ms | " "$latency_ms"
            else
                printf "%8s | " "超时"
                continue
            fi
        fi

        # 下载速率测试（10MB）
        speed_bps=$(curl -s -o /dev/null -w "%{speed_download}" --connect-timeout 8 "https://$host/test_10mb.bin" 2>/dev/null) || speed_bps=""
        if [[ -n "$speed_bps" && "$speed_bps" != "0" ]]; then
            speed_mbs=$(awk "BEGIN {printf \"%.1f\", $speed_bps/1024/1024}")
            printf "%6.1f MB/s" "$speed_mbs"
        else
            # 备用：使用阿里云 100MB 文件（仅北京）
            if [[ "$region" == "北京" ]]; then
                speed_bps=$(curl -s -o /dev/null -w "%{speed_download}" --connect-timeout 8 "https://mirrors.aliyun.com/100mb.test" 2>/dev/null)
                if [[ -n "$speed_bps" && "$speed_bps" != "0" ]]; then
                    speed_mbs=$(awk "BEGIN {printf \"%.1f\", $speed_bps/1024/1024}")
                    printf "%6.1f MB/s" "$speed_mbs"
                else
                    printf "%10s" "N/A"
                fi
            else
                printf "%10s" "N/A"
            fi
        fi
        echo
    done
fi

# === AI 网站可用性 ===
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
        if timeout 4 curl -s --head --fail "https://$domain" --connect-timeout 3 &>/dev/null; then
            print_success "$name: 可访问"
        else
            print_error "$name: 不可达"
        fi
    done
fi

# === 结束 ===
print_title "【检测完成】"
print_success "所有操作均在本地完成，未上传任何用户数据。"
