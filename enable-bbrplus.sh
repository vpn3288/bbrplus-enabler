#!/bin/bash
set -e

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

echo -e "${YELLOW}== 检查是否 root 用户 ==${RESET}"
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户执行本脚本！${RESET}"
  exit 1
fi

echo -e "${YELLOW}== 检测系统内核是否支持 bbrplus ==${RESET}"
available_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
if ! echo "$available_algos" | grep -qw bbrplus; then
  echo -e "${RED}当前内核不支持 bbrplus，请先安装支持的内核${RESET}"
  echo "系统支持的算法：$available_algos"
  exit 1
fi

echo -e "${YELLOW}请选择你要启用的公平队列（qdisc）：${RESET}"
echo "  1) fq（兼容性最好，默认）"
echo "  2) fq_codel（低延迟，Linux 默认）"
echo "  3) cake（最强大，智能，需内核支持）"
read -p "请输入数字（1-3），默认 1: " qchoice

case "$qchoice" in
  2)
    qdisc_choice="fq_codel"
    ;;
  3)
    qdisc_choice="cake"
    ;;
  *)
    qdisc_choice="fq"
    ;;
esac

echo -e "${YELLOW}== 方式 1：写入 sysctl 配置 ==${RESET}"
cat > /etc/sysctl.d/99-bbrplus.conf <<EOF
net.core.default_qdisc = $qdisc_choice
net.ipv4.tcp_congestion_control = bbrplus
EOF
sysctl --system

echo -e "${YELLOW}== 方式 2：创建 systemd 服务兜底 ==${RESET}"
cat > /etc/systemd/system/force-bbrplus.service <<EOF
[Unit]
Description=Force enable BBR Plus and set qdisc $qdisc_choice
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/sysctl -w net.core.default_qdisc=$qdisc_choice
ExecStart=/sbin/sysctl -w net.ipv4.tcp_congestion_control=bbrplus

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable force-bbrplus
systemctl start force-bbrplus

echo -e "${YELLOW}== 方式 3：修改 grub 启动参数（适用于 grub 系统） ==${RESET}"
if [ -f /etc/default/grub ]; then
  cp /etc/default/grub /etc/default/grub.bak.$(date +%F-%T)
  sed -i 's/ net.core.default_qdisc=[^ ]*//g' /etc/default/grub
  sed -i 's/ net.ipv4.tcp_congestion_control=[^ ]*//g' /etc/default/grub
  sed -i "s/^GRUB_CMDLINE_LINUX=\"\(.*\)\"/GRUB_CMDLINE_LINUX=\"\1 net.core.default_qdisc=$qdisc_choice net.ipv4.tcp_congestion_control=bbrplus\"/" /etc/default/grub
  echo -e "${YELLOW}更新 grub 配置...${RESET}"
  update-grub
else
  echo -e "${RED}未检测到 grub 配置，跳过 grub 启动参数修改${RESET}"
fi

echo -e "${YELLOW}== 方式 4：写入 /etc/rc.local（兼容老系统） ==${RESET}"
if [ ! -f /etc/rc.local ]; then
  cat > /etc/rc.local <<EOF
#!/bin/bash
exit 0
EOF
  chmod +x /etc/rc.local
fi
sed -i '/default_qdisc/d' /etc/rc.local
sed -i '/tcp_congestion_control/d' /etc/rc.local
sed -i '/exit 0/d' /etc/rc.local
echo "sysctl -w net.core.default_qdisc=$qdisc_choice" >> /etc/rc.local
echo "sysctl -w net.ipv4.tcp_congestion_control=bbrplus" >> /etc/rc.local
echo "exit 0" >> /etc/rc.local

echo -e "${YELLOW}== 方式 5（可选）：modprobe 预加载（部分内核支持，可能无效） ==${RESET}"
if ! grep -q "tcp_bbrplus" /etc/modules-load.d/bbrplus.conf 2>/dev/null; then
  echo "tcp_bbrplus" > /etc/modules-load.d/bbrplus.conf
  modprobe tcp_bbrplus || echo -e "${RED}modprobe tcp_bbrplus 加载失败，可能内核不支持该模块${RESET}"
else
  echo "modprobe 配置已存在"
fi

echo ""
echo -e "${GREEN}当前拥塞控制算法：$(sysctl net.ipv4.tcp_congestion_control)${RESET}"
echo -e "${GREEN}当前默认队列类型：$(sysctl net.core.default_qdisc)${RESET}"
echo ""
echo -e "${YELLOW}请重启系统以确保全部配置生效，执行命令：${RESET}reboot"
