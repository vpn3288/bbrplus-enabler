#!/bin/bash
#
# BBR Plus + CAKE 强制启用器 - 守护增强版 v3.1
# 集成守护模式，专为对抗 Hiddify 等面板的配置覆盖问题
#
# 由 Gemini 根据用户需求完善
#
# 使用方法:
# bash <(curl -fsSL https://raw.githubusercontent.com/vpn3288/bbrplus-enabler/main/enable-bbrplus.sh)
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
VERSION="3.1.0-Guardian"

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
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "bbrplus"; then
        echo -e "${RED}❌ 当前系统未检测到 BBR Plus 支持${RESET}"
        echo -e "${YELLOW}💡 请确保已安装支持 BBR Plus 的内核 (如 xanmod, liquorix)${RESET}"
        read -p "是否继续配置？ (y/N): " continue_setup
        if [[ ! $continue_setup =~ ^[Yy] ]]; then
            exit 1
        fi
    else
        echo -e "${GREEN}✅ 检测到 BBR Plus 内核支持${RESET}"
    fi
}

# 检查CAKE支持
check_cake() {
    log "${BLUE}🔍 检查 CAKE 队列规程支持...${RESET}"
    if modinfo sch_cake >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 检测到 CAKE 队列规程支持${RESET}"
    else
        echo -e "${YELLOW}⚠️ 未检测到 CAKE 模块。CAKE 通常需要内核 4.19+${RESET}"
        read -p "守护模式需要 CAKE，是否尝试加载模块？(Y/n): " load_cake
        if [[ ! "$load_cake" =~ ^[Nn]$ ]]; then
            if modprobe sch_cake; then
                 echo -e "${GREEN}✅ CAKE 模块加载成功!${RESET}"
            else
                 echo -e "${RED}❌ 无法加载 CAKE 模块，守护模式无法继续。${RESET}"
                 return 1
            fi
        else
            return 1
        fi
    fi
}

# 备份现有配置
backup_configs() {
    log "${YELLOW}📦 备份现有 sysctl 配置...${RESET}"
    local backup_dir="/root/bbrplus-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    if [ -d /etc/sysctl.d ]; then
        cp -r /etc/sysctl.d "$backup_dir/"
        echo "配置已备份到: $backup_dir"
    fi
}

# BBR Plus + CAKE 守护模式
guardian_method() {
    log "${MAGENTA}🔥 启用 BBR Plus + CAKE 守护模式 (对抗配置覆盖)...${RESET}"

    # 1. 创建守护脚本
    log "   - 创建守护脚本 /usr/local/bin/bbrplus-cake-guardian.sh"
    cat > /usr/local/bin/bbrplus-cake-guardian.sh <<'EOF'
#!/bin/bash
# BBRPlus & Cake Guardian Script
# Ensures BBR Plus and Cake are always active, counteracting overrides.

DESIRED_QDISC="cake"
DESIRED_CC="bbrplus"

# Ensure module is loaded
/sbin/modprobe sch_cake 2>/dev/null

while true; do
    if [[ "$(sysctl -n net.core.default_qdisc)" != "$DESIRED_QDISC" ]]; then
        sysctl -w net.core.default_qdisc="$DESIRED_QDISC" >/dev/null 2>&1
    fi
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "$DESIRED_CC" ]]; then
        sysctl -w net.ipv4.tcp_congestion_control="$DESIRED_CC" >/dev/null 2>&1
    fi
    sleep 10
done
EOF

    # 2. 赋予脚本执行权限
    chmod +x /usr/local/bin/bbrplus-cake-guardian.sh
    log "   - 赋予脚本执行权限"

    # 3. 创建 systemd 服务文件
    log "   - 创建 systemd 服务 /etc/systemd/system/bbrplus-guardian.service"
    cat > /etc/systemd/system/bbrplus-guardian.service <<'EOF'
[Unit]
Description=BBRPlus and Cake Qdisc Guardian (to counteract Hiddify overrides)
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
    echo -e "${YELLOW}💡 此服务将持续运行，确保 Hiddify 等软件无法修改您的网络设置。${RESET}"
}

# 检查当前状态
check_status() {
    log "${BLUE}📊 当前系统状态:${RESET}"
    echo "=================================================="
    local cc_algo k_qdisc guardian_status
    cc_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    k_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')

    echo -n "拥塞控制: "
    [ "$cc_algo" = "bbrplus" ] && echo -e "${GREEN}$cc_algo${RESET}" || echo -e "${RED}$cc_algo${RESET}"
    echo -n "队列规程:   "
    [ "$k_qdisc" = "cake" ] && echo -e "${GREEN}$k_qdisc${RESET}" || echo -e "${RED}$k_qdisc${RESET}"

    if systemctl is-active --quiet bbrplus-guardian.service; then
        guardian_status="${GREEN}✅ 运行中${RESET}"
    else
        guardian_status="${RED}❌ 未运行${RESET}"
    fi
    echo "守护服务:   $guardian_status"
    echo "内核版本:   $(uname -r)"
    echo "=================================================="
}

# 清理配置
cleanup_configs() {
    log "${YELLOW}🧹 清理所有 BBR Plus 相关配置...${RESET}"
    
    # 停止并禁用守护服务
    log "   - 停止并移除守护服务..."
    systemctl stop bbrplus-guardian.service >/dev/null 2>&1 || true
    systemctl disable bbrplus-guardian.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/bbrplus-guardian.service
    rm -f /usr/local/bin/bbrplus-cake-guardian.sh
    systemctl daemon-reload >/dev/null 2>&1

    # 删除所有可能的 sysctl 配置文件
    rm -f /etc/sysctl.d/99-bbrplus*.conf
    
    # 恢复系统默认值
    log "   - 尝试恢复系统默认网络配置 (cubic + fq)..."
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    
    echo -e "${GREEN}✅ 清理完成。${RESET}"
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
    echo -e "${MAGENTA}== 终极守护模式 (强烈推荐，对抗Hiddify) ==${RESET}"
    echo -e "  ${GREEN}1)${RESET} 🔥 启用 BBR Plus + CAKE 守护模式"
    echo -e "         ${CYAN}通过后台服务持续强制锁定配置，确保永不失效。${RESET}"
    echo ""
    echo -e "${BLUE}== 系统管理 ==${RESET}"
    echo -e "  ${BLUE}9)${RESET} 📊 刷新当前状态"
    echo -e "  ${RED}c)${RESET} 🧹 清理所有配置并恢复默认"
    echo -e "  ${RED}q)${RESET} 退出脚本"
    echo ""
    read -p "请输入您的选择: " option
    
    case "$option" in
        1)
            check_bbrplus && check_cake && backup_configs && guardian_method
            ;;
        9)
            # 只是为了刷新状态，不需要任何操作，因为菜单会重新调用check_status
            ;;
        c|C)
            read -p "确定要清理所有配置吗? 这会停止守护服务并恢复系统默认值 (y/N): " confirm_cleanup
            if [[ "$confirm_cleanup" =~ ^[Yy]$ ]]; then
                cleanup_configs
            else
                echo "操作已取消。"
            fi
            ;;
        q|Q)
            echo -e "${CYAN}👋 感谢使用!${RESET}"; exit 0
            ;;
        *)
            echo -e "${RED}❌ 无效输入，请重试${RESET}"; sleep 2;
            ;;
    esac
    
    echo ""
    read -p "按任意键返回主菜单..."
    menu
}

# 脚本入口
main() {
    check_root
    detect_os
    # 初始检查，如果守护服务已存在但未运行，尝试启动它
    if [ -f /etc/systemd/system/bbrplus-guardian.service ] && ! systemctl is-active --quiet bbrplus-guardian.service; then
        log "${YELLOW}检测到守护服务存在但未运行，尝试启动...${RESET}"
        systemctl start bbrplus-guardian.service >/dev/null 2>&1 || true
    fi
    menu
}

# 如果直接运行脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
