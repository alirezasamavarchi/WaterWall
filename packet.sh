#!/bin/bash

# WaterWall Packet Tunnel Installer - Complete Version
# Features: libatomic1, chmod +x, readable configs, Edit, Cron, Uninstall

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
echo -e "        WaterWall Packet Tunnel Installer (Iran / Kharej)"
echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"

ensure_setup() {
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || exit 1

  echo -e "${YELLOW}Installing required packages (libatomic1, unzip, jq, wget)...${NC}"
  apt update -qq && apt install -y libatomic1 unzip jq wget

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
    wget -q --show-progress -O tmp.zip "$URL" && unzip -o tmp.zip && rm tmp.zip

    chmod +x Waterwall
    echo -e "${Cyan}Waterwall is now executable.${NC}"
  fi

  if [ ! -f "$CORE_FILE" ]; then
    cat > "$CORE_FILE" << 'EOF'
{
  "log": {
    "path": "log/",
    "core": {
      "loglevel": "INFO",
      "file": "core.log",
      "console": true
    },
    "network": {
      "loglevel": "INFO",
      "file": "network.log",
      "console": true
    }
  },
  "misc": {
    "workers": 0,
    "ram-profile": "client",
    "libs-path": "libs/"
  },
  "configs": []
}
EOF
  fi
}

update_core() {
  mapfile -t files < <(ls -1 "$INSTALL_DIR"/config*-*.json 2>/dev/null | xargs -n1 basename)
  if [ ${#files[@]} -eq 0 ]; then
    jq '.configs = []' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
  else
    jq --argjson arr "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)" '.configs = $arr' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
  fi
  echo -e "${Cyan}core.json updated (${#files[@]} configs).${NC}"
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

setup_cron() {
  read -p "Auto-restart every how many minutes? (0=disable, recommended 30): " interval
  interval=${interval:-30}

  (crontab -l 2>/dev/null | grep -v "waterwall.service") | crontab -

  if [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
    cron="*/$interval * * * * /bin/systemctl restart waterwall.service >/dev/null 2>&1"
    (crontab -l 2>/dev/null; echo "$cron") | crontab -
    echo -e "${Cyan}Cron added: restart every $interval minutes${NC}"
  else
    echo -e "${YELLOW}Auto-restart disabled.${NC}"
  fi
}

list_tunnels() {
  echo -e "\n${Purple}Current configs:${NC}"
  ls -1 config*-*.json 2>/dev/null | while read -r f; do
    echo "  - $f"
  done || echo "No configs yet."
}

edit_tunnel() {
  list_tunnels
  read -p "Enter tunnel ID to edit (e.g. 1): " id

  iran_file="config${id}-iran.json"
  if [ ! -f "$iran_file" ]; then
    echo -e "${RED}Config for ID $id not found.${NC}"
    return
  fi

  echo -e "\nEditing config${id}-iran.json"
  echo "  p = Fake port"
  echo "  d = Device name"
  echo "  i = Private IPs"
  echo "  r = Protocol + number"
  read -p "Choice (p/d/i/r): " opt

  case $opt in
    p)
      read -p "New fake port: " np
      jq --argjson n "$np" '(.nodes[] | select(.name=="input").settings.port) = $n' "$iran_file" > tmp.json && mv tmp.json "$iran_file"
      ;;
    d)
      read -p "New device name: " nd
      jq --arg n "$nd" '(.nodes[] | select(.type=="TunDevice").settings["device-name"]) = $n' "$iran_file" > tmp.json && mv tmp.json "$iran_file"
      ;;
    i)
      read -p "New Private IP Iran: " ni
      read -p "New Private IP Kharej: " nk
      jq --arg ni "$ni" --arg nk "$nk" '
        (.nodes[] | select(.type=="TunDevice").settings["device-ip"]) = "\($ni)/24";
        (.nodes[] | select(.settings.ipv4 == "old_kh").settings.ipv4) = $nk  # adjust selector if needed
      ' "$iran_file" > tmp.json && mv tmp.json "$iran_file"
      ;;
    r)
      echo "1 = protoswap-udp   2 = protoswap-tcp"
      read -p "New type: " nt
      pr=$([ "$nt" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")
      read -p "New number: " nn
      jq --arg k "$pr" --argjson v "$nn" '(.nodes[] | select(.type=="IpManipulator").settings) = {($k): $v}' "$iran_file" > tmp.json && mv tmp.json "$iran_file"
      ;;
    *) echo "Invalid" ;;
  esac

  echo -e "${Cyan}Updated. Restart service to apply: systemctl restart waterwall${NC}"
}

# ────────────────────────────── Create Iran Config ──────────────────────────────
create_iran_config() {
  ensure_setup

  max=0
  for f in config*-iran.json; do
    [[ $f =~ config([0-9]+)-iran ]] && ((BASH_REMATCH[1] > max)) && max=${BASH_REMATCH[1]}
  done
  id=$((max + 1))

  echo -e "\n${Cyan}Creating Iran config #$id${NC}"

  read -p "Device name (default wtun$id): " dev; dev=${dev:-wtun$id}
  read -p "Private IP Iran: " priv_ir
  read -p "Private IP Kharej: " priv_kh
  read -p "Public IP Iran: " pub_ir
  read -p "Public IP Kharej: " pub_kh

  echo "IpManipulator: 1=udp  2=tcp"
  read -p "Type: " t; proto=$([ "$t" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")
  read -p "Protocol number (default 112): " pnum; pnum=${pnum:-112}

  read -p "Fake port: " port; port=${port:-443}
  echo "1=UDP  2=TCP"
  read -p "Type: " lt; listener=$([ "$lt" = "2" ] && echo "TcpListener" || echo "UdpListener")
  connector=$([ "$lt" = "2" ] && echo "TcpConnector" || echo "UdpConnector")

  cat > "config${id}-iran.json" << EOF
{
  "name": "packet-tunnel-iran-${id}",
  "nodes": [
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$dev",
        "device-ip": "$priv_ir/24"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "source-ip",
        "ipv4": "$pub_ir"
      },
      "next": "ipovdest"
    },
    {
      "name": "ipovdest",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "$pub_kh"
      },
      "next": "manip"
    },
    {
      "name": "manip",
      "type": "IpManipulator",
      "settings": {
        "$proto": $pnum
      },
      "next": "ipovsrc2"
    },
    {
      "name": "ipovsrc2",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "source-ip",
        "ipv4": "$priv_kh"
      },
      "next": "ipovdest2"
    },
    {
      "name": "ipovdest2",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "dest-ip",
        "ipv4": "$priv_ir"
      },
      "next": "rd"
    },
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$pub_kh"
      }
    },
    {
      "name": "input",
      "type": "$listener",
      "settings": {
        "address": "0.0.0.0",
        "port": $port,
        "nodelay": true
      },
      "next": "output"
    },
    {
      "name": "output",
      "type": "$connector",
      "settings": {
        "nodelay": true,
        "address": "$priv_kh",
        "port": $port
      }
    }
  ]
}
EOF

  update_core
  echo -e "${Cyan}Iran config created.${NC}"
}

# ────────────────────────────── Create Kharej Config ──────────────────────────────
create_kharej_config() {
  ensure_setup

  max=0
  for f in config*-kharej.json; do
    [[ $f =~ config([0-9]+)-kharej ]] && ((BASH_REMATCH[1] > max)) && max=${BASH_REMATCH[1]}
  done
  id=$((max + 1))

  echo -e "\n${Cyan}Creating Kharej config #$id${NC}"

  read -p "Device name (default wtun$id): " dev; dev=${dev:-wtun$id}
  read -p "Private IP Iran: " priv_ir
  read -p "Private IP Kharej: " priv_kh
  read -p "Public IP Iran: " pub_ir
  read -p "Public IP Kharej: " pub_kh

  echo "IpManipulator: 1=udp  2=tcp"
  read -p "Type: " t; proto=$([ "$t" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")
  read -p "Protocol number (default 112): " pnum; pnum=${pnum:-112}

  cat > "config${id}-kharej.json" << EOF
{
  "name": "packet-tunnel-kharej-${id}",
  "nodes": [
    {
      "name": "rd",
      "type": "RawSocket",
      "settings": {
        "capture-filter-mode": "source-ip",
        "capture-ip": "$pub_ir"
      },
      "next": "ipovsrc"
    },
    {
      "name": "ipovsrc",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "source-ip",
        "ipv4": "$pub_kh"
      },
      "next": "ipovdest"
    },
    {
      "name": "ipovdest",
      "type": "IpOverrider",
      "settings": {
        "direction": "down",
        "mode": "dest-ip",
        "ipv4": "$pub_ir"
      },
      "next": "manip"
    },
    {
      "name": "manip",
      "type": "IpManipulator",
      "settings": {
        "$proto": $pnum
      },
      "next": "ipovsrc2"
    },
    {
      "name": "ipovsrc2",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "source-ip",
        "ipv4": "$priv_kh"
      },
      "next": "ipovdest2"
    },
    {
      "name": "ipovdest2",
      "type": "IpOverrider",
      "settings": {
        "direction": "up",
        "mode": "dest-ip",
        "ipv4": "$priv_ir"
      },
      "next": "my tun"
    },
    {
      "name": "my tun",
      "type": "TunDevice",
      "settings": {
        "device-name": "$dev",
        "device-ip": "$priv_ir/24"
      }
    }
  ]
}
EOF

  update_core
  echo -e "${Cyan}Kharej config created.${NC}"
}

# ────────────────────────────── Main Loop ──────────────────────────────

while true; do
  echo -e "\n${Purple}Select option:${NC}"
  echo "  1. Create Iran config only"
  echo "  2. Create Kharej config only"
  echo "  3. List current configs"
  echo "  4. Edit existing config"
  echo "  5. Setup / change auto-restart cron"
  echo "  6. Uninstall everything"
  echo "  0. Exit"
  read -p "Choice: " ch

  case $ch in
    1) create_iran_config; create_service; setup_cron ;;
    2) create_kharej_config; create_service; setup_cron ;;
    3) list_tunnels ;;
    4) edit_tunnel ;;
    5) setup_cron ;;
    6)
      read -p "Uninstall ALL? (y/N): " y
      [[ "$y" =~ ^[Yy]$ ]] && {
        systemctl stop waterwall 2>/dev/null
        systemctl disable waterwall 2>/dev/null
        rm -f /etc/systemd/system/waterwall.service
        pkill -f Waterwall 2>/dev/null
        rm -rf "$INSTALL_DIR"
        (crontab -l 2>/dev/null | grep -v "waterwall.service") | crontab -
        echo -e "${YELLOW}Uninstall completed.${NC}"
      }
      ;;
    0) echo "Exiting..."; exit 0 ;;
    *) echo -e "${RED}Invalid${NC}" ;;
  esac
done
