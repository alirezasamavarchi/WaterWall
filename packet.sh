#!/bin/bash

# Colors
Purple='\033[0;35m'
Cyan='\033[0;36m'
YELLOW='\033[0;33m'
White='\033[0;96m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo "
══════════════════════════════════════════════════════════════════════════════════════
        Packet Tunnel Installer - WaterWall (Multi-Config + Logs)
══════════════════════════════════════════════════════════════════════════════════════
"

# Architecture detection
ARCH=$(uname -m)
if [ "$ARCH" == "aarch64" ]; then
  ASSET_NAME="Waterwall-linux-gcc-arm64.zip"
  echo -e "${Cyan}ARM64 detected → Using gcc-arm64${NC}"
elif [ "$ARCH" == "x86_64" ]; then
  if grep -q " avx512" /proc/cpuinfo; then
    ASSET_NAME="Waterwall-linux-clang-avx512f-x64.zip"
    echo -e "${Cyan}x86_64 with AVX-512 → Using clang-avx512f${NC}"
  else
    ASSET_NAME="Waterwall-linux-clang-x64.zip"
    echo -e "${Cyan}x86_64 detected → Using clang-x64${NC}"
  fi
else
  echo -e "${RED}Unsupported architecture: $ARCH${NC}"
  exit 1
fi

download_and_unzip() {
  local url="$1"
  local dest="$2"
  echo -e "${YELLOW}Downloading $dest...${NC}"
  wget -q --show-progress -O "$dest" "$url"
  unzip -o "$dest"
  chmod +x Waterwall
  rm -f "$dest"
  echo -e "${Cyan}Binary ready. Version: $(./Waterwall --version 2>/dev/null || echo 'unknown')${NC}"
}

get_latest_release_url() {
  curl -s "https://api.github.com/repos/alirezasamavarchi/WaterWall/releases/latest" |
    jq -r ".assets[] | select(.name == \"$ASSET_NAME\") | .browser_download_url"
}

setup_service() {
  cat > /etc/systemd/system/waterwall.service << EOF
[Unit]
Description=WaterWall Packet Tunnel (Multi-Config)
After=network.target

[Service]
ExecStart=/root/packet-tunnel/Waterwall
WorkingDirectory=/root/packet-tunnel
Restart=always
RestartSec=5
User=root
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable waterwall
  systemctl start waterwall
  echo -e "${Cyan}Service created and started.${NC}"
}

show_logs() {
  echo -e "\n${Purple}=== WaterWall Logs ===${NC}"
  echo -e "${Cyan}Last 100 lines of core.log:${NC}"
  tail -n 100 log/core.log 2>/dev/null || echo "No core.log yet"
  echo -e "\n${Cyan}Last 100 lines of network.log:${NC}"
  tail -n 100 log/network.log 2>/dev/null || echo "No network.log yet"
  echo -e "\n${YELLOW}Live tail? (Ctrl+C to stop)${NC}"
  read -p "Press Enter to start live tail or any key to skip: " live
  if [ -z "$live" ]; then
    echo -e "${Purple}Live tail started (network.log + core.log)...${NC}"
    tail -f log/network.log log/core.log 2>/dev/null
  fi
}

# Main menu
while true; do
  echo -e "\n${Purple}Select option:${NC}"
  echo -e "${White}1. Kharej (Foreign side)${NC}"
  echo -e "${Cyan}2. Iran (Local side)${NC}"
  echo -e "${White}3. Uninstall${NC}"
  echo -e "${Cyan}4. View Logs${NC}"
  echo -e "${White}0. Exit${NC}"
  read -p "Choice: " choice

  if [[ "$choice" == "0" ]]; then
    echo "Exiting..."
    break
  fi

  if [[ "$choice" == "4" ]]; then
    cd /root/packet-tunnel 2>/dev/null || echo -e "${RED}No installation found.${NC}"
    show_logs
    read -p "Press Enter to return to menu..." dummy
    continue
  fi

  if [[ "$choice" == "3" ]]; then
    read -p "Are you sure you want to uninstall? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Uninstall cancelled."
      continue
    fi
    systemctl stop waterwall 2>/dev/null
    systemctl disable waterwall 2>/dev/null
    rm -f /etc/systemd/system/waterwall.service
    pkill -f Waterwall 2>/dev/null
    rm -rf /root/packet-tunnel
    (crontab -l 2>/dev/null | grep -v "waterwall") | crontab -
    echo -e "${YELLOW}Uninstall completed successfully.${NC}"
    read -p "Press Enter..." dummy
    continue
  fi

  # ==================== Setup ====================
  mkdir -p /root/packet-tunnel
  cd /root/packet-tunnel

  apt update -y && apt install -y unzip jq wget

  url=$(get_latest_release_url)
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo -e "${RED}Download failed.${NC}"
    exit 1
  fi
  download_and_unzip "$url" "$ASSET_NAME"

  # Number of configs
  read -p "How many tunnels/configs? (1-10): " num_configs
  num_configs=${num_configs:-1}
  [[ "$num_configs" -lt 1 || "$num_configs" -gt 10 ]] && num_configs=1

  configs_array=()
  summary=""

  for ((i=1; i<=num_configs; i++)); do
    echo -e "\n${Cyan}=== Tunnel #$i of $num_configs ===${NC}"

    read -p "Device suffix (e.g. $i → wtun$i): " suffix
    suffix=${suffix:-$i}
    DEVICE="wtun${suffix}"

    read -p "Private IP Iran (e.g. 10.20.${i}.1): " PRIV_IRAN
    read -p "Private IP Kharej (e.g. 10.20.${i}.2): " PRIV_KHAREJ

    echo -e "\n${Purple}IpManipulator:${NC}"
    echo "  1 = protoswap-udp"
    echo "  2 = protoswap-tcp"
    read -p "Type (1 or 2): " ptype
    PROTO=$([ "$ptype" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")

    read -p "Protocol number (0-255) [default 100+$i]: " pnum
    pnum=${pnum:-$((100 + i))}

    # Fake port - ALWAYS manual
    FAKE_PORT=80
    LISTENER_TYPE="UdpListener"
    CONNECTOR_TYPE="UdpConnector"

    if [ "$choice" = "2" ]; then
      read -p "Fake port for this tunnel (e.g. 80): " input_port
      FAKE_PORT=${input_port:-80}

      echo "  1 = UDP    2 = TCP"
      read -p "Type: " ltype
      if [ "$ltype" = "2" ]; then
        LISTENER_TYPE="TcpListener"
        CONNECTOR_TYPE="TcpConnector"
      fi
    fi

    config_file="config${i}.json"
    configs_array+=("\"$config_file\"")

    # ==================== Generate readable config ====================
    if [ "$choice" = "1" ]; then
      read -p "Iran public IP: " IP_IRAN
      IP_KHAREJ=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)

      cat > "$config_file" << EOF
{
  "name": "packet-tunnel-kharej-${i}",
  "nodes": [
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$IP_IRAN"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "source-ip",
        "ipv4": "$IP_KHAREJ"
      },
      "next": "ipovdest"
    },
    {
      "name": "ipovdest",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "dest-ip",
        "ipv4": "$IP_IRAN"
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
      "next": "mytun"
    },
    {
      "name": "mytun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$DEVICE",
        "device-ip": "$PRIV_IRAN/24"
      }
    }
  ]
}
EOF
    else
      read -p "Kharej public IP: " IP_KHAREJ
      IP_IRAN=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)

      cat > "$config_file" << EOF
{
  "name": "packet-tunnel-iran-${i}",
  "nodes": [
    {
      "name": "mytun",
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
        "ipv4": "$IP_IRAN"
      },
      "next": "ipovdest"
    },
    {
      "name": "ipovdest",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "$IP_KHAREJ"
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
        "capture-ip": "$IP_KHAREJ"
      }
    },
    {
      "name": "input",
      "type": "$LISTENER_TYPE",
      "settings": {
        "address": "0.0.0.0",
        "port": $FAKE_PORT
      },
      "next": "output"
    },
    {
      "name": "output",
      "type": "$CONNECTOR_TYPE",
      "settings": {
        "address": "$PRIV_KHAREJ",
        "port": $FAKE_PORT
      }
    }
  ]
}
EOF
    fi

    # Add to summary
    summary+="\nTunnel #$i:\n"
    summary+="   Device     : $DEVICE\n"
    summary+="   Priv Iran  : $PRIV_IRAN/24\n"
    summary+="   Priv Kharej: $PRIV_KHAREJ\n"
    summary+="   Protocol   : $PROTO : $pnum\n"
    [[ "$choice" == "2" ]] && summary+="   Fake Port  : $FAKE_PORT ($LISTENER_TYPE)\n"
    summary+="   Public Iran: $IP_IRAN\n"
    summary+="   Public Kharej: $IP_KHAREJ\n"
  done

  # core.json
  configs_list=$(IFS=, ; echo "${configs_array[*]}")
  cat > core.json << EOF
{
  "log": {
    "path": "log/",
    "core": { "loglevel": "INFO", "file": "core.log", "console": true },
    "network": { "loglevel": "INFO", "file": "network.log", "console": true }
  },
  "misc": { "workers": 0, "ram-profile": "client", "libs-path": "libs/" },
  "configs": [ $configs_list ]
}
EOF

  echo -e "\n${Cyan}All configs created successfully!${NC}"
  echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${White}SUMMARY OF ALL TUNNELS:${NC}"
  echo -e "$summary"
  echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"

  setup_service

  # Auto-restart cron
  echo -e "\n${Purple}Auto-restart to prevent hanging?${NC}"
  echo "  0 = Disable"
  echo " 15/30/60 = minutes"
  read -p "Interval [default 30]: " restart_interval
  restart_interval=${restart_interval:-30}

  if [[ "$restart_interval" =~ ^(15|30|60)$ ]]; then
    (crontab -l 2>/dev/null | grep -v "waterwall") | crontab -
    cron_job="*/$restart_interval * * * * /bin/systemctl restart waterwall.service >/dev/null 2>&1"
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    echo -e "${Cyan}Cron added: restart every $restart_interval minutes${NC}"
  fi

  echo -e "\n${YELLOW}Next steps:${NC}"
  echo "   ip link set wtunX up     (for each device)"
  echo "   Check logs with option 4 in menu"
  echo "   Firewall: open fake ports on Iran side only"

  read -p "Press Enter to return to menu..." dummy
done
