#!/bin/bash
# Автоматический установщик Telegram WEB Proxy (tproxy-server)

# Проверка на запуск от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт с правами root (sudo ./install.sh ...)"
  exit 1
fi

# Проверка аргументов
if [ "$#" -ne 2 ]; then
    echo "Ошибка! Использование: $0 <домен> <секрет_32_символа>"
    echo "Пример: $0 tg.example.com d8a2903bb3138fd99d547cbd81740e02"
    exit 1
fi

DOMAIN=$1
SECRET=$2

echo "=== 1. Запуск Backend MTProxy ==="
docker stop tg-web-backend 2>/dev/null
docker rm tg-web-backend 2>/dev/null
docker run -d --name tg-web-backend --restart always -p 127.0.0.1:8443:443 -e SECRET=$SECRET telegrammessenger/proxy:latest

echo "=== 2. Установка Go и сборка tproxy-server ==="
apt update && apt install -y golang git
cd /tmp
rm -rf tproxy-server
git clone https://github.com/telegramdesktop/tproxy-server.git
cd tproxy-server
go build -o tproxy-server ./cmd/tproxy-server
mv tproxy-server /usr/local/bin/

echo "=== 3. Создание конфигурации ==="
mkdir -p /etc/tproxy-server /srv/tproxy-site
echo '<h1>It works!</h1>' > /srv/tproxy-site/index.html

# Генерируем config.json с подстановкой домена пользователя
cat << EOF > /etc/tproxy-server/config.json
{
  "public_hostname": "$DOMAIN",
  "listen": "127.0.0.1:8444",
  "profiles_file": "/etc/tproxy-server/profiles.json",
  "public_dir": "/srv/tproxy-site"
}
EOF

# Генерируем profiles.json с подстановкой секрета пользователя
cat << EOF > /etc/tproxy-server/profiles.json
{
  "profiles": [
    {
      "name": "default",
      "secret": "$SECRET",
      "backend": "127.0.0.1:8443",
      "carrier_mode": "https"
    }
  ]
}
EOF

# Параноидальные права доступа, как требует демон
chmod 600 /etc/tproxy-server/profiles.json

echo "=== 4. Настройка службы tg-web-relay ==="
cat << 'EOF' > /etc/systemd/system/tg-web-relay.service
[Unit]
Description=Telegram WEB Proxy Relay
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tg-web-relay

echo "=== Установка успешно завершена! ==="
echo "Осталось только добавить в ваш /etc/caddy/Caddyfile следующий блок:"
echo ""
echo "$DOMAIN {"
echo "    reverse_proxy 127.0.0.1:8444"
echo "}"
echo ""
echo "И перезапустить веб-сервер командой: sudo systemctl restart caddy"
