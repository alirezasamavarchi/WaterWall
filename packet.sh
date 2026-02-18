#!/bin/bash

# WaterWall Packet Tunnel Installer - FINAL COMPLETE VERSION
# Fixed: libatomic1, chmod +x, manual binary, readable configs, full edit, cron

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
echo -e "        WaterWall Packet Tunnel Installer - Complete"
echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"

ensure_setup() {
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR" || exit 1

  echo -e "${YELLOW}Installing required packages...${NC}"
  apt update -qq && apt install -y libatomic1 unzip jq wget

  if [ ! -f "Waterwall" ]; then
    echo -e "\n${Purple}Select Waterwall binary:${NC}"
    echo "  1. Auto detect"
    echo "  2. Clang x64 (old/normal CPU)"
    echo "  3. Clang AVX512 (new CPU)"
    echo "  4. GCC ARM64"
    read -p "Choice (1-4): " bchoice

    case $bchoice in
      2) ASSET="Waterwall-linux-clang-x64.zip" ;;
      3) ASSET="Waterwall-linux-clang-avx512f-x64.zip" ;;
      4) ASSET="Waterwall-linux-gcc-arm64.zip" ;;
      *) 
        ARCH=$(uname -m)
        if [ "$ARCH" = "aarch64" ]; then ASSET="Waterwall-linux-gcc-arm64.zip"
        elif grep -q avx512 /proc/cpuinfo; then ASSET="Waterwall-linux-clang-avx512f-x64.zip"
        else ASSET="Waterwall-linux-clang-x64.zip"; fi
        ;;
    esac

    echo -e "${YELLOW}Downloading $ASSET ...${NC}"
    URL=$(curl -s "https://api.github.com/repos/alirezasamavarchi/WaterWall/releases/latest" | jq -r ".assets[] | select(.name==\"$ASSET\") | .browser_download_url")
    [ -z "$URL" ] && { echo -e "${RED}Download failed.${NC}"; exit 1; }

    wget -q --show-progress -O tmp.zip "$URL" && unzip -o tmp.zip && rm tmp.zip
    chmod +x Waterwall
    echo -e "${Cyan}Waterwall ready.${NC}"
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

update_core() {
  mapfile -t files < <(ls -1 config*-*.json 2>/dev/null | xargs -n1 basename)
  jq --argjson arr "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)" '.configs = $arr' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
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
}

setup_cron() {
  read -p "Restart service every how many minutes? (0=disable, 30=recommended): " interval
  interval=${interval:-30}
  (crontab -l 2>/dev/null | grep -v waterwall.service) | crontab -
  if [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
    (crontab -l 2>/dev/null; echo "*/$interval * * * * /bin/systemctl restart waterwall.service >/dev/null 2>&1") | crontab -
    echo -e "${Cyan}Cron set.${NC}"
  else
    echo -e "${YELLOW}Cron disabled.${NC}"
  fi
}

list_tunnels() {
  echo -e "\n${Purple}Current configs:${NC}"
  ls -1 config*-*.json 2>/dev/null | while read f; do echo "  - $f"; done || echo "No configs."
}

edit_tunnel() {
  list_tunnels
  read -p "Tunnel ID (e.g. 1): " id
  echo -e "\nWhich file?"
  echo "1 = config${id}-iran.json"
  echo "2 = config${id}-kharej.json"
  read -p "Choose: " s
  file="config${id}-$( [ "$s" = "1" ] && echo "iran" || echo "kharej" ).json"

  [ ! -f "$file" ] && { echo -e "${RED}File not found.${NC}"; return; }

  echo -e "\nEdit options:"
  echo "  p = Fake port (Iran only)"
  echo "  d = Device name"
  echo "  i = Private IPs"
  echo "  r = Protocol + number"
  read -p "Choice: " e

  case $e in
    p) read -p "New port: " np
       jq --argjson n "$np" '(.nodes[] | select(.name=="input").settings.port) = $n' "$file" > tmp && mv tmp "$file" ;;
    d) read -p "New device: " nd
       jq --arg n "$nd" '(.nodes[] | select(.type=="TunDevice").settings["device-name"]) = $n' "$file" > tmp && mv tmp "$file" ;;
    i) read -p "New Priv Iran: " ni
       read -p "New Priv Kharej: " nk
       jq --arg ni "$ni" --arg nk "$nk" '(.nodes[] | select(.type=="TunDevice").settings["device-ip"]) = "\($ni)/24"' "$file" > tmp && mv tmp "$file" ;;
    r) echo "1=udp 2=tcp"; read -p "Type: " nt
       pr=$([ "$nt" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")
       read -p "Number: " nn
       jq --arg k "$pr" --argjson v "$nn" '(.nodes[] | select(.type=="IpManipulator").settings) = {($k): $v}' "$file" > tmp && mv tmp "$file" ;;
    *) echo "Invalid" ;;
  esac
  echo -e "${Cyan}Updated. Restart service to apply.${NC}"
}

create_iran_config() {
  ensure_setup
  max=0
  for f in config*-iran.json; do [[ $f =~ ([0-9]+) ]] && (( ${BASH_REMATCH[1]} > max )) && max=${BASH_REMATCH[1]}; done
  id=$((max+1))

  echo -e "\n${Cyan}Iran config #$id${NC}"
  read -p "Device (wtun$id): " dev; dev=${dev:-wtun$id}
  read -p "Priv Iran: " priv_ir
  read -p "Priv Kharej: " priv_kh
  read -p "Pub Iran: " pub_ir
  read -p "Pub Kharej: " pub_kh

  echo "1=udp 2=tcp"
  read -p "Manip type: " t; proto=$([ "$t" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")
  read -p "Number (112): " pnum; pnum=${pnum:-112}

  read -p "Fake port (443): " port; port=${port:-443}
  echo "1=UDP 2=TCP"
  read -p "Listener type: " lt
  listener=$([ "$lt" = "2" ] && echo "TcpListener" || echo "UdpListener")
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

create_kharej_config() {
  ensure_setup
  max=0
  for f in config*-kharej.json; do [[ $f =~ ([0-9]+) ]] && (( ${BASH_REMATCH[1]} > max )) && max=${BASH_REMATCH[1]}; done
  id=$((max+1))

  echo -e "\n${Cyan}Kharej config #$id${NC}"
  read -p "Device (wtun$id): " dev; dev=${dev:-wtun$id}
  read -p "Priv Iran: " priv_ir
  read -p "Priv Kharej: " priv_kh
  read -p "Pub Iran: " pub_ir
  read -p "Pub Kharej: " pub_kh

  echo "1=udp 2=tcp"
  read -p "Manip type: " t; proto=$([ "$t" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")
  read -p "Number (112): " pnum; pnum=${pnum:-112}

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

# Main menu
ensure_setup

while true; do
  echo -e "\n${Purple}Menu:${NC}"
  echo "  1. Create Iran config only"
  echo "  2. Create Kharej config only"
  echo "  3. List current configs"
  echo "  4. Edit existing config"
  echo "  5. Setup auto-restart cron"
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
        echo -e "${YELLOW}Uninstall complete.${NC}"
      }
      ;;
    0) exit 0 ;;
    *) echo -e "${RED}Invalid${NC}" ;;
  esac
done
