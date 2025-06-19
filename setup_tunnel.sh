#!/bin/bash

# ==============================================================================
# IPIP 隧道 + 动态域名更新 + NAT 自动配置脚本 (最终版)
#
# 功能:
# 1. 交互式收集配置信息。
# 2. 自动安装所有必要的依赖工具。
# 3. 自动开启内核 IP 转发。
# 4. 根据用户输入，生成并配置动态更新脚本。
# 5. 自动设置 Cron 定时任务，实现无人值守更新。
# 6. 自动配置 nftables 防火墙，实现内网穿透 (NAT)。
# 7. 立即执行一次，建立隧道并测试。
# ==============================================================================

# --- 脚本初始化和环境检查 ---
set -e # 任何命令失败则立即退出
apt-get install -y curl > /dev/null
# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
   echo "错误: 此脚本需要 root 权限。请使用 'sudo bash $0' 运行。" >&2
   exit 1
fi

# --- 欢迎信息和交互式配置 ---
echo "=================================================="
echo " IPIP 隧道 + 动态域名更新 + NAT 自动配置脚本"
echo "=================================================="
echo "本脚本将引导您完成所有设置，包括依赖安装。"
echo ""

# 自动检测公网IP和默认网卡
echo "正在尝试自动检测公网 IP 和主网卡..."
# 使用多个源提高成功率
DETECTED_IP=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com)
DETECTED_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -n 1)
echo "--------------------------------------------------"

# 收集用户输入
read -p "请输入你的本地公网 IP 地址 [自动检测: ${DETECTED_IP}]: " LOCAL_IP
LOCAL_IP=${LOCAL_IP:-$DETECTED_IP}

read -p "请输入对端的动态域名 (例如: mytunnel.ddns.net): " REMOTE_DOMAIN
read -p "请输入隧道名称 (例如: ipip-dyn) [默认: ipip-dyn]: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-"ipip-dyn"}

read -p "请输入隧道接口的本地 IP (例如: 10.10.10.1/24): " TUNNEL_LOCAL_IP_CIDR
read -p "请输入隧道对端的 IP (用于 PING 测试, 例如: 10.10.10.2): " TUNNEL_PEER_IP

read -p "请输入用于 NAT 的公网网卡名称 [自动检测: ${DETECTED_IFACE}]: " OIF_NAME
OIF_NAME=${OIF_NAME:-$DETECTED_IFACE}

# 验证输入是否为空
if [ -z "$LOCAL_IP" ] || [ -z "$REMOTE_DOMAIN" ] || [ -z "$TUNNEL_NAME" ] || [ -z "$TUNNEL_LOCAL_IP_CIDR" ] || [ -z "$TUNNEL_PEER_IP" ] || [ -z "$OIF_NAME" ]; then
    echo "错误: 所有字段均为必填项，请重新运行脚本。"
    exit 1
fi

# --- 配置确认 ---
echo ""
echo "------------------- 配置确认 -------------------"
echo "本地公网 IP:           $LOCAL_IP"
echo "远程动态域名:          $REMOTE_DOMAIN"
echo "隧道名称:              $TUNNEL_NAME"
echo "隧道本地 IP:           $TUNNEL_LOCAL_IP_CIDR"
echo "隧道对端 IP:           $TUNNEL_PEER_IP"
echo "NAT 出口网卡:          $OIF_NAME"
echo "--------------------------------------------------"
echo ""
read -p "配置无误，是否开始执行安装？ (y/n): " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "操作已取消。"
    exit 0
fi


# --- 步骤 1: 安装依赖并配置系统环境 ---
echo ""
echo "[1/5] 正在安装依赖并配置系统环境..."

# 更新软件包列表
echo "--> 正在更新 apt 软件包列表..."
apt-get update > /dev/null

# 安装必要的工具
echo "--> 正在安装依赖工具: iproute2, dnsutils, nftables, cron, bridge-utils..."
apt-get install -y iproute2 dnsutils nftables cron bridge-utils > /dev/null

# 开启 IP 转发
echo "--> 正在启用内核 IP 转发..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -p > /dev/null

# 加载内核模块
echo "--> 正在加载 IPIP 内核模块..."
modprobe ipip
echo "✅ 系统环境配置完成。"


# --- 步骤 2: 创建动态更新脚本 ---
echo ""
echo "[2/5] 正在创建隧道动态更新脚本..."
SCRIPT_PATH="/usr/local/bin/update_${TUNNEL_NAME}.sh"
LOG_PATH="/var/log/update_${TUNNEL_NAME}.log"

# 使用 heredoc 创建脚本
cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
# IPIP 隧道动态更新脚本 (由一键脚本自动生成)

# --- 配置变量 ---
TUNNEL_NAME="$TUNNEL_NAME"
REMOTE_DOMAIN="$REMOTE_DOMAIN"
LOCAL_IP="$LOCAL_IP"
TUNNEL_LOCAL_IP_CIDR="$TUNNEL_LOCAL_IP_CIDR"
TUNNEL_PEER_IP="$TUNNEL_PEER_IP"

# --- 脚本核心逻辑 ---
NEW_REMOTE_IP=\$(dig +short A \$REMOTE_DOMAIN | head -n 1)

if [ -z "\$NEW_REMOTE_IP" ]; then
    echo "\$(date): Error - 无法解析域名 \$REMOTE_DOMAIN"
    exit 1
fi

CURRENT_REMOTE_IP=\$(ip tunnel show \$TUNNEL_NAME 2>/dev/null | awk '/remote/ {print \$4}')

if [ "\$NEW_REMOTE_IP" == "\$CURRENT_REMOTE_IP" ]; then
    echo "\$(date): IP for \$REMOTE_DOMAIN 仍然是 \$NEW_REMOTE_IP. 无需更改."
else
    echo "\$(date): IP 发生变化或隧道不存在. 新 IP: \$NEW_REMOTE_IP. 正在更新隧道..."

    if ip link show \$TUNNEL_NAME > /dev/null 2>&1; then
        echo "\$(date): 删除旧隧道 \$TUNNEL_NAME..."
        ip tunnel del \$TUNNEL_NAME
    fi

    echo "\$(date): 创建新隧道 \$TUNNEL_NAME (mode ipip local \$LOCAL_IP remote \$NEW_REMOTE_IP)..."
    ip tunnel add \$TUNNEL_NAME mode ipip local \$LOCAL_IP remote \$NEW_REMOTE_IP
    ip link set \$TUNNEL_NAME up
    
    echo "\$(date): 配置隧道IP \$TUNNEL_LOCAL_IP_CIDR..."
    ip addr del \$TUNNEL_LOCAL_IP_CIDR dev \$TUNNEL_NAME 2>/dev/null || true
    ip addr add \$TUNNEL_LOCAL_IP_CIDR dev \$TUNNEL_NAME

    echo "\$(date): 等待5秒让接口稳定..."
    sleep 5

    echo "\$(date): Ping 隧道对端 \$TUNNEL_PEER_IP 测试连通性..."
    if ping -c 4 \$TUNNEL_PEER_IP; then
        echo "\$(date): 隧道 \$TUNNEL_NAME 更新成功，Ping 测试通过。"
    else
        echo "\$(date): 警告: 隧道 \$TUNNEL_NAME 已更新，但 Ping 测试失败。请检查对端配置或网络防火墙。"
    fi
fi
exit 0
EOF

chmod +x "$SCRIPT_PATH"
echo "✅ 更新脚本已创建: $SCRIPT_PATH"


# --- 步骤 3: 设置定时任务 ---
echo ""
echo "[3/5] 正在设置定时任务 (Cron)..."
CRON_FILE="/etc/cron.d/update_${TUNNEL_NAME}"
echo "*/5 * * * * root $SCRIPT_PATH >> $LOG_PATH 2>&1" > "$CRON_FILE"
chmod 0644 "$CRON_FILE"
systemctl restart cron
echo "✅ 定时任务已设置。每5分钟执行一次，日志记录在: $LOG_PATH"


# --- 步骤 4: 配置防火墙 ---
echo ""
echo "[4/5] 正在配置防火墙 (nftables)..."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!! 警告 !!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "接下来的操作将使用新配置覆盖 /etc/nftables.conf 文件。"
echo "这将清空您所有的现有 nftables 规则，并仅应用 IP 转发所需的 NAT 规则。"
echo "如果您有其他重要的防火墙规则，请选择 'n' 并手动配置。"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "是否继续自动配置 nftables 防火墙？ (y/n): " nft_confirm
if [[ "$nft_confirm" == [yY] ]]; then
    cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f
# 由一键脚本自动生成于 $(date)

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority 0;
		policy accept;
		
		# 基础规则: 接受已建立和相关的连接
		ct state established,related accept
		
		# 允许来自本地回环接口的所有流量
		iifname "lo" accept
		
		# 允许 ICMP (Ping)
		ip protocol icmp accept
		
		# 允许 GRE (协议 47)，IPIP 隧道需要
		ip protocol gre accept
	}
	chain forward {
		type filter hook forward priority 0;
		
		# 允许从隧道接口转发到公网网卡
		iifname "$TUNNEL_NAME" oifname "$OIF_NAME" accept
		
		# 允许已建立和相关的连接被转发
		ct state established,related accept
		
		# 默认丢弃所有其他转发
		policy drop;
	}
	chain output {
		type filter hook output priority 0;
		policy accept;
	}
}

table ip nat {
	chain postrouting {
		type nat hook postrouting priority 100;
		# 对所有流出公网网卡的流量进行源地址转换 (NAT)
		oifname "$OIF_NAME" masquerade
	}
}
EOF
    echo "--> 正在启用并重启 nftables 服务..."
    systemctl enable nftables > /dev/null
    systemctl restart nftables
    echo "✅ nftables 防火墙配置完成。"
else
    echo "⚠️  已跳过防火墙自动配置。请您务必手动配置防火墙，允许 GRE 协议 (IP protocol 47) 的传入，并设置正确的 NAT 规则，否则隧道将无法工作。"
fi


# --- 步骤 5: 首次运行并总结 ---
echo ""
echo "[5/5] 正在首次运行脚本以建立隧道..."
# 首次运行时创建日志文件，避免权限问题
touch "$LOG_PATH"
chown root:root "$LOG_PATH"
# 执行脚本
"$SCRIPT_PATH"

echo ""
echo "=================================================="
echo "         🎉 部署完成! 🎉"
echo "=================================================="
echo "所有配置已完成。请检查以下信息："
echo ""
echo "  - 隧道名称:            $TUNNEL_NAME"
echo "  - 隧道更新脚本:        $SCRIPT_PATH"
echo "  - 定时任务日志:        $LOG_PATH"
echo ""
echo "脚本已执行一次，请检查上面的输出确认隧道是否成功建立。"
echo "您现在可以使用 'ip addr' 查看隧道接口，或通过 'ping $TUNNEL_PEER_IP' 测试连通性。"
echo "请确保在对端设备上也完成了对应的隧道和路由配置。"
echo "=================================================="

