#!/bin/bash

set -e

echo "=============================="
echo "VPN INSTALLER - SETUP"
echo "=============================="

read -p "🌐 Домен (например your-domain.com): " DOMAIN
DOMAIN=${DOMAIN:-your-domain.com}

read -p "📧 Email для SSL (example@example.com): " EMAIL
EMAIL=${EMAIL:-example@example.com}

read -p "🎭 Fake site (https://demo.cloudreve.org): " FAKE_SITE
FAKE_SITE=${FAKE_SITE:-https://demo.cloudreve.org}

read -p "👤 Username (оставь пустым = авто): " USER_NAME
read -p "🔑 Password (оставь пустым = авто): " USER_PASS

read -p "⚡ Установить WARP? (y/n): " WARP_INPUT
INSTALL_WARP=false
if [[ "$WARP_INPUT" == "y" || "$WARP_INPUT" == "Y" ]]; then
  INSTALL_WARP=true
fi

echo ""
echo "[+] Обновление системы..."
apt update -y && apt upgrade -y

echo "[+] Установка базовых пакетов..."
apt install -y wget curl tar openssl gnupg lsb-release

echo "[+] Включение BBR..."
grep -q "fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

echo "[+] Установка Go..."
cd /tmp
wget -q https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz

export PATH=$PATH:/usr/local/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.profile

echo "[+] Установка xcaddy..."
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

echo "[+] Подготовка TMP..."
mkdir -p /root/tmp
export TMPDIR=/root/tmp

echo "[+] Сборка Caddy..."
~/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive

echo "[+] Генерация логина/пароля..."

if [ -z "$USER_NAME" ]; then
  USER_NAME=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 12)
fi

if [ -z "$USER_PASS" ]; then
  USER_PASS=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)
fi

echo "Логин: $USER_NAME"
echo "Пароль: $USER_PASS"

echo "[+] Создание конфигурации Caddy..."
mkdir -p /etc/caddy

cat <<EOF > /etc/caddy/Caddyfile
:443, $DOMAIN
tls $EMAIL

route {
 forward_proxy {
   basic_auth $USER_NAME $USER_PASS
   hide_ip
   hide_via
   probe_resistance
 }

 reverse_proxy $FAKE_SITE {
   header_up Host {upstream_hostport}
   header_up X-Forwarded-Host {host}
 }
}
EOF

echo "[+] Установка Caddy..."
mv caddy /usr/bin/caddy
chmod +x /usr/bin/caddy

echo "[+] systemd сервис..."
cat <<EOF > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=always
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now caddy

echo "[+] Запуск..."
caddy start --config /etc/caddy/Caddyfile || true

### ===== WARP =====
if [ "$INSTALL_WARP" = true ]; then
  echo "[+] Установка WARP..."

  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflare-client.list

  apt update
  apt install -y cloudflare-warp

  warp-cli registration new
  warp-cli mode proxy
  warp-cli connect

  echo "[!] Добавь в Caddyfile:"
  echo "upstream socks5://127.0.0.1:40000"
fi

echo ""
echo "=============================="
echo "ГОТОВО 🚀"
echo "=============================="
echo "Домен: https://$DOMAIN"
echo "Логин: $USER_NAME"
echo "Пароль: $USER_PASS"
echo ""

cat <<EOF
{
  "listen": "socks://127.0.0.1:20808",
  "proxy": "https://$USER_NAME:$USER_PASS@$DOMAIN"
}
EOF

echo "=============================="
