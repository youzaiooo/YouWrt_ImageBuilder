#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 设置默认防火墙规则，方便单网口虚拟机首次访问 WebUI 
# 因为本项目中 单网口模式是dhcp模式 直接就能上网并且访问web界面 避免新手每次都要修改/etc/config/network中的静态ip
# 当你刷机运行后 都调整好了 你完全可以在web页面自行关闭 wan口防火墙的入站数据
# 具体操作方法：网络——防火墙 在wan的入站数据 下拉选项里选择 拒绝 保存并应用即可。
uci set firewall.@zone[1].input='ACCEPT'

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 检查配置文件pppoe-settings是否存在 该文件由build.sh动态生成
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. Skipping." >>$LOGFILE
else
    # 读取pppoe信息($enable_pppoe、$pppoe_account、$pppoe_password)
    . "$SETTINGS_FILE"
fi

# 1. 先获取所有物理接口列表
ifnames=""
for iface in /sys/class/net/*; do
    iface_name=$(basename "$iface")
    if [ -e "$iface/device" ] && echo "$iface_name" | grep -Eq '^eth|^en'; then
        ifnames="$ifnames $iface_name"
    fi
done
ifnames=$(echo "$ifnames" | awk '{$1=$1};1')

count=$(echo "$ifnames" | wc -w)
echo "Detected physical interfaces: $ifnames" >>$LOGFILE
echo "Interface count: $count" >>$LOGFILE

# 2. 根据板子型号映射WAN和LAN接口
board_name=$(cat /tmp/sysinfo/board_name 2>/dev/null || echo "unknown")
echo "Board detected: $board_name" >>$LOGFILE

wan_ifname=""
lan_ifnames=""
# 此处特殊处理个别开发板网口顺序问题
case "$board_name" in
    "radxa,e20c"|"friendlyarm,nanopi-r5c")
        wan_ifname="eth1"
        lan_ifnames="eth0"
        echo "Using $board_name mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
    *)
        # 默认第一个接口为WAN，其余为LAN
        wan_ifname=$(echo "$ifnames" | awk '{print $1}')
        lan_ifnames=$(echo "$ifnames" | cut -d ' ' -f2-)
        echo "Using default mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"
        ;;
esac

# 3. 配置网络
if [ "$count" -eq 1 ]; then
    # 单网口设备，DHCP模式
    uci set network.lan.proto='dhcp'
    uci delete network.lan.ipaddr
    uci delete network.lan.netmask
    uci delete network.lan.gateway
    uci delete network.lan.dns
    uci commit network
elif [ "$count" -gt 1 ]; then
    # 多网口设备配置
    # 配置WAN
    uci set network.wan=interface
    uci set network.wan.device="$wan_ifname"
    uci set network.wan.proto='dhcp'

    # 配置WAN6
    uci set network.wan6=interface
    uci set network.wan6.device="$wan_ifname"
    uci set network.wan6.proto='dhcpv6'

    # 查找 br-lan 设备 section
    section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
    if [ -z "$section" ]; then
        echo "error：cannot find device 'br-lan'." >>$LOGFILE
    else
        # 删除原有ports
        uci -q delete "network.$section.ports"
        # 添加LAN接口端口
        for port in $lan_ifnames; do
            uci add_list "network.$section.ports"="$port"
        done
        echo "Updated br-lan ports: $lan_ifnames" >>$LOGFILE
    fi

    # LAN口设置静态IP
    uci set network.lan.proto='static'
    # 多网口设备 支持修改为别的管理后台地址 在Github Action 的UI上自行输入即可 
    uci set network.lan.netmask='255.255.255.0'
    # 设置路由器管理后台地址
    IP_VALUE_FILE="/etc/config/custom_router_ip.txt"
    if [ -f "$IP_VALUE_FILE" ]; then
        CUSTOM_IP=$(cat "$IP_VALUE_FILE")
        # 用户在UI上设置的路由器后台管理地址
        uci set network.lan.ipaddr=$CUSTOM_IP
        echo "custom router ip is $CUSTOM_IP" >> $LOGFILE
    else
        uci set network.lan.ipaddr='192.168.100.1'
        echo "default router ip is 192.168.100.1" >> $LOGFILE
    fi

    # PPPoE设置
    echo "enable_pppoe value: $enable_pppoe" >>$LOGFILE
    if [ "$enable_pppoe" = "yes" ]; then
        echo "PPPoE enabled, configuring..." >>$LOGFILE
        uci set network.wan.proto='pppoe'
        uci set network.wan.username="$pppoe_account"
        uci set network.wan.password="$pppoe_password"
        uci set network.wan.peerdns='1'
        uci set network.wan.auto='1'
        uci set network.wan6.proto='none'
        echo "PPPoE config done." >>$LOGFILE
    else
        echo "PPPoE not enabled." >>$LOGFILE
    fi

    uci commit network
fi

# 设置所有网口可访问网页终端
uci delete ttyd.@ttyd[0].interface

# 设置所有网口可连接 SSH
uci set dropbear.@dropbear[0].Interface=''
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by youzai"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "fix ttyd show msg: /usb/bin/zsh: not found" >>$LOGFILE
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "fix quickfile nginx config" >>$LOGFILE
fi

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall

# 追加新的 zone + forwarding 配置
cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

# 从 backup-YouzaiWrt-2026-06-08 迁移的通用默认配置。
# 跳过密码、证书、Tailscale 状态、DDNS 账号、私网路由和设备专用 IPv6 地址。
echo "Applying migrated YouzaiWrt defaults..." >>$LOGFILE

# 系统基础设置
uci set system.@system[0].hostname='YouzaiWrt'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].log_size='128'
uci set system.@system[0].ttylogin='0'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.server='ntp1.aliyun.com'
uci add_list system.ntp.server='ntp.ntsc.ac.cn'
uci add_list system.ntp.server='cn.ntp.org.cn'
uci commit system

# 多网口默认管理地址沿用备份值；如果构建流程写入了 custom_router_ip.txt，则尊重上面的已有逻辑。
if [ "$count" -gt 1 ] && [ ! -f /etc/config/custom_router_ip.txt ]; then
    uci set network.lan.ipaddr='192.168.10.254'
    echo "backup router ip is 192.168.10.254" >>$LOGFILE
fi

# 网络通用优化。wan6 使用 @wan 便于跟随 WAN 口协议和设备变化。
uci set network.globals.packet_steering='1'
uci set network.lan.ip6assign='64'
uci set network.lan.ipv6='1'
uci set network.lan.ip6ifaceid='eui64'
uci set network.wan.metric='11'
if [ "${enable_pppoe:-}" != "yes" ]; then
    uci set network.wan6.device='@wan'
    uci -q delete network.wan6.ifname
    uci set network.wan6.proto='dhcpv6'
    uci set network.wan6.metric='11'
    uci set network.wan6.requery='3600'
    uci set network.wan6.force_link='1'
    uci set network.wan6.reqaddress='try'
    uci set network.wan6.reqprefix='auto'
    uci set network.wan6.extendprefix='1'
fi
if uci -q get network.docker >/dev/null 2>&1 || [ -e /etc/init.d/dockerd ]; then
    uci set network.docker=interface
    uci set network.docker.device='docker0'
    uci set network.docker.proto='none'
    uci set network.docker.auto='0'
    if ! uci -q show network | grep -q "name='docker0'"; then
        uci add network device
        uci set network.@device[-1].type='bridge'
        uci set network.@device[-1].name='docker0'
    fi
fi
if command -v tailscaled >/dev/null 2>&1 || [ -e /etc/init.d/tailscale ]; then
    uci set network.tailscale=interface
    uci set network.tailscale.proto='none'
    uci set network.tailscale.device='tailscale0'
fi
uci commit network

# DHCP/DNS 默认值，来自备份中的 dnsmasq 缓存与 IPv6 RA 设置。
uci set dhcp.@dnsmasq[0].min_cache_ttl='3600'
uci set dhcp.@dnsmasq[0].use_stale_cache='3600'
uci set dhcp.@dnsmasq[0].cachesize='8000'
uci set dhcp.@dnsmasq[0].nonegcache='1'
uci set dhcp.@dnsmasq[0].ednspacket_max='1232'
uci set dhcp.@dnsmasq[0].localuse='1'
uci set dhcp.@dnsmasq[0].noresolv='0'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
uci set dhcp.lan.dhcpv4='server'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci -q delete dhcp.lan.ra_flags
uci add_list dhcp.lan.ra_flags='other-config'
uci set dhcp.lan.max_preferred_lifetime='2700'
uci set dhcp.lan.max_valid_lifetime='5400'
uci commit dhcp

# Dropbear 保持密码登录可用，但不写入任何 root 密码或 shadow 内容。
uci set dropbear.@dropbear[0].enable='1'
uci set dropbear.@dropbear[0].PasswordAuth='on'
uci set dropbear.@dropbear[0].RootPasswordAuth='on'
uci set dropbear.@dropbear[0].Port='22'
uci set dropbear.@dropbear[0].Interface=''
uci commit dropbear

# TTYD 不绑定单一接口，便于首次启动后从 LAN/WAN 管理面进入终端。
if uci -q get ttyd.@ttyd[0] >/dev/null 2>&1; then
    uci -q delete ttyd.@ttyd[0].interface
    uci commit ttyd
fi

# 兼容 OpenWrt 25.12+：不在首次启动脚本中使用 opkg；如需包操作，优先使用 apk。
if command -v apk >/dev/null 2>&1; then
    echo "apk package manager detected." >>$LOGFILE
elif command -v opkg >/dev/null 2>&1; then
    echo "opkg package manager detected." >>$LOGFILE
fi

# Docker 默认数据目录和防火墙网络归属。
if [ -e /etc/init.d/dockerd ] || command -v dockerd >/dev/null 2>&1; then
    uci -q get dockerd.globals >/dev/null 2>&1 || uci set dockerd.globals=globals
    uci -q get dockerd.dockerman >/dev/null 2>&1 || uci set dockerd.dockerman=dockerman
    uci set dockerd.globals.data_root='/opt/docker/'
    uci set dockerd.globals.log_level='warn'
    uci set dockerd.globals.iptables='1'
    uci set dockerd.globals.auto_start='1'
    uci set dockerd.dockerman.socket_path='/var/run/docker.sock'
    uci set dockerd.dockerman.status_path='/tmp/.docker_action_status'
    uci set dockerd.dockerman.debug='false'
    uci set dockerd.dockerman.debug_path='/tmp/.docker_debug'
    uci set dockerd.dockerman.remote_endpoint='0'
    uci -q delete dockerd.dockerman.ac_allowed_interface
    uci add_list dockerd.dockerman.ac_allowed_interface='br-lan'
    uci commit dockerd

    uci -q delete firewall.docker.network
    uci add_list firewall.docker.network='docker'
    uci commit firewall
fi

# Tailscale 只迁移通用运行参数，不迁移 tailscaled.state 或私网路由广播。
if [ -e /etc/init.d/tailscale ] || command -v tailscaled >/dev/null 2>&1; then
    uci -q get tailscale.settings >/dev/null 2>&1 || uci set tailscale.settings=settings
    uci set tailscale.settings.log_stderr='1'
    uci set tailscale.settings.log_stdout='1'
    uci set tailscale.settings.port='41641'
    uci set tailscale.settings.state_file='/etc/tailscale/tailscaled.state'
    uci set tailscale.settings.fw_mode='nftables'
    uci set tailscale.settings.service_enabled='1'
    uci set tailscale.settings.accept_routes='1'
    uci set tailscale.settings.advertise_exit_node='0'
    uci set tailscale.settings.exit_node_allow_lan_access='1'
    uci set tailscale.settings.runwebclient='1'
    uci set tailscale.settings.nosnat='0'
    uci set tailscale.settings.shields_up='0'
    uci set tailscale.settings.ssh='0'
    uci set tailscale.settings.disable_magic_dns='1'
    uci set tailscale.settings.enable_relay='1'
    uci set tailscale.settings.relay_server_port='42333'
    uci -q delete tailscale.settings.advertise_routes
    uci commit tailscale

    uci -q delete firewall.tailscale
    uci set firewall.tailscale=zone
    uci set firewall.tailscale.name='tailscale'
    uci set firewall.tailscale.input='ACCEPT'
    uci set firewall.tailscale.output='ACCEPT'
    uci set firewall.tailscale.forward='ACCEPT'
    uci set firewall.tailscale.mtu_fix='1'
    uci add_list firewall.tailscale.network='tailscale'
    uci commit firewall
fi

# ddns-go 只启用监听参数，账号和域名配置需要首次登录后手工导入。
if [ -e /etc/init.d/ddns-go ] || command -v ddns-go >/dev/null 2>&1; then
    uci set ddns-go.config=ddns-go
    uci set ddns-go.config.enabled='1'
    uci set ddns-go.config.listen='[::]:9876'
    uci set ddns-go.config.ttl='300'
    uci set ddns-go.config.insecure='1'
    uci commit ddns-go
fi

# Argon 主题偏好。
if [ -f /etc/config/argon ]; then
    uci -q get argon.global >/dev/null 2>&1 || uci set argon.global=global
    uci set argon.global.primary='#5e72e4'
    uci set argon.global.dark_primary='#483d8b'
    uci set argon.global.blur='0'
    uci set argon.global.blur_dark='0'
    uci set argon.global.transparency='0.3'
    uci set argon.global.transparency_dark='0.3'
    uci set argon.global.mode='normal'
    uci set argon.global.online_wallpaper='bing'
    uci commit argon
fi

# Bandix 基础界面参数。
if [ -f /etc/config/bandix ]; then
    uci -q get bandix.general >/dev/null 2>&1 || uci set bandix.general=bandix
    uci -q get bandix.traffic >/dev/null 2>&1 || uci set bandix.traffic=bandix
    uci -q get bandix.connections >/dev/null 2>&1 || uci set bandix.connections=bandix
    uci -q get bandix.dns >/dev/null 2>&1 || uci set bandix.dns=bandix
    uci set bandix.general.iface='br-lan'
    uci set bandix.general.port='8686'
    uci set bandix.general.data_dir='/usr/share/bandix'
    uci set bandix.general.language='auto'
    uci set bandix.general.theme='auto'
    uci set bandix.general.log_level='info'
    uci set bandix.traffic.enabled='0'
    uci set bandix.connections.enabled='0'
    uci set bandix.dns.enabled='0'
    uci commit bandix
fi

# 迁移 IPv6 LAN 路由修复脚本。此脚本不包含设备地址，按运行时 br-lan 前缀动态处理。
mkdir -p /etc/odhcp6c.user.d
cat >/root/fix_ipv6_lan_routes.sh <<'EOF'
#!/bin/sh
set -eu

LAN_IF="${LAN_IF:-br-lan}"
METRIC="${METRIC:-100}"
PUBLIC_SRC="${PUBLIC_SRC:-2000::/3}"
ACTION="${1:-apply}"

find_prefixes() {
    ip -6 route show table main dev "$LAN_IF" 2>/dev/null |
        awk '$1 ~ /^[23][0-9a-fA-F:]*\/[0-9]+$/ { print $1 }' |
        sort -u
}

apply_routes() {
    prefixes="$(find_prefixes)"
    [ -n "$prefixes" ] || {
        echo "No global IPv6 prefix found on $LAN_IF" >&2
        exit 1
    }
    for prefix in $prefixes; do
        echo "Applying routes for $prefix on $LAN_IF metric $METRIC"
        ip -6 route replace "$prefix" dev "$LAN_IF" metric "$METRIC"
        ip -6 route replace "$prefix" from "$prefix" dev "$LAN_IF" metric "$METRIC"
        ip -6 route replace "$prefix" from "$PUBLIC_SRC" dev "$LAN_IF" metric "$METRIC"
    done
}

delete_routes() {
    prefixes="$(find_prefixes)"
    [ -n "$prefixes" ] || {
        echo "No global IPv6 prefix found on $LAN_IF" >&2
        exit 1
    }
    for prefix in $prefixes; do
        echo "Deleting routes for $prefix on $LAN_IF metric $METRIC"
        ip -6 route del "$prefix" dev "$LAN_IF" metric "$METRIC" 2>/dev/null || true
        ip -6 route del "$prefix" from "$prefix" dev "$LAN_IF" metric "$METRIC" 2>/dev/null || true
        ip -6 route del "$prefix" from "$PUBLIC_SRC" dev "$LAN_IF" metric "$METRIC" 2>/dev/null || true
    done
}

case "$ACTION" in
    apply|add|fix)
        apply_routes
        ;;
    delete|del|remove)
        delete_routes
        ;;
    show|status)
        ip -6 route show table main dev "$LAN_IF"
        ;;
    *)
        echo "Usage: $0 [apply|delete|show]" >&2
        exit 2
        ;;
esac
EOF
chmod 0755 /root/fix_ipv6_lan_routes.sh

cat >/etc/odhcp6c.user.d/99-fix-ipv6-lan-routes <<'EOF'
#!/bin/sh

[ "$INTERFACE" = "wan6" ] || exit 0

case "$2" in
    bound|informed|updated|rebound|ra-updated)
        (
            i=0
            while [ "$i" -lt 10 ]; do
                logger -t fix-ipv6-lan-routes "event=$2 interface=$INTERFACE apply attempt=$((i + 1))"
                if /root/fix_ipv6_lan_routes.sh apply 2>&1 | logger -t fix-ipv6-lan-routes; then
                    exit 0
                fi
                i=$((i + 1))
                sleep 2
            done
            logger -t fix-ipv6-lan-routes "failed after retries"
        ) &
        ;;
esac
EOF
chmod 0755 /etc/odhcp6c.user.d/99-fix-ipv6-lan-routes

echo "Migrated YouzaiWrt defaults finished." >>$LOGFILE

exit 0
