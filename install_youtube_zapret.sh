#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

SRC_DIR="/opt/zapret-classic"
HOSTLIST_DIR="/etc/zapret"
HOSTLIST_FILE="$HOSTLIST_DIR/youtube.txt"
NFQWS_BIN="/usr/local/bin/nfqws"
NFT_START="/usr/local/sbin/zapret-nft-start.sh"
NFT_STOP="/usr/local/sbin/zapret-nft-stop.sh"
SERVICE_FILE="/etc/systemd/system/zapret.service"

apt-get update
apt-get install -y --no-install-recommends \
  git \
  build-essential \
  pkg-config \
  libcap-dev \
  zlib1g-dev \
  libnetfilter-queue-dev \
  libnfnetlink-dev \
  libmnl-dev \
  nftables

if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" fetch --depth=1 origin master
  git -C "$SRC_DIR" reset --hard origin/master
else
  rm -rf "$SRC_DIR"
  git clone --depth=1 https://github.com/bol-van/zapret.git "$SRC_DIR"
fi

make -C "$SRC_DIR/nfq" -j"$(nproc)"
install -m 0755 "$SRC_DIR/nfq/nfqws" "$NFQWS_BIN"

mkdir -p "$HOSTLIST_DIR"
cat > "$HOSTLIST_FILE" <<'EOF'
youtube.com
www.youtube.com
m.youtube.com
youtubei.googleapis.com
yt3.ggpht.com
yt3.googleusercontent.com
i.ytimg.com
www.ytimg.com
s.ytimg.com
img.youtube.com
ggpht.com
googleusercontent.com
googlevideo.com
redirector.googlevideo.com
r*.googlevideo.com
r1---*.googlevideo.com
r2---*.googlevideo.com
r3---*.googlevideo.com
r4---*.googlevideo.com
r5---*.googlevideo.com
r6---*.googlevideo.com
r7---*.googlevideo.com
r8---*.googlevideo.com
r9---*.googlevideo.com
*.googlevideo.com
*.ytimg.com
*.ggpht.com
*.googleusercontent.com
gstatic.com
*.gstatic.com
accounts.google.com
EOF

cat > "$NFT_START" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

nft list table inet zapret >/dev/null 2>&1 && nft delete table inet zapret || true

nft -f - <<'NFT'
table inet zapret {
  chain postnat_hook {
    type filter hook postrouting priority srcnat + 1; policy accept;
    udp dport 443 ct original packets 1-12 queue flags bypass to 200
    tcp dport {80,443} ct original packets 1-12 queue flags bypass to 200
  }

  chain prenat_hook {
    type filter hook prerouting priority dstnat + 1; policy accept;
    udp sport 443 ct reply packets 1-3 queue flags bypass to 200
    tcp sport {80,443} ct reply packets 1-6 queue flags bypass to 200
  }
}
NFT
EOF

cat > "$NFT_STOP" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
nft delete table inet zapret >/dev/null 2>&1 || true
EOF

chmod 0755 "$NFT_START" "$NFT_STOP"

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=zapret DPI bypass for YouTube
After=network.target

[Service]
Type=forking
ExecStartPre=/usr/local/sbin/zapret-nft-start.sh
ExecStart=/usr/local/bin/nfqws --daemon --dpi-desync-ttl=2 --dpi-desync-fooling=badseq,md5sig --hostlist=/etc/zapret/youtube.txt --qnum=200
ExecStop=/bin/sh -c 'pkill -x nfqws || true'
ExecStopPost=/usr/local/sbin/zapret-nft-stop.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

if systemctl list-unit-files | grep -q '^zapret2\.service'; then
  systemctl disable --now zapret2.service || true
fi

systemctl daemon-reload
systemctl enable --now zapret.service

echo
systemctl is-active zapret.service
systemctl status zapret.service --no-pager -l || true
