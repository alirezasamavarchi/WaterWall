#!/bin/bash

# Colors
Purple='\033[0;35m'
Cyan='\033[0;36m'
YELLOW='\033[0;33m'
White='\033[0;96m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="/root/packet-tunnel"
CORE_FILE="$INSTALL_DIR/core.json"

clear
echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "        WaterWall Packet Tunnel Installer (Iran + Kharej + Cron)"
echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"

ensure_setup() {
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || exit 1

  if [ ! -f "Waterwall" ]; then
    echo -e "${YELLOW}Downloading Waterwall binary...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ]; then ASSET="Waterwall-linux-gcc-arm64.zip"; fi
    if [ "$ARCH" = "x86_64" ]; then
      if grep -q avx512 /proc/cpuinfo; then ASSET="Waterwall-linux-clang-avx512f-x64.zip"
      else ASSET="Waterwall-linux-clang-x64.zip"; fi
    fi
    URL=$(curl -s "https://api.github.com/repos/alirezasamavarchi/WaterWall/releases/latest" | jq -r ".assets[] | select(.name==\"$ASSET\") | .browser_download_url")
    [ -z "$URL" ] && { echo -e "${RED}Failed to get download URL.${NC}"; exit 1; }
    wget -q --show-progress -O tmp.zip "$URL" && unzip -o tmp.zip && chmod +x Waterwall && rm tmp.zip
  fi

  if [ ! -f "$CORE_FILE" ]; then
    cat > "$CORE_FILE" << 'EOF'
{
  "log": {
    "path": "log/",
    "core": { "loglevel": "INFO", "file": "core.log", "console": true },
    "network": { "loglevel": "INFO", "file": "network.log", "console": true }
  },
  "misc": { "workers": 0, "ram-profile": "client", "libs-path": "libs/" },
  "configs": []
}
EOF
  fi
}

update_core_configs() {
  mapfile -t files < <(ls -1 "$INSTALL_DIR"/config*-*.json 2>/dev/null | xargs -n1 basename)
  if [ ${#files[@]} -eq 0 ]; then
    jq '.configs = []' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
  else
    jq --argjson arr "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)" '.configs = $arr' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
  fi
  echo -e "${Cyan}core.json updated (${#files[@]} configs loaded)${NC}"
}

create_service() {
  cat > /etc/systemd/system/waterwall.service << EOF
[Unit]
Description=WaterWall Packet Tunnel
After=network.target

[Service]
ExecStart=$INSTALL_DIR/Waterwall
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=5
User=root
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now waterwall
  echo -e "${Cyan}Service created and started.${NC}"
}

setup_auto_restart() {
  echo -e "\n${Purple}Enable auto-restart to prevent hanging?${NC}"
  echo "  0 = Disable"
  echo " 15 = Every 15 minutes"
  echo " 30 = Every 30 minutes (recommended)"
  echo " 60 = Every 60 minutes"
  read -p "Interval in minutes (default 30): " interval
  interval=${interval:-30}

  # Remove old waterwall cron jobs
  (crontab -l 2>/dev/null | grep -v "waterwall.service") | crontab -

  if [[ "$interval" =~ ^(15|30|60)$ ]]; then
    cron_job="*/$interval * * * * /bin/systemctl restart waterwall.service >/dev/null 2>&1 # Waterwall auto-restart"
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    echo -e "${Cyan}Cron added: restart every $interval minutes${NC}"
  else
    echo -e "${YELLOW}Auto-restart disabled.${NC}"
  fi
}

# ────────────────────────────── Create Tunnel Pair ──────────────────────────────

create_tunnel_pair() {
  ensure_setup

  # Find next ID
  max_id=0
  for f in config*-iran.json; do
    [[ $f =~ config([0-9]+)-iran.json ]] && (( ${BASH_REMATCH[1]} > max_id )) && max_id=${BASH_REMATCH[1]}
  done
  next_id=$((max_id + 1))

  echo -e "\n${Cyan}Creating tunnel pair #$next_id${NC}"

  read -p "Device name (e.g. wtun$next_id): " DEVICE
  DEVICE=${DEVICE:-wtun$next_id}

  read -p "Private IP Iran (e.g. 10.10.$next_id.1): " PRIV_IRAN
  read -p "Private IP Kharej (e.g. 10.10.$next_id.2): " PRIV_KHAREJ

  echo -e "\n${Purple}IpManipulator settings:${NC}"
  echo "  1 = protoswap-udp"
  echo "  2 = protoswap-tcp"
  read -p "Choose (1 or 2): " ptype
  PROTO=$([ "$ptype" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")

  read -p "Protocol number (0-255) [default 112]: " pnum
  pnum=${pnum:-112}

  FAKE_PORT=""
  LISTENER_TYPE="UdpListener"
  CONNECTOR_TYPE="UdpConnector"

  read -p "Public IP Iran: " PUB_IRAN
  read -p "Public IP Kharej: " PUB_KHAREJ

  if [ "$side" = "iran" ]; then
    read -p "Fake port (e.g. 80, 443, 53): " FAKE_PORT
    FAKE_PORT=${FAKE_PORT:-443}

    echo "  1 = UDP    2 = TCP"
    read -p "Listener type: " ltype
    [ "$ltype" = "2" ] && { LISTENER_TYPE="TcpListener"; CONNECTOR_TYPE="TcpConnector"; }
  fi

  # ─── Iran config ───
  cat > "config${next_id}-iran.json" << EOF
{
  "name": "packet-tunnel-iran-${next_id}",
  "nodes": [
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$DEVICE",
        "device-ip": "$PRIV_IRAN/24"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "source-ip",
        "ipv4": "$PUB_IRAN"
      },
      "next": "ipovdest"
    },
    {
      "name": "ipovdest",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "$PUB_KHAREJ"
      },
      "next": "manip"
    },
    {
      "name": "manip",
      "type": "IpManipulator",
      "settings": {
        "$PROTO": $pnum
      },
      "next": "ipovsrc2"
    },
    {
      "name": "ipovsrc2",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "source-ip",
        "ipv4": "$PRIV_KHAREJ"
      },
      "next": "ipovdest2"
    },
    {
      "name": "ipovdest2",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "dest-ip",
        "ipv4": "$PRIV_IRAN"
      },
      "next": "rd"
    },
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$PUB_KHAREJ"
      }
    },
    {
      "name": "input",
      "type": "$LISTENER_TYPE",
      "settings": {
        "address": "0.0.0.0",
        "port": $FAKE_PORT,
        "nodelay": true
      },
      "next": "output"
    },
    {
      "name": "output",
      "type": "$CONNECTOR_TYPE",
      "settings": {
        "nodelay": true,
        "address": "$PRIV_KHAREJ",
        "port": $FAKE_PORT
      }
    }
  ]
}
EOF

  # ─── Kharej config ───
  cat > "config${next_id}-kharej.json" << EOF
{
  "name": "packet-tunnel-kharej-${next_id}",
  "nodes": [
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$PUB_IRAN"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "source-ip",
        "ipv4": "$PUB_KHAREJ"
      },
      "next": "ipovdest"
    },
    {
      "name": "ipovdest",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "dest-ip",
        "ipv4": "$PUB_IRAN"
      },
      "next": "manip"
    },
    {
      "name": "manip",
      "type": "IpManipulator",
      "settings": {
        "$PROTO": $pnum
      },
      "next": "ipovsrc2"
    },
    {
      "name": "ipovsrc2",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "source-ip",
        "ipv4": "$PRIV_KHAREJ"
      },
      "next": "ipovdest2"
    },
    {
      "name": "ipovdest2",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "$PRIV_IRAN"
      },
      "next": "my tun"
    },
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$DEVICE",
        "device-ip": "$PRIV_IRAN/24"
      }
    }
  ]
}
EOF

  update_core_configs
  echo -e "\n${Cyan}Tunnel pair #$next_id created:${NC}"
  echo "  config${next_id}-iran.json"
  echo "  config${next_id}-kharej.json"
  echo ""
  echo "Device: $DEVICE"
  echo "Private IP Iran: $PRIV_IRAN/24"
  echo "Private IP Kharej: $PRIV_KHAREJ"
  echo "Protocol: $PROTO : $pnum"
  [ -n "$FAKE_PORT" ] && echo "Fake port (Iran): $FAKE_PORT"
  echo "Public IP Iran: $PUB_IRAN"
  echo "Public IP Kharej: $PUB_KHAREJ"
}

# ────────────────────────────── Main Loop ──────────────────────────────

while true; do
  echo -e "\n${Purple}Select option:${NC}"
  echo "  1. Create new tunnel pair (Iran + Kharej)"
  echo "  2. Setup / change auto-restart cron"
  echo "  3. Show current cron jobs"
  echo "  4. Uninstall everything"
  echo "  0. Exit"
  read -p "Choice: " choice

  case $choice in
    1)
      read -p "Which side are you configuring now? (i = Iran / k = Kharej): " s
      side=$([ "$s" = "i" ] && echo "iran" || echo "kharej")
      create_tunnel_pair
      create_service
      setup_auto_restart
      ;;
    2)
      setup_auto_restart
      ;;
    3)
      echo -e "\n${Cyan}Current crontab entries for Waterwall:${NC}"
      crontab -l | grep -i waterwall || echo "No cron jobs found for waterwall"
      ;;
    4)
      read -p "Are you sure you want to uninstall everything? (y/N): " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        systemctl stop waterwall 2>/dev/null
        systemctl disable waterwall 2>/dev/null
        rm -f /etc/systemd/system/waterwall.service
        pkill -f Waterwall 2>/dev/null
        rm -rf "$INSTALL_DIR"
        (crontab -l 2>/dev/null | grep -v "waterwall.service") | crontab -
        echo -e "${YELLOW}Uninstall completed.${NC}"
      fi
      ;;
    0)
      echo "Exiting..."
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid choice${NC}"
      ;;
  esac
done
