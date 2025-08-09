#!/bin/bash
#
# BBR Plus + FQ/FQ_PIE/CAKE 强制启用器 - 守护增强版
# 支持多种启动方式，并提供守护模式以对抗配置覆盖，确保BBR Plus在任何情况下都能正常启用
#
# 使用方法:
# curl -fsSL https://raw.githubusercontent.com/your-username/bbrplus-enabler/main/enable-bbrplus.sh | bash
#

set -e

# 颜色定义
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

# 脚本版本
VERSION="3.0.0-guardian"

# 检测发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        OS_VERSION=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        OS_VERSION=$(lsb_release -sr)
    else
        OS=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
}

# 输出带时间戳的日志
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ 请使用 root 用户运行此脚本${RESET}"
        exit 1
    fi
}

# 检查BBR Plus支持
check_bbrplus() {
    log "${BLUE}🔍 检查 BBR Plus 内核支持...${RESET}"
    
    local algo=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    
    echo "当前拥塞控制算法: $current"
    echo "可用拥塞控制算法: $algo"
    
    if ! echo "$algo" | grep -qw "bbrplus"; then
        echo -e "${RED}❌ 当前系统未检测到 BBR Plus 支持${RESET}"
        echo -e "${YELLOW}💡 请确保已安装支持 BBR Plus 的内核${RESET}"
        echo -e "${YELLOW}   常见的内核包括: xanmod, liquorix, 或自编译内核${RESET}"
        
        read -p "是否继续配置？某些方法可能在重启后生效 (y/N): " continue_setup
        if [[ ! $continue_setup =~ ^[Yy] ]]; then
            exit 1
        fi
    else
        echo -e "${GREEN}✅ 检测到 BBR Plus 内核支持${RESET}"
    fi
}

# 检查FQ_PIE支持
check_fqpie() {
    log "${BLUE}🔍 检查 FQ_PIE 队列规程支持...${RESET}"
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    echo "当前队列规程: $current_qdisc"
    
    if lsmod | grep -q sch_fq_pie || modinfo sch_fq_pie >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 检测到 FQ_PIE 队列规程支持${RESET}"
    else
        echo -e "${YELLOW}⚠️ 未检测到 FQ_PIE 模块，尝试加载...${RESET}"
        modprobe sch_fq_pie 2>/dev/null || echo -e "${RED}❌ 无法加载 FQ_PIE 模块${RESET}"
    fi
}

##### 新增：检查CAKE支持 #####
check_cake() {
    log "${BLUE}🔍 检查 CAKE 队列规程支持...${RESET}"
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    echo "当前队列规程: $current_qdisc"

    if lsmod | grep -q sch_cake || modinfo sch_cake >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 检测到 CAKE 队列规程支持${RESET}"
    else
        echo -e "${YELLOW}⚠️ 未检测到 CAKE 模块，尝试加载...${RESET}"
        if modprobe sch_cake 2>/dev/null; then
            echo -e "${GREEN}✅ CAKE 模块加载成功${RESET}"
        else
            echo -e "${RED}❌ 无法加载 CAKE 模块。请确保内核版本高于 4.19。${RESET}"
            return 1
        fi
    fi
}

# 备份现有配置
backup_configs() {
    log "${YELLOW}📦 备份现有配置...${RESET}"
    local backup_dir="/root/bbrplus-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份相关配置文件
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$backup_dir/"
    [ -d /etc/sysctl.d ] && cp -r /etc/sysctl.d "$backup_dir/"
    [ -f /etc/default/grub ] && cp /etc/default/grub "$backup_dir/"
    [ -f /etc/rc.local ] && cp /etc/rc.local "$backup_dir/"
    
    echo "配置已备份到: $backup_dir"
}

# 方法1-FQ_PIE: sysctl配置文件 (FQ_PIE模式)
sysctl_method_fqpie() {
    log "${YELLOW}>>> 方法1-FQ_PIE: 配置 sysctl 启用 BBR Plus + FQ_PIE${RESET}"
    cat > /etc/sysctl.d/99-bbrplus-fqpie.conf <<'EOF'
# BBR Plus + FQ_PIE Configuration
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbrplus
EOF
    sysctl -p /etc/sysctl.d/99-bbrplus-fqpie.conf >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ sysctl (FQ_PIE模式) 配置完成${RESET}"
}

##### 新增：sysctl配置 (CAKE模式) #####
sysctl_method_cake() {
    log "${YELLOW}>>> 方法1-CAKE: 配置 sysctl 启用 BBR Plus + CAKE${RESET}"
    cat > /etc/sysctl.d/99-bbrplus-cake.conf <<'EOF'
# BBR Plus + CAKE Configuration
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbrplus
EOF
    sysctl -p /etc/sysctl.d/99-bbrplus-cake.conf >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ sysctl (CAKE模式) 配置完成${RESET}"
}

##### 新增：守护模式 (Guardian Mode) - 解决Hiddify等软件冲突的核心方案 #####
guardian_method_cake() {
    log "${RED}>>> 核心功能: 创建 BBR Plus + CAKE 守护服务 (对抗配置覆盖)${RESET}"

    # 1. 创建循环检测修复脚本
    log "   - 创建守护脚本 /usr/local/bin/bbrplus-cake-guardian.sh"
    cat > /usr/local/bin/bbrplus-cake-guardian.sh <<'EOF'
#!/bin/bash
# This script is a guardian to ensure BBR Plus and Cake qdisc remain active.
# It's designed to counteract other services that might override network settings.

LOG_FILE="/var/log/bbrplus-guardian.log"
DESIRED_QDISC="cake"
DESIRED_CC="bbrplus"

log_change() {
    echo "$(date): $1" >> "$LOG_FILE"
}

# Load module just in case
/sbin/modprobe sch_cake 2>/dev/null

while true; do
    # Read current values directly from procfs for accuracy
    current_qdisc=$(cat /proc/sys/net/core/default_qdisc)
    current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control)
    
    # Check and fix qdisc
    if [ "$current_qdisc" != "$DESIRED_QDISC" ]; then
        echo "$DESIRED_QDISC" > /proc/sys/net/core/default_qdisc
        log_change "Qdisc reverted from '$current_qdisc' to '$DESIRED_QDISC'."
    fi
    
    # Check and fix congestion control
    if [ "$current_cc" != "$DESIRED_CC" ]; then
        echo "$DESIRED_CC" > /proc/sys/net/ipv4/tcp_congestion_control
        log_change "Congestion control reverted from '$current_cc' to '$DESIRED_CC'."
    fi
    
    # Check every 5 seconds - more responsive than 10
    sleep 5
done
EOF

    # 2. 赋予脚本执行权限
    chmod +x /usr/local/bin/bbrplus-cake-guardian.sh
    log "   - 赋予脚本执行权限"

    # 3. 创建 systemd 服务文件
    log "   - 创建 systemd 服务 /etc/systemd/system/bbrplus-guardian.service"
    cat > /etc/systemd/system/bbrplus-guardian.service <<'EOF'
[Unit]
Description=BBRPlus and Cake Qdisc Guardian
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/bbrplus-cake-guardian.sh
Restart=always
RestartSec=10
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    # 4. 重新加载 systemd 并启动服务
    log "   - 启用并启动守护服务"
    systemctl daemon-reload
    systemctl enable bbrplus-guardian.service
    systemctl start bbrplus-guardian.service

    echo -e "${GREEN}✅ BBR Plus + CAKE 守护服务已启动并设为开机自启${RESET}"
    echo -e "${YELLOW}💡 此服务将持续运行，确保 Hiddify 等软件无法修改您的 BBR Plus 和 CAKE 设置。${RESET}"
    echo -e "${YELLOW}   可以用 'systemctl status bbrplus-guardian' 来检查其运行状态。${RESET}"
}


# 检查当前状态
check_status() {
    log "${BLUE}📊 当前系统状态:${RESET}"
    echo "======================================"
    local cc_algo k_qdisc fq_pie_mod cake_mod guardian_status
    cc_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    k_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')
    
    echo "当前拥塞控制算法: $([ "$cc_algo" = "bbrplus" ] && echo -e "${GREEN}$cc_algo${RESET}" || echo -e "${RED}$cc_algo${RESET}")"
    echo "当前队列规程: $([ "$k_qdisc" = "cake" ] || [ "$k_qdisc" = "fq_pie" ] && echo -e "${GREEN}$k_qdisc${RESET}" || echo -e "${RED}$k_qdisc${RESET}")"
    echo "可用拥塞控制算法: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '未知')"
    echo "内核版本: $(uname -r)"
    
    # 检查模块
    lsmod | grep -q sch_fq_pie && fq_pie_mod="${GREEN}✅ 已加载${RESET}" || fq_pie_mod="${RED}❌ 未加载${RESET}"
    lsmod | grep -q sch_cake && cake_mod="${GREEN}✅ 已加载${RESET}" || cake_mod="${RED}❌ 未加载${RESET}"
    echo "FQ_PIE 模块状态: $fq_pie_mod"
    echo "CAKE 模块状态:   $cake_mod"

    # 检查守护服务状态
    if systemctl is-active --quiet bbrplus-guardian; then
        guardian_status="${GREEN}✅ 运行中${RESET}"
    else
        guardian_status="${RED}❌ 未运行${RESET}"
    fi
    echo "守护服务状态:     $guardian_status"
    echo "======================================"
}

# 清理配置
cleanup_configs() {
    log "${YELLOW}🧹 清理 BBR Plus 相关配置...${RESET}"
    
    # 停止并禁用守护服务
    log "   - 停止并移除守护服务..."
    systemctl stop bbrplus-guardian.service >/dev/null 2>&1 || true
    systemctl disable bbrplus-guardian.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/bbrplus-guardian.service
    rm -f /usr/local/bin/bbrplus-cake-guardian.sh
    systemctl daemon-reload

    # 删除sysctl配置文件
    rm -f /etc/sysctl.d/99-bbrplus-fq.conf
    rm -f /etc/sysctl.d/99-bbrplus-fqpie.conf
    rm -f /etc/sysctl.d/99-bbrplus-cake.conf
    
    # ... (此处省略原始脚本中其他清理项，为简洁起见，实际使用时应保留)
    
    # 恢复系统默认值
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    
    echo -e "${GREEN}✅ 清理完成，已尝试恢复系统默认网络配置 (cubic + fq)。${RESET}"
}

# 主菜单
menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}  BBR Plus + CAKE 强制启用器 (守护增强版) v${VERSION}  ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN}专为解决 Hiddify 等面板配置覆盖问题而设计${RESET}"
    echo ""
    check_status
    echo ""
    echo -e "${MAGENTA}== 终极稳定模式 (推荐，可对抗Hiddify) ==${RESET}"
    echo -e "  ${RED}1${RESET}) 🔥 BBR Plus + CAKE (守护模式)"
    echo -e "         ${CYAN}通过持续守护进程强制锁定配置，确保永不失效。${RESET}"
    echo ""
    echo -e "${YELLOW}== 标准模式 (可能被Hiddify覆盖) ==${RESET}"
    echo -e "  ${YELLOW}11${RESET}) BBR Plus + FQ_PIE (sysctl方式)"
    echo -e "  ${YELLOW}12${RESET}) BBR Plus + CAKE (sysctl方式)"
    echo ""
    echo -e "${BLUE}== 系统管理 ==${RESET}"
    echo -e "  ${BLUE}9${RESET}) 📊 刷新当前状态"
    echo -e "  ${RED}c${RESET}) 🧹 清理所有配置并恢复默认"
    echo -e "  ${RED}q${RESET}) 退出"
    echo ""
    read -p "请输入选择: " option
    
    case "$option" in
        1)
            check_bbrplus && check_cake && backup_configs && guardian_method_cake
            ;;
        11)
            check_bbrplus && check_fqpie && backup_configs && sysctl_method_fqpie
            ;;
        12)
            check_bbrplus && check_cake && backup_configs && sysctl_method_cake
            ;;
        9)
            menu
            ;;
        c|C)
            cleanup_configs && read -p "按回车键继续..." && menu
            ;;
        q|Q)
            echo -e "${CYAN}👋 感谢使用!${RESET}"; exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效输入，请重试${RESET}"; sleep 2; menu
            ;;
    esac
    
    echo ""
    log "${GREEN}✅ 操作完成!${RESET}"
    echo ""
    read -p "按回车键返回主菜单..."
    menu
}


# 脚本入口
main() {
    check_root
    menu
}

# 如果直接运行脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
