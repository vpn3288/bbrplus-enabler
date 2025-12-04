#!/bin/bash
#
# BBR Plus + CAKE 强制启用器 - 终极优化版 v5.0
# 集成守护模式，专为对抗 Hiddify 等面板的配置覆盖问题
#
# 优化重点：实用性 > 复杂性
#
# 使用方法:
# bash <(curl -fsSL https://raw.githubusercontent.com/your-repo/ultimate-script.sh)
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
VERSION="5.0.0-Ultimate"

# 配置常量
GUARDIAN_SCRIPT="/usr/local/bin/bbrplus-cake-guardian.sh"
GUARDIAN_SERVICE="bbrplus-guardian.service"
GUARDIAN_CONFIG="/etc/bbrplus-guardian.conf"
DESIRED_CC="bbrplus"
DESIRED_QDISC="cake"

# 统一输出带时间戳的日志
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
    log "${BLUE}🔍 检查 ${DESIRED_CC} 内核支持...${RESET}"
    if ! sysctl net.ipv4.tcp_available_congestion_control | grep -q "${DESIRED_CC}"; then
        echo -e "${RED}❌ 当前系统未检测到 ${DESIRED_CC} 支持${RESET}"
        echo -e "${YELLOW}💡 请确保已安装支持 ${DESIRED_CC} 的内核 (如 xanmod, liquorix)${RESET}"
        read -p "是否继续配置？ (y/N): " continue_setup
        if [[ ! $continue_setup =~ ^[Yy] ]]; then
            return 1
        fi
    else
        echo -e "${GREEN}✅ 检测到 ${DESIRED_CC} 内核支持${RESET}"
    fi
}

# 检查CAKE支持
check_cake() {
    log "${BLUE}🔍 检查 ${DESIRED_QDISC} 队列规程支持...${RESET}"
    if modinfo sch_cake >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 检测到 ${DESIRED_QDISC} 队列规程支持${RESET}"
        return 0
    else
        echo -e "${YELLOW}⚠️ 未检测到 ${DESIRED_QDISC} 模块。CAKE 通常需要内核 4.19+${RESET}"
        read -p "守护模式需要 ${DESIRED_QDISC}，是否尝试加载模块？(Y/n): " load_cake
        if [[ ! "$load_cake" =~ ^[Nn]$ ]]; then
            log "   - 尝试加载 ${DESIRED_QDISC} 模块..."
            if modprobe sch_cake 2>/dev/null; then
                # 二次验证
                sleep 1
                if modinfo sch_cake >/dev/null 2>&1; then
                    echo -e "${GREEN}✅ ${DESIRED_QDISC} 模块加载成功!${RESET}"
                    return 0
                fi
            fi
            echo -e "${RED}❌ 无法加载 ${DESIRED_QDISC} 模块，守护模式无法继续。${RESET}"
            return 1
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
        cp -r /etc/sysctl.d "$backup_dir/" 2>/dev/null || true
    fi
    cp /etc/sysctl.conf "$backup_dir/" 2>/dev/null || true
    echo -e "配置已备份到: ${CYAN}$backup_dir${RESET}"
}

# 创建配置文件
create_config() {
    log "   - 创建配置文件 ${GUARDIAN_CONFIG}"
    cat > "$GUARDIAN_CONFIG" <<EOF
# BBRPlus Guardian 配置文件
# 检查间隔（秒）- 推荐 30-60 秒，太短会占用资源
GUARD_INTERVAL=30

# 拥塞控制算法
DESIRED_CC=bbrplus

# 队列规程
DESIRED_QDISC=cake

# 是否应用到所有网络接口（yes/no）
# 注意：启用后会对所有接口应用 CAKE，可能影响某些特殊网络配置
APPLY_TO_INTERFACES=no
EOF
}

# BBR Plus + CAKE 守护模式（终极优化版）
guardian_method() {
    log "${MAGENTA}🔥 启用 BBR Plus + CAKE 守护模式 (终极优化版)...${RESET}"

    # 1. 创建配置文件
    create_config

    # 2. 创建守护脚本
    log "   - 创建守护脚本 ${GUARDIAN_SCRIPT}"
    cat > "$GUARDIAN_SCRIPT" <<'EOF'
#!/bin/bash
# BBRPlus & Cake Guardian Script (Ultimate Edition)
# Ensures BBR Plus and Cake are always active, counteracting overrides.

# 加载配置文件
CONFIG_FILE="/etc/bbrplus-guardian.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # 默认值
    GUARD_INTERVAL=30
    DESIRED_CC="bbrplus"
    DESIRED_QDISC="cake"
    APPLY_TO_INTERFACES="no"
fi

# 确保模块已加载
/sbin/modprobe sch_cake 2>/dev/null

# 应用 CAKE 到网络接口的函数
apply_cake_to_interfaces() {
    if [ "$APPLY_TO_INTERFACES" = "yes" ]; then
        for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
            # 检查接口是否 UP
            if ip link show "$iface" | grep -q "state UP"; then
                # 检查当前 qdisc
                current_qdisc=$(tc qdisc show dev "$iface" | head -1 | awk '{print $2}')
                if [ "$current_qdisc" != "cake" ]; then
                    if tc qdisc replace dev "$iface" root cake bandwidth 1Gbit 2>/dev/null; then
                        logger -t BBRPlus-Guardian "接口 $iface: 应用 CAKE 成功"
                    fi
                fi
            fi
        done
    fi
}

# 初次应用接口配置
apply_cake_to_interfaces

# 主循环
while true; do
    # 检查 sysctl QDisc
    CURRENT_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [[ "$CURRENT_QDISC" != "$DESIRED_QDISC" ]]; then
        sysctl -w net.core.default_qdisc="$DESIRED_QDISC" >/dev/null 2>&1
        logger -t BBRPlus-Guardian "QDisc 恢复: 从 $CURRENT_QDISC 强制恢复到 $DESIRED_QDISC"
    fi

    # 检查拥塞控制
    CURRENT_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    if [[ "$CURRENT_CC" != "$DESIRED_CC" ]]; then
        sysctl -w net.ipv4.tcp_congestion_control="$DESIRED_CC" >/dev/null 2>&1
        logger -t BBRPlus-Guardian "CC 恢复: 从 $CURRENT_CC 强制恢复到 $DESIRED_CC"
    fi

    # 应用接口配置（如果启用）
    apply_cake_to_interfaces

    sleep "$GUARD_INTERVAL"
done
EOF

    # 3. 赋予脚本执行权限
    chmod +x "$GUARDIAN_SCRIPT"
    log "   - 赋予脚本执行权限"

    # 4. 创建 systemd 服务文件
    log "   - 创建 systemd 服务 /etc/systemd/system/${GUARDIAN_SERVICE}"
    cat > /etc/systemd/system/"$GUARDIAN_SERVICE" <<EOF
[Unit]
Description=BBRPlus and Cake Qdisc Guardian (Counteracts Panel Overrides)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${GUARDIAN_SCRIPT}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # 5. 重新加载 systemd 并启动服务
    log "   - 启用并启动守护服务"
    systemctl daemon-reload
    systemctl enable "$GUARDIAN_SERVICE"
    systemctl start "$GUARDIAN_SERVICE"

    echo -e "${GREEN}✅ ${DESIRED_CC} + ${DESIRED_QDISC} 守护服务已启动并设为开机自启${RESET}"
    echo -e "${YELLOW}💡 配置文件: ${CYAN}${GUARDIAN_CONFIG}${RESET}"
    echo -e "${YELLOW}💡 查看日志: ${CYAN}journalctl -u ${GUARDIAN_SERVICE} -f${RESET}"
    echo -e "${YELLOW}💡 修改配置后需要执行: ${CYAN}systemctl restart ${GUARDIAN_SERVICE}${RESET}"
}

# 检查当前状态（增强版）
check_status() {
    log "${BLUE}📊 当前系统状态:${RESET}"
    echo "=================================================="
    local cc_algo k_qdisc guardian_status
    cc_algo=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')
    k_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')

    echo -n "拥塞控制 (${DESIRED_CC}): "
    [ "$cc_algo" = "${DESIRED_CC}" ] && echo -e "${GREEN}$cc_algo ✓${RESET}" || echo -e "${RED}$cc_algo ✗${RESET}"
    echo -n "队列规程 (${DESIRED_QDISC}):   "
    [ "$k_qdisc" = "${DESIRED_QDISC}" ] && echo -e "${GREEN}$k_qdisc ✓${RESET}" || echo -e "${RED}$k_qdisc ✗${RESET}"

    if systemctl is-active --quiet "$GUARDIAN_SERVICE"; then
        local restart_count=$(systemctl show -p NRestarts "$GUARDIAN_SERVICE" | cut -d'=' -f2)
        local uptime=$(systemctl show -p ActiveEnterTimestamp "$GUARDIAN_SERVICE" | cut -d'=' -f2)
        guardian_status="${GREEN}✅ 运行中${RESET}"
        [ "$restart_count" -gt 0 ] && guardian_status="$guardian_status ${YELLOW}(重启 $restart_count 次)${RESET}"
    else
        guardian_status="${RED}❌ 未运行${RESET}"
    fi
    echo "守护服务:              $guardian_status"
    echo "内核版本:              $(uname -r)"
    
    # 显示配置
    if [ -f "$GUARDIAN_CONFIG" ]; then
        local interval=$(grep "^GUARD_INTERVAL=" "$GUARDIAN_CONFIG" 2>/dev/null | cut -d'=' -f2)
        local apply_iface=$(grep "^APPLY_TO_INTERFACES=" "$GUARDIAN_CONFIG" 2>/dev/null | cut -d'=' -f2)
        echo "检查间隔:              ${interval:-30} 秒"
        echo "接口级应用:            ${apply_iface:-no}"
    fi
    echo "=================================================="
}

# 编辑配置文件
edit_config() {
    if [ ! -f "$GUARDIAN_CONFIG" ]; then
        echo -e "${RED}❌ 配置文件不存在，请先启用守护模式${RESET}"
        return 1
    fi
    
    echo -e "${CYAN}当前配置:${RESET}"
    cat "$GUARDIAN_CONFIG"
    echo ""
    echo -e "${YELLOW}可调整参数说明:${RESET}"
    echo "  GUARD_INTERVAL: 检查间隔(秒)，推荐 30-60"
    echo "  APPLY_TO_INTERFACES: 是否应用到所有网络接口 (yes/no)"
    echo "    ${RED}警告: 启用接口级应用可能影响某些网络配置${RESET}"
    echo ""
    read -p "是否使用编辑器编辑配置？(y/N): " edit_choice
    
    if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
        ${EDITOR:-nano} "$GUARDIAN_CONFIG"
        echo -e "${YELLOW}配置已修改，重启服务生效...${RESET}"
        systemctl restart "$GUARDIAN_SERVICE"
        echo -e "${GREEN}✅ 服务已重启${RESET}"
    fi
}

# 查看统计信息
show_stats() {
    if ! systemctl is-active --quiet "$GUARDIAN_SERVICE"; then
        echo -e "${RED}❌ 守护服务未运行${RESET}"
        return 1
    fi
    
    echo -e "${CYAN}📊 守护服务统计信息 (最近1小时):${RESET}"
    echo "=================================================="
    
    # 统计恢复次数
    local cc_recoveries=$(journalctl -u "$GUARDIAN_SERVICE" --since "1 hour ago" 2>/dev/null | grep -c "CC 恢复" || echo "0")
    local qdisc_recoveries=$(journalctl -u "$GUARDIAN_SERVICE" --since "1 hour ago" 2>/dev/null | grep -c "QDisc 恢复" || echo "0")
    
    echo "拥塞控制恢复次数:      $cc_recoveries"
    echo "队列规程恢复次数:      $qdisc_recoveries"
    
    if [ "$cc_recoveries" -gt 0 ] || [ "$qdisc_recoveries" -gt 0 ]; then
        echo -e "${YELLOW}检测到配置被修改 $((cc_recoveries + qdisc_recoveries)) 次${RESET}"
        echo -e "${YELLOW}这说明守护服务正在有效对抗配置覆盖！${RESET}"
    else
        echo -e "${GREEN}配置稳定，无需恢复${RESET}"
    fi
    echo "=================================================="
}

# 清理配置
cleanup_configs() {
    log "${YELLOW}🧹 清理所有 BBR Plus 相关配置...${RESET}"
    
    # 停止并禁用守护服务
    log "   - 停止并移除守护服务..."
    systemctl stop "$GUARDIAN_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$GUARDIAN_SERVICE" >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/"$GUARDIAN_SERVICE"
    rm -f "$GUARDIAN_SCRIPT"
    rm -f "$GUARDIAN_CONFIG"
    systemctl daemon-reload >/dev/null 2>&1

    # 删除所有可能的 sysctl 配置文件
    rm -f /etc/sysctl.d/99-bbrplus*.conf
    
    # 恢复系统默认值
    log "   - 尝试恢复系统默认网络配置 (cubic + fq)..."
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1 || true
    
    echo -e "${GREEN}✅ 清理完成。${RESET}"
    echo -e "${YELLOW}💡 建议重启系统以确保所有网络接口的配置完全恢复。${RESET}"
}

# 主菜单
menu() {
    clear
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${GREEN}  BBR Plus + CAKE 强制启用器 (终极优化版) v${VERSION}  ${RESET}"
    echo -e "${GREEN}======================================================${RESET}"
    echo -e "${CYAN}专为解决 Hiddify 等面板配置覆盖问题而设计${RESET}"
    echo ""
    check_status
    echo ""
    echo -e "${MAGENTA}== 守护模式 ==${RESET}"
    echo -e "  ${GREEN}1)${RESET} 🔥 启用 ${DESIRED_CC} + ${DESIRED_QDISC} 守护模式"
    echo -e "  ${BLUE}2)${RESET} ⚙️  编辑守护配置 (调整检查间隔、接口应用等)"
    echo ""
    echo -e "${BLUE}== 监控与管理 ==${RESET}"
    echo -e "  ${BLUE}3)${RESET} 📊 查看统计信息 (恢复次数、运行状态)"
    echo -e "  ${BLUE}4)${RESET} 📜 查看实时日志 (journalctl -f)"
    echo -e "  ${BLUE}9)${RESET} 🔄 刷新当前状态"
    echo ""
    echo -e "${RED}== 系统管理 ==${RESET}"
    echo -e "  ${RED}c)${RESET} 🧹 清理所有配置并恢复默认"
    echo -e "  ${RED}q)${RESET} 退出脚本"
    echo ""
    read -p "请输入您的选择: " option
    
    case "$option" in
        1)
            check_bbrplus && check_cake && backup_configs && guardian_method
            ;;
        2)
            edit_config
            ;;
        3)
            show_stats
            ;;
        4)
            echo ""
            log "${CYAN}📜 正在获取守护服务实时日志... (按 Ctrl+C 退出)${RESET}"
            echo ""
            journalctl -u "$GUARDIAN_SERVICE" -f --since "10 minutes ago"
            ;;
        9)
            # 刷新状态
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
            echo -e "${RED}❌ 无效输入，请重试${RESET}"; sleep 1;
            ;;
    esac
    
    echo ""
    read -p "按任意键返回主菜单..."
    menu
}

# 脚本入口
main() {
    check_root
    # 检查并尝试启动已存在的守护服务
    if [ -f /etc/systemd/system/"$GUARDIAN_SERVICE" ]; then
        if ! systemctl is-active --quiet "$GUARDIAN_SERVICE"; then
            log "${YELLOW}检测到守护服务文件存在但未运行，尝试启动...${RESET}"
            systemctl start "$GUARDIAN_SERVICE" >/dev/null 2>&1 || true
        fi
    fi
    menu
}

# 如果直接运行脚本
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
