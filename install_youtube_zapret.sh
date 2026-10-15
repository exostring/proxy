#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

SRC_DIR="/opt/zapret-classic"
HOSTLIST_DIR="/etc/zapret"
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
  if [[ -n "$(git -C "$SRC_DIR" status --porcelain)" ]]; then
    echo "Working tree $SRC_DIR is not clean; refusing to overwrite it." >&2
    exit 1
  fi
  git -C "$SRC_DIR" fetch --depth=1 origin master
  git -C "$SRC_DIR" reset --hard origin/master
elif [[ -e "$SRC_DIR" ]]; then
  echo "$SRC_DIR exists but is not a Git checkout; refusing to remove it." >&2
  exit 1
else
  git clone --depth=1 https://github.com/bol-van/zapret.git "$SRC_DIR"
fi

make -C "$SRC_DIR/nfq" -j"$(nproc)"
install -m 0755 "$SRC_DIR/nfq/nfqws" "$NFQWS_BIN"

mkdir -p "$HOSTLIST_DIR"

cat > "$HOSTLIST_DIR/youtube.txt" <<'EOF'
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

cat > "$HOSTLIST_DIR/youtubei.txt" <<'EOF'
youtubei.googleapis.com
EOF

NFQWS_ARGS=(
  --qnum=200

  --filter-tcp=80
  --filter-l7=http
  --hostlist="$HOSTLIST_DIR/youtube.txt"
  --dpi-desync=fake,multisplit
  --dpi-desync-split-pos=method+2
  --dpi-desync-fooling=md5sig
  --new

  --filter-tcp=443
  --filter-l7=tls
  --hostlist="$HOSTLIST_DIR/youtubei.txt"
  --dpi-desync=multidisorder
  --dpi-desync-split-pos=host+1
  --new

  --filter-tcp=443
  --filter-l7=tls
  --hostlist="$HOSTLIST_DIR/youtube.txt"
  --dpi-desync=fake,multidisorder
  --dpi-desync-split-pos=1,midsld
  --dpi-desync-fooling=badseq,md5sig
  --new

  --filter-udp=443
  --filter-l7=quic
  --hostlist="$HOSTLIST_DIR/youtube.txt"
  --dpi-desync=fake
  --dpi-desync-repeats=6
  --dpi-desync-fake-quic="$SRC_DIR/files/fake/quic_initial_www_google_com.bin"
)

"$NFQWS_BIN" --dry-run "${NFQWS_ARGS[@]}"

printf -v NFQWS_COMMAND '%s ' "$NFQWS_BIN" "${NFQWS_ARGS[@]}"
NFQWS_COMMAND="${NFQWS_COMMAND% }"

cat > "$NFT_START" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if nft list table inet zapret >/dev/null 2>&1; then
  nft delete table inet zapret
fi

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

if nft list table inet zapret >/dev/null 2>&1; then
  nft delete table inet zapret
fi
EOF

chmod 0755 "$NFT_START" "$NFT_STOP"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=zapret DPI bypass for YouTube
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$NFT_START
ExecStart=$NFQWS_COMMAND
ExecStopPost=$NFT_STOP
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Stop zapret2 if this server has it, then remove any leftover table.
if systemctl cat zapret2.service >/dev/null 2>&1; then
  systemctl disable --now zapret2.service
fi

if nft list table inet zapret2 >/dev/null 2>&1; then
  nft delete table inet zapret2
fi

systemctl daemon-reload
systemctl enable zapret.service
systemctl restart zapret.service

echo
systemctl is-active zapret.service
systemctl status zapret.service --no-pager -l
