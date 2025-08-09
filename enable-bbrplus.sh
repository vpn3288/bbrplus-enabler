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

echo -e "${YELLOW}== 清理冲突的 sysctl 配置（net.ipv4.tcp_congestion_control 和 net.core.default_qdisc） ==${RESET}"
conf_files=$(grep -rlE 'net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc' /etc/sysctl.d/ || true)
for file in $conf_files; do
  echo "处理文件：$file"
  # 备份
  cp "$file" "$file.bak.$(date +%F-%T)"
  # 注释掉冲突的行
  sed -i '/net\.ipv4\.tcp_congestion_control/d' "$file"
  sed -i '/net\.core\.default_qdisc/d' "$file"
done

echo -e "${YELLOW}== 写入指定的 sysctl 配置文件 /etc/sysctl.d/99-bbrplus.conf ==${RESET}"
cat > /etc/sysctl.d/99-bbrplus.conf <<EOF
net.core.default_qdisc = $qdisc_choice
net.ipv4.tcp_congestion_control = bbrplus
EOF

echo -e "${YELLOW}== 重新加载 sysctl 配置 ==${RESET}"
sysctl --system

echo -e "${YELLOW}== 简单检测并修复 /etc/default/grub 语法错误（修复 GRUB_CMDLINE_LINUX 行）==${RESET}"
if [ -f /etc/default/grub ]; then
  cp /etc/default/grub /etc/default/grub.bak.$(date +%F-%T)
  
  # 提取原有 GRUB_CMDLINE_LINUX 内容（去除前后引号）
  old_cmdline=$(grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub | head -n1 | sed -E 's/^GRUB_CMDLINE_LINUX="(.*)"$/\1/' || echo "")
  
  # 过滤掉旧的相关参数
  new_cmdline=$(echo "$old_cmdline" | sed -E 's/(net\.core\.default_qdisc=[^ ]+)//g; s/(net\.ipv4\.tcp_congestion_control=[^ ]+)//g' | xargs)
  
  # 新参数加入
  new_cmdline="$new_cmdline net.core.default_qdisc=$qdisc_choice net.ipv4.tcp_congestion_control=bbrplus"
  
  # 用安全的方式替换整行
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$new_cmdline\"|" /etc/default/grub
  
  echo -e "${GREEN}/etc/default/grub 修复完成。请确认无语法错误后手动执行：sudo update-grub${RESET}"
else
  echo -e "${RED}未检测到 /etc/default/grub 文件，跳过 grub 修复${RESET}"
fi

echo -e "${YELLOW}== 创建持续守护服务，防止其他程序覆盖 bbrplus 设置 ==${RESET}"

cat >/usr/local/bin/force-bbrplus.sh <<EOF
#!/bin/bash
target_algo="bbrplus"
target_qdisc="$qdisc_choice"
while true; do
  current_algo=\$(sysctl -n net.ipv4.tcp_congestion_control)
  current_qdisc=\$(sysctl -n net.core.default_qdisc)
  if [ "\$current_algo" != "\$target_algo" ]; then
    sysctl -w net.ipv4.tcp_congestion_control=\$target_algo
  fi
  if [ "\$current_qdisc" != "\$target_qdisc" ]; then
    sysctl -w net.core.default_qdisc=\$target_qdisc
  fi
  sleep 5
done
EOF

chmod +x /usr/local/bin/force-bbrplus.sh

cat >/etc/systemd/system/force-bbrplus.service <<EOF
[Unit]
Description=持续强制启用 BBR Plus 和 qdisc 服务
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/force-bbrplus.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable force-bbrplus
systemctl restart force-bbrplus

echo ""
echo -e "${GREEN}当前拥塞控制算法：$(sysctl -n net.ipv4.tcp_congestion_control)${RESET}"
echo -e "${GREEN}当前默认队列类型：$(sysctl -n net.core.default_qdisc)${RESET}"
echo ""
echo -e "${YELLOW}请确认 /etc/default/grub 无语法错误后，执行：${RESET}sudo update-grub"
echo -e "${YELLOW}然后重启生效：${RESET}sudo reboot"
