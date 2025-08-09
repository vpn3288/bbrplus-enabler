#!/bin/bash
#
# BBR Plus 强制启用器 - 增强版
# 支持多种启动方式，确保BBR Plus在任何情况下都能正常启用
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
RESET="\033[0m"

# 脚本版本
VERSION="2.0.0"

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
    
    if ! echo "$algo" | grep -qw "bbrplus\|bbr2\|bbrplus2"; then
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

# 备份现有配置
backup_configs() {
    log "${YELLOW}📦 备份现有配置...${RESET}"
    local backup_dir="/root/bbrplus-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份相关配置文件
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$backup_dir/"
    [ -f /etc/sysctl.d/99-bbrplus.conf ] && cp /etc/sysctl.d/99-bbrplus.conf "$backup_dir/"
    [ -f /etc/default/grub ] && cp /etc/default/grub "$backup_dir/"
    [ -f /etc/rc.local ] && cp /etc/rc.local "$backup_dir/"
    
    echo "配置已备份到: $backup_dir"
}

# 方法1: sysctl配置文件
sysctl_method() {
    log "${YELLOW}>>> 方法1: 配置 sysctl 启用 BBR Plus${RESET}"
    
    # 创建专用配置文件
    cat > /etc/sysctl.d/99-bbrplus.conf <<'EOF'
# BBR Plus Configuration
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbrplus

# 额外的网络优化参数
net.core.rmem_default = 1048576
net.core.rmem_max = 16777216
net.core.wmem_default = 65536
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_rmem = 4096 1048576 2097152
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_collapse = 0
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    # 同时写入主配置文件作为后备
    if ! grep -q "net.ipv4.tcp_congestion_control.*bbrplus" /etc/sysctl.conf 2>/dev/null; then
        echo "" >> /etc/sysctl.conf
        echo "# BBR Plus - Added by enable script" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbrplus" >> /etc/sysctl.conf
    fi
    
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ sysctl 配置完成${RESET}"
}

# 方法2: systemd 服务 (增强版)
systemd_method() {
    log "${YELLOW}>>> 方法2: 创建 systemd 启动服务${RESET}"
    
    cat > /etc/systemd/system/force-bbrplus.service <<'EOF'
[Unit]
Description=Force Enable BBR Plus TCP Congestion Control
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 5
ExecStart=/bin/bash -c 'echo fq > /proc/sys/net/core/default_qdisc && echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control'
ExecStart=/sbin/sysctl -w net.core.default_qdisc=fq
ExecStart=/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbrplus
TimeoutStartSec=30
Restart=no

[Install]
WantedBy=multi-user.target network-online.target
EOF

    systemctl daemon-reload
    systemctl enable force-bbrplus.service
    systemctl start force-bbrplus.service >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ systemd 服务配置完成${RESET}"
}

# 方法3: GRUB启动参数
grub_method() {
    log "${YELLOW}>>> 方法3: 修改 GRUB 启动参数${RESET}"
    
    if [ -f /etc/default/grub ]; then
        # 备份grub配置
        cp /etc/default/grub /etc/default/grub.bbrplus.bak
        
        # 移除现有的BBR相关参数
        sed -i 's/net\.core\.default_qdisc=[^ ]* //g' /etc/default/grub
        sed -i 's/net\.ipv4\.tcp_congestion_control=[^ ]* //g' /etc/default/grub
        
        # 添加BBR Plus参数
        if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
            sed -i 's/^GRUB_CMDLINE_LINUX="/&net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbrplus /' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX="net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbrplus"' >> /etc/default/grub
        fi
        
        # 更新GRUB配置
        if command -v update-grub >/dev/null 2>&1; then
            update-grub >/dev/null 2>&1
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
        elif command -v grub2-mkconfig >/dev/null 2>&1; then
            grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
        fi
        
        echo -e "${GREEN}✅ GRUB 配置完成${RESET}"
    else
        echo -e "${RED}⚠️ 未检测到 GRUB 配置，跳过此方法${RESET}"
    fi
}

# 方法4: rc.local 兼容方式 (增强版)
rclocal_method() {
    log "${YELLOW}>>> 方法4: 配置 rc.local 开机启动${RESET}"
    
    # 创建或修改 rc.local
    cat > /etc/rc.local <<'EOF'
#!/bin/bash
# BBR Plus force enable script
# This file is executed at the end of each multiuser runlevel

# 等待网络就绪
sleep 3

# 强制设置BBR Plus
echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || true
echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true

# 使用sysctl命令作为后备
/sbin/sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbrplus >/dev/null 2>&1 || true

# 记录日志
echo "$(date): BBR Plus force enabled" >> /var/log/bbrplus.log

exit 0
EOF
    
    chmod +x /etc/rc.local
    
    # 如果系统使用systemd，确保rc-local服务启用
    if systemctl list-unit-files | grep -q rc-local; then
        systemctl enable rc-local >/dev/null 2>&1 || true
    fi
    
    echo -e "${GREEN}✅ rc.local 配置完成${RESET}"
}

# 方法5: crontab定时任务
crontab_method() {
    log "${YELLOW}>>> 方法5: 创建 crontab 定时检查任务${RESET}"
    
    # 创建检查脚本
    cat > /usr/local/bin/check-bbrplus.sh <<'EOF'
#!/bin/bash
CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$CURRENT" != "bbrplus" ]; then
    echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || true
    echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbrplus >/dev/null 2>&1 || true
    echo "$(date): BBR Plus restored from $CURRENT" >> /var/log/bbrplus.log
fi
EOF
    
    chmod +x /usr/local/bin/check-bbrplus.sh
    
    # 添加到crontab (每分钟检查一次)
    (crontab -l 2>/dev/null | grep -v check-bbrplus; echo "*/1 * * * * /usr/local/bin/check-bbrplus.sh") | crontab -
    
    echo -e "${GREEN}✅ crontab 定时任务配置完成${RESET}"
}

# 方法6: 内核模块参数 (如果适用)
kernel_module_method() {
    log "${YELLOW}>>> 方法6: 配置内核模块参数${RESET}"
    
    # 创建模块参数文件
    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/bbrplus.conf <<'EOF'
# BBR Plus kernel module options
options tcp_bbrplus enabled=1
EOF
    
    # 更新initramfs
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u >/dev/null 2>&1 || true
    elif command -v dracut >/dev/null 2>&1; then
        dracut -f >/dev/null 2>&1 || true
    fi
    
    echo -e "${GREEN}✅ 内核模块参数配置完成${RESET}"
}

# 方法7: 直接修改proc文件系统 (立即生效)
proc_method() {
    log "${YELLOW}>>> 方法7: 直接修改 proc 文件系统 (立即生效)${RESET}"
    
    # 立即设置
    echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || true
    echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    
    echo -e "${GREEN}✅ proc 文件系统修改完成 (立即生效)${RESET}"
}

# 全部方法
all_methods() {
    log "${CYAN}🚀 启用所有方法 (推荐)${RESET}"
    proc_method
    sysctl_method
    systemd_method
    grub_method
    rclocal_method
    crontab_method
    kernel_module_method
}

# 检查当前状态
check_status() {
    log "${BLUE}📊 当前系统状态:${RESET}"
    echo "======================================"
    echo "当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
    echo "当前队列规程: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo '未知')"
    echo "可用拥塞控制算法: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo '未知')"
    echo "内核版本: $(uname -r)"
    echo "系统信息: $OS $OS_VERSION"
    echo "======================================"
}

# 清理配置
cleanup_configs() {
    log "${YELLOW}🧹 清理 BBR Plus 相关配置...${RESET}"
    
    # 删除配置文件
    rm -f /etc/sysctl.d/99-bbrplus.conf
    
    # 删除systemd服务
    systemctl stop force-bbrplus.service >/dev/null 2>&1 || true
    systemctl disable force-bbrplus.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/force-bbrplus.service
    systemctl daemon-reload
    
    # 清理grub配置
    if [ -f /etc/default/grub.bbrplus.bak ]; then
        mv /etc/default/grub.bbrplus.bak /etc/default/grub
        if command -v update-grub >/dev/null 2>&1; then
            update-grub >/dev/null 2>&1
        fi
    fi
    
    # 删除rc.local中的BBR Plus配置
    if [ -f /etc/rc.local ]; then
        sed -i '/BBR Plus/,/exit 0/d' /etc/rc.local
        echo "exit 0" >> /etc/rc.local
    fi
    
    # 删除crontab任务
    crontab -l 2>/dev/null | grep -v check-bbrplus | crontab - || true
    rm -f /usr/local/bin/check-bbrplus.sh
    
    # 删除模块配置
    rm -f /etc/modprobe.d/bbrplus.conf
    
    # 删除日志
    rm -f /var/log/bbrplus.log
    
    echo -e "${GREEN}✅ 清理完成${RESET}"
}

# 主菜单
menu() {
    clear
    echo -e "${GREEN}=========================================${RESET}"
    echo -e "${GREEN}    BBR Plus 强制启用器 v${VERSION}    ${RESET}"
    echo -e "${GREEN}=========================================${RESET}"
    echo ""
    detect_os
    check_status
    echo ""
    echo -e "${CYAN}请选择操作:${RESET}"
    echo -e "  ${YELLOW}1${RESET}) 仅使用 sysctl 配置"
    echo -e "  ${YELLOW}2${RESET}) 使用 systemd 启动服务"
    echo -e "  ${YELLOW}3${RESET}) 修改 GRUB 启动参数"
    echo -e "  ${YELLOW}4${RESET}) 配置 rc.local 启动"
    echo -e "  ${YELLOW}5${RESET}) 配置 crontab 定时检查"
    echo -e "  ${YELLOW}6${RESET}) 配置内核模块参数"
    echo -e "  ${YELLOW}7${RESET}) 直接修改 proc 文件系统 (立即生效)"
    echo -e "  ${GREEN}8${RESET}) 🚀 一键全部启用 (推荐)"
    echo -e "  ${BLUE}9${RESET}) 📊 检查当前状态"
    echo -e "  ${RED}c${RESET}) 🧹 清理所有 BBR Plus 配置"
    echo -e "  ${RED}q${RESET}) 退出"
    echo ""
    read -p "请输入选择 (1-9/c/q): " option
    
    case "$option" in
        1) check_bbrplus && backup_configs && sysctl_method ;;
        2) check_bbrplus && backup_configs && systemd_method ;;
        3) check_bbrplus && backup_configs && grub_method ;;
        4) check_bbrplus && backup_configs && rclocal_method ;;
        5) check_bbrplus && backup_configs && crontab_method ;;
        6) check_bbrplus && backup_configs && kernel_module_method ;;
        7) check_bbrplus && proc_method ;;
        8) check_bbrplus && backup_configs && all_methods ;;
        9) check_status && read -p "按回车键继续..." && menu ;;
        c|C) cleanup_configs && read -p "按回车键继续..." && menu ;;
        q|Q) echo -e "${CYAN}👋 感谢使用 BBR Plus 启用器!${RESET}"; exit 0 ;;
        *) echo -e "${RED}❌ 无效输入，请重试${RESET}"; sleep 2; menu ;;
    esac
    
    echo ""
    log "${GREEN}✅ 操作完成!${RESET}"
    echo ""
    echo -e "${CYAN}当前状态:${RESET}"
    echo "拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "队列规程: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo ""
    echo -e "${YELLOW}💡 提示:${RESET}"
    echo "   - 某些配置可能需要重启系统才能完全生效"
    echo "   - 建议执行 'reboot' 重启系统"
    echo "   - 重启后可以再次运行脚本检查状态"
    echo ""
    read -p "是否现在重启系统? (y/N): " reboot_now
    if [[ $reboot_now =~ ^[Yy] ]]; then
        log "${YELLOW}🔄 正在重启系统...${RESET}"
        reboot
    else
        read -p "按回车键返回菜单..." 
        menu
    fi
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
