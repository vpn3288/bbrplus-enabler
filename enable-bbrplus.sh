#!/bin/bash
#
# BBR Plus + FQ_PIE 强制启用器 - 增强版
# 支持多种启动方式，确保BBR Plus和FQ_PIE在任何情况下都能正常启用
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
VERSION="2.1.0"

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

# 检查FQ_PIE支持
check_fqpie() {
    log "${BLUE}🔍 检查 FQ_PIE 队列规程支持...${RESET}"
    
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")
    echo "当前队列规程: $current_qdisc"
    
    # 检查内核模块是否存在
    if lsmod | grep -q sch_fq_pie || modinfo sch_fq_pie >/dev/null 2>&1; then
        echo -e "${GREEN}✅ 检测到 FQ_PIE 队列规程支持${RESET}"
    else
        echo -e "${YELLOW}⚠️ 未检测到 FQ_PIE 模块，尝试加载...${RESET}"
        modprobe sch_fq_pie 2>/dev/null || echo -e "${RED}❌ 无法加载 FQ_PIE 模块${RESET}"
    fi
    
    # 检查tc命令是否可以创建fq_pie队列
    if command -v tc >/dev/null 2>&1; then
        if tc qdisc add dev lo root fq_pie 2>/dev/null; then
            tc qdisc del dev lo root 2>/dev/null || true
            echo -e "${GREEN}✅ FQ_PIE 队列规程可正常使用${RESET}"
        else
            echo -e "${YELLOW}⚠️ FQ_PIE 队列规程可能不完全支持${RESET}"
        fi
    fi
}

# 备份现有配置
backup_configs() {
    log "${YELLOW}📦 备份现有配置...${RESET}"
    local backup_dir="/root/bbrplus-fqpie-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份相关配置文件
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf "$backup_dir/"
    [ -f /etc/sysctl.d/99-bbrplus.conf ] && cp /etc/sysctl.d/99-bbrplus.conf "$backup_dir/"
    [ -f /etc/sysctl.d/99-bbrplus-fqpie.conf ] && cp /etc/sysctl.d/99-bbrplus-fqpie.conf "$backup_dir/"
    [ -f /etc/default/grub ] && cp /etc/default/grub "$backup_dir/"
    [ -f /etc/rc.local ] && cp /etc/rc.local "$backup_dir/"
    
    echo "配置已备份到: $backup_dir"
}

# 方法1: sysctl配置文件 (FQ模式)
sysctl_method_fq() {
    log "${YELLOW}>>> 方法1: 配置 sysctl 启用 BBR Plus + FQ${RESET}"
    
    # 创建专用配置文件
    cat > /etc/sysctl.d/99-bbrplus-fq.conf <<'EOF'
# BBR Plus + FQ Configuration
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
        echo "# BBR Plus + FQ - Added by enable script" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbrplus" >> /etc/sysctl.conf
    fi
    
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ sysctl (FQ模式) 配置完成${RESET}"
}

# 方法1-FQ_PIE: sysctl配置文件 (FQ_PIE模式)
sysctl_method_fqpie() {
    log "${YELLOW}>>> 方法1-FQ_PIE: 配置 sysctl 启用 BBR Plus + FQ_PIE${RESET}"
    
    # 创建专用配置文件
    cat > /etc/sysctl.d/99-bbrplus-fqpie.conf <<'EOF'
# BBR Plus + FQ_PIE Configuration - 极致性能模式
net.core.default_qdisc = fq_pie
net.ipv4.tcp_congestion_control = bbrplus

# FQ_PIE 专用优化参数
net.core.rmem_default = 2097152
net.core.rmem_max = 33554432
net.core.wmem_default = 131072
net.core.wmem_max = 33554432
net.core.netdev_max_backlog = 65536
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

# TCP 缓冲区优化 (为FQ_PIE调优)
net.ipv4.tcp_rmem = 8192 2097152 4194304
net.ipv4.tcp_wmem = 8192 131072 33554432
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_collapse = 0
net.ipv4.tcp_slow_start_after_idle = 0

# BBR Plus 专用优化
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# 激进的内存分配 (FQ_PIE需要更多内存)
vm.min_free_kbytes = 131072
vm.swappiness = 10
EOF

    # 同时写入主配置文件作为后备
    if ! grep -q "net.ipv4.tcp_congestion_control.*bbrplus" /etc/sysctl.conf 2>/dev/null; then
        echo "" >> /etc/sysctl.conf
        echo "# BBR Plus + FQ_PIE - Added by enable script" >> /etc/sysctl.conf
        echo "net.core.default_qdisc = fq_pie" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbrplus" >> /etc/sysctl.conf
    fi
    
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ sysctl (FQ_PIE模式) 配置完成${RESET}"
}

# 方法2: systemd 服务 (FQ模式)
systemd_method_fq() {
    log "${YELLOW}>>> 方法2: 创建 systemd 启动服务 (FQ模式)${RESET}"
    
    cat > /etc/systemd/system/force-bbrplus-fq.service <<'EOF'
[Unit]
Description=Force Enable BBR Plus TCP Congestion Control with FQ
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
    systemctl enable force-bbrplus-fq.service
    systemctl start force-bbrplus-fq.service >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ systemd 服务 (FQ模式) 配置完成${RESET}"
}

# 方法2-FQ_PIE: systemd 服务 (FQ_PIE模式)
systemd_method_fqpie() {
    log "${YELLOW}>>> 方法2-FQ_PIE: 创建 systemd 启动服务 (FQ_PIE模式)${RESET}"
    
    cat > /etc/systemd/system/force-bbrplus-fqpie.service <<'EOF'
[Unit]
Description=Force Enable BBR Plus with FQ_PIE - Ultimate Performance Mode
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStartPre=/sbin/modprobe sch_fq_pie
ExecStart=/bin/bash -c 'echo fq_pie > /proc/sys/net/core/default_qdisc && echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control'
ExecStart=/sbin/sysctl -w net.core.default_qdisc=fq_pie
ExecStart=/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbrplus
ExecStart=/bin/bash -c 'echo "BBR Plus + FQ_PIE activated at $(date)" >> /var/log/bbrplus-fqpie.log'
TimeoutStartSec=30
Restart=no

[Install]
WantedBy=multi-user.target network-online.target
EOF

    systemctl daemon-reload
    systemctl enable force-bbrplus-fqpie.service
    systemctl start force-bbrplus-fqpie.service >/dev/null 2>&1 || true
    echo -e "${GREEN}✅ systemd 服务 (FQ_PIE模式) 配置完成${RESET}"
}

# 方法3: GRUB启动参数 (支持FQ_PIE)
grub_method_fqpie() {
    log "${YELLOW}>>> 方法3-FQ_PIE: 修改 GRUB 启动参数 (FQ_PIE模式)${RESET}"
    
    if [ -f /etc/default/grub ]; then
        # 备份grub配置
        cp /etc/default/grub /etc/default/grub.bbrplus.bak
        
        # 移除现有的BBR相关参数
        sed -i 's/net\.core\.default_qdisc=[^ ]* //g' /etc/default/grub
        sed -i 's/net\.ipv4\.tcp_congestion_control=[^ ]* //g' /etc/default/grub
        
        # 添加BBR Plus + FQ_PIE 参数
        if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
            sed -i 's/^GRUB_CMDLINE_LINUX="/&net.core.default_qdisc=fq_pie net.ipv4.tcp_congestion_control=bbrplus /' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX="net.core.default_qdisc=fq_pie net.ipv4.tcp_congestion_control=bbrplus"' >> /etc/default/grub
        fi
        
        # 更新GRUB配置
        if command -v update-grub >/dev/null 2>&1; then
            update-grub >/dev/null 2>&1
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
        elif command -v grub2-mkconfig >/dev/null 2>&1; then
            grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
        fi
        
        echo -e "${GREEN}✅ GRUB (FQ_PIE模式) 配置完成${RESET}"
    else
        echo -e "${RED}⚠️ 未检测到 GRUB 配置，跳过此方法${RESET}"
    fi
}

# 方法4: rc.local 兼容方式 (FQ_PIE模式)
rclocal_method_fqpie() {
    log "${YELLOW}>>> 方法4-FQ_PIE: 配置 rc.local 开机启动 (FQ_PIE模式)${RESET}"
    
    # 创建或修改 rc.local
    cat > /etc/rc.local <<'EOF'
#!/bin/bash
# BBR Plus + FQ_PIE force enable script - Ultimate Performance Mode
# This file is executed at the end of each multiuser runlevel

# 等待网络就绪
sleep 5

# 加载FQ_PIE模块
/sbin/modprobe sch_fq_pie 2>/dev/null || true

# 强制设置BBR Plus + FQ_PIE
echo fq_pie > /proc/sys/net/core/default_qdisc 2>/dev/null || true
echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true

# 使用sysctl命令作为后备
/sbin/sysctl -w net.core.default_qdisc=fq_pie >/dev/null 2>&1 || true
/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbrplus >/dev/null 2>&1 || true

# 记录日志
echo "$(date): BBR Plus + FQ_PIE force enabled" >> /var/log/bbrplus-fqpie.log

exit 0
EOF
    
    chmod +x /etc/rc.local
    
    # 如果系统使用systemd，确保rc-local服务启用
    if systemctl list-unit-files | grep -q rc-local; then
        systemctl enable rc-local >/dev/null 2>&1 || true
    fi
    
    echo -e "${GREEN}✅ rc.local (FQ_PIE模式) 配置完成${RESET}"
}

# 方法5: crontab定时任务 (FQ_PIE模式)
crontab_method_fqpie() {
    log "${YELLOW}>>> 方法5-FQ_PIE: 创建 crontab 定时检查任务 (FQ_PIE模式)${RESET}"
    
    # 创建检查脚本
    cat > /usr/local/bin/check-bbrplus-fqpie.sh <<'EOF'
#!/bin/bash
CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

CHANGED=0

if [ "$CURRENT_CC" != "bbrplus" ]; then
    echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbrplus >/dev/null 2>&1 || true
    CHANGED=1
fi

if [ "$CURRENT_QDISC" != "fq_pie" ]; then
    modprobe sch_fq_pie 2>/dev/null || true
    echo fq_pie > /proc/sys/net/core/default_qdisc 2>/dev/null || true
    sysctl -w net.core.default_qdisc=fq_pie >/dev/null 2>&1 || true
    CHANGED=1
fi

if [ "$CHANGED" -eq 1 ]; then
    echo "$(date): BBR Plus + FQ_PIE restored from CC:$CURRENT_CC QDISC:$CURRENT_QDISC" >> /var/log/bbrplus-fqpie.log
fi
EOF
    
    chmod +x /usr/local/bin/check-bbrplus-fqpie.sh
    
    # 添加到crontab (每分钟检查一次)
    (crontab -l 2>/dev/null | grep -v check-bbrplus; echo "*/1 * * * * /usr/local/bin/check-bbrplus-fqpie.sh") | crontab -
    
    echo -e "${GREEN}✅ crontab 定时任务 (FQ_PIE模式) 配置完成${RESET}"
}

# 方法7: 直接修改proc文件系统 (FQ_PIE立即生效)
proc_method_fqpie() {
    log "${YELLOW}>>> 方法7-FQ_PIE: 直接修改 proc 文件系统 (FQ_PIE立即生效)${RESET}"
    
    # 加载FQ_PIE模块
    modprobe sch_fq_pie 2>/dev/null || true
    
    # 立即设置
    echo fq_pie > /proc/sys/net/core/default_qdisc 2>/dev/null || true
    echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    
    echo -e "${GREEN}✅ proc 文件系统修改完成 (FQ_PIE立即生效)${RESET}"
}

# 极致性能模式 (所有FQ_PIE方法)
ultimate_performance_mode() {
    log "${MAGENTA}🚀 启用极致性能模式 (BBR Plus + FQ_PIE 全套)${RESET}"
    echo -e "${MAGENTA}⚡ 警告: 此模式将最大化网络性能，可能消耗更多系统资源${RESET}"
    
    proc_method_fqpie
    sysctl_method_fqpie
    systemd_method_fqpie
    grub_method_fqpie
    rclocal_method_fqpie
    crontab_method_fqpie
    
    # 额外的性能调优
    log "${YELLOW}>>> 应用极致性能调优参数...${RESET}"
    
    # CPU调频设置为性能模式
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
    fi
    
    # 网卡队列优化
    for iface in $(ls /sys/class/net/ | grep -E '^(eth|ens|enp)'); do
        if [ -d "/sys/class/net/$iface" ]; then
            ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
            ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
        fi
    done
    
    echo -e "${MAGENTA}🎯 极致性能模式配置完成！${RESET}"
}

# 标准全部方法 (FQ模式)
all_methods_fq() {
    log "${CYAN}🚀 启用标准全部方法 (BBR Plus + FQ)${RESET}"
    proc_method_fq() {
        echo fq > /proc/sys/net/core/default_qdisc 2>/dev/null || true
        echo bbrplus > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
    }
    
    proc_method_fq
    sysctl_method_fq
    systemd_method_fq
    grub_method() {
        if [ -f /etc/default/grub ]; then
            cp /etc/default/grub /etc/default/grub.bbrplus.bak
            sed -i 's/net\.core\.default_qdisc=[^ ]* //g' /etc/default/grub
            sed -i 's/net\.ipv4\.tcp_congestion_control=[^ ]* //g' /etc/default/grub
            if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                sed -i 's/^GRUB_CMDLINE_LINUX="/&net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbrplus /' /etc/default/grub
            else
                echo 'GRUB_CMDLINE_LINUX="net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbrplus"' >> /etc/default/grub
            fi
            if command -v update-grub >/dev/null 2>&1; then
                update-grub >/dev/null 2>&1
            fi
        fi
    }
    grub_method
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
    
    # 检查FQ_PIE模块状态
    if lsmod | grep -q sch_fq_pie; then
        echo "FQ_PIE 模块状态: ✅ 已加载"
    else
        echo "FQ_PIE 模块状态: ❌ 未加载"
    fi
    
    # 网络接口信息
    echo ""
    echo "网络接口队列信息:"
    for iface in $(ls /sys/class/net/ | grep -E '^(eth|ens|enp)' | head -3); do
        if [ -d "/sys/class/net/$iface" ]; then
            qdisc_info=$(tc qdisc show dev "$iface" 2>/dev/null | head -1 || echo "无法获取")
            echo "  $iface: $qdisc_info"
        fi
    done
    echo "======================================"
}

# 清理配置
cleanup_configs() {
    log "${YELLOW}🧹 清理 BBR Plus + FQ_PIE 相关配置...${RESET}"
    
    # 删除配置文件
    rm -f /etc/sysctl.d/99-bbrplus.conf
    rm -f /etc/sysctl.d/99-bbrplus-fq.conf
    rm -f /etc/sysctl.d/99-bbrplus-fqpie.conf
    
    # 删除systemd服务
    for service in force-bbrplus force-bbrplus-fq force-bbrplus-fqpie; do
        systemctl stop "$service.service" >/dev/null 2>&1 || true
        systemctl disable "$service.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$service.service"
    done
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
    rm -f /usr/local/bin/check-bbrplus-fqpie.sh
    
    # 删除模块配置
    rm -f /etc/modprobe.d/bbrplus.conf
    
    # 删除日志
    rm -f /var/log/bbrplus.log
    rm -f /var/log/bbrplus-fqpie.log
    
    echo -e "${GREEN}✅ 清理完成${RESET}"
}

# 主菜单
menu() {
    clear
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "${GREEN}  BBR Plus + FQ_PIE 强制启用器 v${VERSION}  ${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
    echo ""
    detect_os
    check_status
    echo ""
    echo -e "${CYAN}请选择操作模式:${RESET}"
    echo ""
    echo -e "${YELLOW}== 标准模式 (BBR Plus + FQ) ==${RESET}"
    echo -e "  ${YELLOW}1${RESET}) 仅使用 sysctl 配置 (FQ)"
    echo -e "  ${YELLOW}2${RESET}) 使用 systemd 启动服务 (FQ)"
    echo -e "  ${YELLOW}3${RESET}) 修改 GRUB 启动参数 (FQ)"
    echo -e "  ${GREEN}8${RESET}) 🚀 标准模式全部启用 (BBR Plus + FQ)"
    echo ""
    echo -e "${MAGENTA}== 极致性能模式 (BBR Plus + FQ_PIE) ==${RESET}"
    echo -e "  ${MAGENTA}11${RESET}) ⚡ sysctl 配置 (FQ_PIE)"
    echo -e "  ${MAGENTA}12${RESET}) ⚡ systemd 启动服务 (FQ_PIE)"
    echo -e "  ${MAGENTA}13${RESET}) ⚡ GRUB 启动参数 (FQ_PIE)"
    echo -e "  ${MAGENTA}14${RESET}) ⚡ rc.local 启动 (FQ_PIE)"
    echo -e "  ${MAGENTA}15${RESET}) ⚡ crontab 定时检查 (FQ_PIE)"
    echo -e "  ${MAGENTA}17${RESET}) ⚡ 直接修改 proc (FQ_PIE立即生效)"
    echo -e "  ${RED}88${RESET}) 🔥 极致性能模式全套 (最强配置)"
    echo ""
    echo -e "${BLUE}== 系统管理 ==${RESET}"
    echo -e "  ${BLUE}9${RESET}) 📊 检查当前状态"
    echo -e "  ${YELLOW}t${RESET}) 🧪 测试 FQ_PIE 支持"
    echo -e "  ${RED}c${RESET}) 🧹 清理所有配置"
    echo -e "  ${RED}q${RESET}) 退出"
    echo ""
    echo -e "${CYAN}💡 提示:${RESET}"
    echo -e "   - FQ_PIE 是更先进的队列管理算法，可显著降低延迟"
    echo -e "   - 极致性能模式会消耗更多系统资源，适合高性能服务器"
    echo -e "   - 建议先测试 FQ_PIE 支持再选择相应模式"
    echo ""
    read -p "请输入选择: " option
    
    case "$option" in
        1) check_bbrplus && backup_configs && sysctl_method_fq ;;
        2) check_bbrplus && backup_configs && systemd_method_fq ;;
        3) check_bbrplus && backup_configs && grub_method() {
            if [ -f /etc/default/grub ]; then
                cp /etc/default/grub /etc/default/grub.bbrplus.bak
                sed -i 's/net\.core\.default_qdisc=[^ ]* //g' /etc/default/grub
                sed -i 's/net\.ipv4\.tcp_congestion_control=[^ ]* //g' /etc/default/grub
                if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
                    sed -i 's/^GRUB_CMDLINE_LINUX="/&net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbrplus /' /etc/default/grub
                else
                    echo 'GRUB_CMDLINE_LINUX="net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbrplus"' >> /etc/default/grub
                fi
                if command -v update-grub >/dev/null 2>&1; then
                    update-grub >/dev/null 2>&1
                elif command -v grub-mkconfig >/dev/null 2>&1; then
                    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
                elif command -v grub2-mkconfig >/dev/null 2>&1; then
                    grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1
                fi
                echo -e "${GREEN}✅ GRUB (FQ模式) 配置完成${RESET}"
            else
                echo -e "${RED}⚠️ 未检测到 GRUB 配置，跳过此方法${RESET}"
            fi
        } && grub_method ;;
        8) check_bbrplus && backup_configs && all_methods_fq ;;
        
        11) check_bbrplus && check_fqpie && backup_configs && sysctl_method_fqpie ;;
        12) check_bbrplus && check_fqpie && backup_configs && systemd_method_fqpie ;;
        13) check_bbrplus && check_fqpie && backup_configs && grub_method_fqpie ;;
        14) check_bbrplus && check_fqpie && backup_configs && rclocal_method_fqpie ;;
        15) check_bbrplus && check_fqpie && backup_configs && crontab_method_fqpie ;;
        17) check_bbrplus && check_fqpie && proc_method_fqpie ;;
        88) check_bbrplus && check_fqpie && backup_configs && ultimate_performance_mode ;;
        
        9) check_status && read -p "按回车键继续..." && menu ;;
        t|T) test_fqpie_support && read -p "按回车键继续..." && menu ;;
        c|C) cleanup_configs && read -p "按回车键继续..." && menu ;;
        q|Q) echo -e "${CYAN}👋 感谢使用 BBR Plus + FQ_PIE 启用器!${RESET}"; exit 0 ;;
        *) echo -e "${RED}❌ 无效输入，请重试${RESET}"; sleep 2; menu ;;
    esac
    
    echo ""
    log "${GREEN}✅ 操作完成!${RESET}"
    echo ""
    echo -e "${CYAN}当前状态:${RESET}"
    echo "拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "队列规程: $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    echo ""
    
    # 显示性能提示
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$current_qdisc" = "fq_pie" ]; then
        echo -e "${MAGENTA}🔥 极致性能模式已启用!${RESET}"
        echo -e "${YELLOW}💡 FQ_PIE 模式特性:${RESET}"
        echo "   - 显著降低网络延迟"
        echo "   - 智能队列管理"
        echo "   - 自适应拥塞控制"
        echo "   - 更高的带宽利用率"
    elif [ "$current_qdisc" = "fq" ]; then
        echo -e "${GREEN}✅ 标准性能模式已启用${RESET}"
        echo -e "${YELLOW}💡 提示: 可尝试升级到 FQ_PIE 模式获得更佳性能${RESET}"
    fi
    
    echo ""
    echo -e "${YELLOW}💡 重要提示:${RESET}"
    echo "   - 某些配置可能需要重启系统才能完全生效"
    echo "   - FQ_PIE 模式需要较新内核支持 (建议 5.6+)"
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

# 测试FQ_PIE支持
test_fqpie_support() {
    log "${BLUE}🧪 测试 FQ_PIE 支持情况...${RESET}"
    echo "======================================"
    
    echo "1. 检查内核版本:"
    kernel_version=$(uname -r)
    echo "   当前内核: $kernel_version"
    
    kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    kernel_minor=$(echo "$kernel_version" | cut -d. -f2)
    
    if [ "$kernel_major" -gt 5 ] || ([ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -ge 6 ]); then
        echo -e "   状态: ${GREEN}✅ 内核版本支持 FQ_PIE${RESET}"
    else
        echo -e "   状态: ${YELLOW}⚠️ 内核版本较低，FQ_PIE 支持可能不完整${RESET}"
    fi
    
    echo ""
    echo "2. 检查 FQ_PIE 模块:"
    if modinfo sch_fq_pie >/dev/null 2>&1; then
        echo -e "   状态: ${GREEN}✅ FQ_PIE 模块存在${RESET}"
        modinfo sch_fq_pie | head -5
    else
        echo -e "   状态: ${RED}❌ FQ_PIE 模块不存在${RESET}"
    fi
    
    echo ""
    echo "3. 尝试加载 FQ_PIE 模块:"
    if modprobe sch_fq_pie 2>/dev/null; then
        echo -e "   状态: ${GREEN}✅ 模块加载成功${RESET}"
        if lsmod | grep -q sch_fq_pie; then
            echo -e "   确认: ${GREEN}✅ 模块已在内存中${RESET}"
        fi
    else
        echo -e "   状态: ${RED}❌ 模块加载失败${RESET}"
    fi
    
    echo ""
    echo "4. 测试 tc 命令支持:"
    if command -v tc >/dev/null 2>&1; then
        echo -e "   tc 命令: ${GREEN}✅ 可用${RESET}"
        
        # 创建临时测试
        test_result=""
        if tc qdisc add dev lo parent root fq_pie 2>/dev/null; then
            echo -e "   FQ_PIE 创建: ${GREEN}✅ 成功${RESET}"
            tc qdisc del dev lo parent root 2>/dev/null || true
        else
            echo -e "   FQ_PIE 创建: ${RED}❌ 失败${RESET}"
            test_result="failed"
        fi
    else
        echo -e "   tc 命令: ${RED}❌ 不可用${RESET}"
        test_result="failed"
    fi
    
    echo ""
    echo "5. 系统兼容性评估:"
    if [ -z "$test_result" ]; then
        echo -e "   总体评估: ${GREEN}✅ 系统完全支持 FQ_PIE${RESET}"
        echo -e "   建议: ${MAGENTA}推荐使用极致性能模式${RESET}"
    else
        echo -e "   总体评估: ${YELLOW}⚠️ 系统部分支持 FQ_PIE${RESET}"
        echo -e "   建议: ${YELLOW}建议使用标准 FQ 模式，或升级内核${RESET}"
    fi
    
    echo ""
    echo "6. 性能对比信息:"
    echo "   FQ (Fair Queue):"
    echo "     - 成熟稳定的队列算法"
    echo "     - 广泛的内核支持"
    echo "     - 适合大多数应用场景"
    echo ""
    echo "   FQ_PIE (Fair Queue + PIE):"
    echo "     - 结合公平队列和PIE算法"
    echo "     - 显著降低延迟和抖动"
    echo "     - 更智能的队列管理"
    echo "     - 需要较新内核支持 (5.6+)"
    echo "     - 更高的CPU使用率"
    
    echo "======================================"
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
