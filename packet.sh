#!/bin/bash

# ────────────────────────────────────────────────
#   Packet Tunnel Manager - WaterWall
#   Add / List / Edit / Delete / Logs / Uninstall
# ────────────────────────────────────────────────

Purple='\033[0;35m'
Cyan='\033[0;36m'
YELLOW='\033[0;33m'
White='\033[0;96m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="/root/packet-tunnel"
CORE_FILE="$INSTALL_DIR/core.json"
CONFIG_PREFIX="config"

clear
echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "        Packet Tunnel Manager - WaterWall (2025 edition)"
echo -e "${Purple}══════════════════════════════════════════════════════════════════════${NC}"

# ────────────────────────────── Helper Functions ──────────────────────────────

ensure_core() {
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

setup_service() {
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

list_tunnels() {
  if [ ! -s "$CORE_FILE" ]; then echo -e "${YELLOW}No tunnels yet.${NC}"; return; fi

  echo -e "\n${Purple}Current tunnels:${NC}"
  jq -r '.configs[]' "$CORE_FILE" 2>/dev/null | while read -r conf; do
    f="$INSTALL_DIR/$conf"
    [ -f "$f" ] || { echo -e "${RED}$conf (missing file)${NC}"; continue; }

    name=$(jq -r '.name' "$f" 2>/dev/null)
    dev=$(jq -r '.nodes[] | select(.type=="TunDevice") | .settings["device-name"]' "$f" 2>/dev/null || echo "-")
    port=$(jq -r '.nodes[] | select(.name=="input") | .settings.port' "$f" 2>/dev/null || echo "-")
    proto_key=$(jq -r '.nodes[] | select(.type=="IpManipulator") | .settings | keys[]' "$f" 2>/dev/null || echo "-")
    proto_val=$(jq -r ".nodes[] | select(.type==\"IpManipulator\") | .settings.$proto_key" "$f" 2>/dev/null || echo "-")

    num=${conf#${CONFIG_PREFIX}}
    num=${num%.json}
    echo -e "  ${White}$num)${NC} $conf → $name | dev: $dev | port: $port | $proto_key: $proto_val"
  done
}

update_core() {
  mapfile -t files < <(ls -1 "$INSTALL_DIR"/${CONFIG_PREFIX}*.json 2>/dev/null | xargs -n1 basename)
  if [ ${#files[@]} -eq 0 ]; then
    jq '.configs = []' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
  else
    jq --argjson arr "$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)" '.configs = $arr' "$CORE_FILE" > tmp && mv tmp "$CORE_FILE"
  fi
  echo -e "${Cyan}core.json updated.${NC}"
}

# ────────────────────────────── Add New Tunnel ──────────────────────────────

add_tunnel() {
  ensure_core

  # پیدا کردن بعدی‌ترین شماره
  max=0
  for f in ${CONFIG_PREFIX}*.json; do
    [[ $f =~ ${CONFIG_PREFIX}([0-9]+)\.json ]] && (( ${BASH_REMATCH[1]} > max )) && max=${BASH_REMATCH[1]}
  done
  next=$((max + 1))

  echo -e "\n${Cyan}Adding new tunnel → config${next}.json${NC}"

  read -p "Device name (wtunX) [default wtun$next]: " dev
  dev=${dev:-wtun$next}

  read -p "Private IP Iran (e.g. 10.66.$next.1): " priv_ir
  read -p "Private IP Kharej (e.g. 10.66.$next.2): " priv_kh

  echo -e "\n${Purple}Manipulator:${NC}  1=udp   2=tcp"
  read -p "Type: " ptyp
  proto=$([ "$ptyp" = "2" ] && echo "protoswap-tcp" || echo "protoswap-udp")

  read -p "Protocol number (default 100+$next): " pnum
  pnum=${pnum:-$((100 + next))}

  FAKE_PORT=""
  LIST_TYPE="UdpListener"
  CONN_TYPE="UdpConnector"

  if [[ "$side" == "iran" ]]; then
    read -p "Fake port (e.g. 80,443,53): " FAKE_PORT
    FAKE_PORT=${FAKE_PORT:-80}

    read -p "1=UDP   2=TCP : " ltyp
    [ "$ltyp" = "2" ] && { LIST_TYPE="TcpListener"; CONN_TYPE="TcpConnector"; }
  fi

  read -p "Public IP Iran: " pub_ir
  read -p "Public IP Kharej: " pub_kh

  cat > "config${next}.json" << EOF
{
  "name": "tunnel-${next}",
  "nodes": [
    {
      "name": "mytun",
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
    }
EOF

  if [[ "$side" == "iran" ]]; then
    cat >> "config${next}.json" << EOF
    ,{
      "name": "input",
      "type": "$LIST_TYPE",
      "settings": {
        "address": "0.0.0.0",
        "port": $FAKE_PORT
      },
      "next": "output"
    },
    {
      "name": "output",
      "type": "$CONN_TYPE",
      "settings": {
        "address": "$priv_kh",
        "port": $FAKE_PORT
      }
    }
EOF
  fi

  echo "  ]" >> "config${next}.json"
  echo "}" >> "config${next}.json"

  update_core
  echo -e "${Cyan}Tunnel $next added.${NC}"
}

# ────────────────────────────── Main Loop ──────────────────────────────

ensure_core

while true; do
  echo -e "\n${Purple}Menu:${NC}"
  echo "  1   Add new tunnel"
  echo "  2   List tunnels"
  echo "  3   Edit tunnel"
  echo "  4   Delete tunnel"
  echo "  5   View logs"
  echo "  6   Uninstall all"
  echo "  0   Exit"
  read -p "→ " choice

  case $choice in
    1)  read -p "Iran or Kharej side? (i/k): " side_choice
        side=$([ "$side_choice" = "i" ] && echo "iran" || echo "kharej")
        add_tunnel
        setup_service
        ;;
    2)  list_tunnels ;;
    3)  list_tunnels
        read -p "Edit which number? " en
        ef="config${en}.json"
        [ -f "$ef" ] || { echo -e "${RED}Not found${NC}"; continue; }

        echo "  p = port    d = device    i = private IPs    r = proto+number"
        read -p "What to change? " ec

        case $ec in
          p) read -p "New port: " np
             jq --argjson n "$np" '(.nodes[] | select(.name=="input").settings.port) = $n' "$ef" > tmp && mv tmp "$ef" ;;
          d) read -p "New device: " nd
             jq --arg n "$nd" '(.nodes[] | select(.type=="TunDevice").settings["device-name"]) = $n' "$ef" > tmp && mv tmp "$ef" ;;
          i) read -p "New priv Iran: " ni
             read -p "New priv Kharej: " nk
             jq --arg ni "$ni" --arg nk "$nk" '
               (.nodes[] | select(.type=="TunDevice").settings["device-ip"]) = "\($ni)/24";
               (.nodes[] | select(.settings["ipv4"]=="old_kh")).settings.ipv4 = $nk' "$ef" > tmp && mv tmp "$ef" ;;  # نیاز به تنظیم دقیق‌تر
          r) read -p "New proto (udp/tcpswap): " npr
             read -p "New number: " nnum
             jq --arg k "$npr" --argjson v "$nnum" '(.nodes[] | select(.type=="IpManipulator").settings) = {($k): $v}' "$ef" > tmp && mv tmp "$ef" ;;
          *) echo "Not supported yet" ;;
        esac
        echo -e "${Cyan}Edited.${NC}"
        ;;
    4)  list_tunnels
        read -p "Delete which number? " dn
        rm -f "config${dn}.json" 2>/dev/null && update_core && echo -e "${YELLOW}Deleted.${NC}"
        ;;
    5)  tail -n 60 log/core.log log/network.log 2>/dev/null || echo "No logs"
        read -p "Live tail? (y/n): " lt
        [[ $lt = "y" ]] && tail -f log/*.log
        ;;
    6)  read -p "Really uninstall ALL? (y/N): " uy
        [[ $uy = "y" || $uy = "Y" ]] && {
          systemctl stop waterwall 2>/dev/null
          rm -f /etc/systemd/system/waterwall.service
          rm -rf "$INSTALL_DIR"
          (crontab -l | grep -v waterwall | crontab -)
          echo -e "${YELLOW}Uninstall done.${NC}"
        }
        ;;
    0)  exit 0 ;;
    *)  echo "Invalid choice" ;;
  esac
done
