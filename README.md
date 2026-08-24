# Telegram Experimental WEB Proxy (Desktop Only)

Руководство и скрипт автоустановки для новейшего экспериментального WEB-транспорта Telegram (`telegramdesktop/tproxy-server`) на базе **Caddy** и официального Docker-контейнера **MTProxy**.

> 🛑 **ВНИМАНИЕ! ПРОЧТИТЕ ПЕРЕД УСТАНОВКОЙ:**
> 
> 1. **ТОЛЬКО ДЛЯ ПК:** Данный WEB-протокол на текущий момент работает **исключительно в десктопной версии Telegram** (Windows, macOS, Linux). Мобильные клиенты (iOS, Android) этот вид прокси пока не поддерживают! На телефоне он работать не будет.
> 2. **НУЖЕН СВОЙ СЕРВЕР:** Для установки вам потребуется подключиться по SSH к собственному арендованному Linux-серверу (VPS/VDS) со статическим IP, привязанным доменом и базовым пониманием работы с консолью. Если у вас нет сервера — эта инструкция вам не подойдет.
> 3. **ЭКСПЕРИМЕНТАЛЬНЫЙ СОФТ:** Это ранняя реализация протокола, предназначенная для тестирования и обхода жестких блокировок (DPI).

---

## 🏗 Архитектура решения

```text
Telegram Desktop (WebView2 / Edge)
       │
       │ HTTPS (HTTP/2 POST /api/v1/up & /api/v1/down)
       ▼
Cloudflare (DNS Only — серое облако)
       │
       ▼
Caddy Web Server (Port 443)
       │
       │ HTTP reverse proxy
       ▼
tproxy-server Relay (Port 8444, Go daemon)
       │
       │ Raw MTProto TCP
       ▼
Docker MTProxy Backend (Port 8443)
       │
       ▼
Telegram Infrastructure

Telegram Desktop (WebView2): Маскирует трафик под стандартные HTTP/2 запросы (/api/v1/up и /api/v1/down) с реальными браузерными заголовками (Edge/Chrome).

Cloudflare / DNS: Запись поддомена должна быть строго в режиме DNS only (серое облако). Проксирование Cloudflare (WAF/Challenge) блокирует скрытые фоновые запросы WebView.

Caddy (HTTPS 443): Принимает TLS-трафик, терминирует сертификат и проксирует его локально.

tproxy-server (Relay 8444): Демон Telegram на Go, разбирающий HTTP-обёртку, кадровые потоки и проверяющий секрет.

Docker MTProxy (Backend 8443): Принимает очищенный трафик и отправляет его на сервера Telegram.

🚀 Пошаговая установка
🔥 Автоматическая установка (Быстрый старт)
Вы можете развернуть всю инфраструктуру автоматически с помощью готового bash-скрипта. Подключитесь к вашему серверу по SSH (например, ssh root@ваш_ip) и выполните следующие шаги:

1. Сгенерируйте секретный ключ
Для работы прокси нужен 32-значный hex-ключ. Сгенерируйте его прямо в консоли командой:

openssl rand -hex 16

(Скопируйте полученную строку — это ваш пароль для подключения).

2. Скачайте и запустите установщик

# Скачиваем скрипт
wget https://raw.githubusercontent.com/Kaprojennoe/telegram-web-proxy-setup/main/install.sh

# Делаем скрипт исполняемым
chmod +x install.sh

# Запускаем (замените на ваш домен и сгенерированный 32-значный hex-секрет)
sudo ./install.sh proxy.example.com YOUR_SECRET_32_HEX

(Если вы предпочитаете контролировать каждый шаг сборки, ниже приведена инструкция по ручной установке).

🛠 Ручная установка
1. Запуск Backend MTProxy (Docker)
Запускаем официальный контейнер на локальном порту 8443:

docker run -d \
  --name tg-web-backend \
  --restart always \
  -p 127.0.0.1:8443:443 \
  -e SECRET=YOUR_SECRET_32_HEX \
  telegrammessenger/proxy:latest

2. Сборка tproxy-server
Устанавливаем компилятор Go и собираем бинарник ретранслятора:

sudo apt update && sudo apt install -y golang git
cd ~
git clone https://github.com/telegramdesktop/tproxy-server.git
cd tproxy-server
go build -o tproxy-server ./cmd/tproxy-server
sudo mv tproxy-server /usr/local/bin/

3. Настройка конфигурации и заглушки
# Создание рабочих директорий
sudo mkdir -p /etc/tproxy-server /srv/tproxy-site

# Создание обязательной веб-заглушки (демон требует физический index.html)
echo '<h1>It works!</h1>' | sudo tee /srv/tproxy-site/index.html

# Главный конфиг сервера
cat << 'EOF' | sudo tee /etc/tproxy-server/config.json
{
  "public_hostname": "proxy.example.com",
  "listen": "127.0.0.1:8444",
  "profiles_file": "/etc/tproxy-server/profiles.json",
  "public_dir": "/srv/tproxy-site"
}
EOF

# Файл профилей с секретом и маршрутизацией на бэкенд
cat << 'EOF' | sudo tee /etc/tproxy-server/profiles.json
{
  "profiles": [
    {
      "name": "default",
      "secret": "YOUR_SECRET_32_HEX",
      "backend": "127.0.0.1:8443",
      "carrier_mode": "https"
    }
  ]
}
EOF

# КРИТИЧЕСКИ ВАЖНО: строгие права на файл профилей (демон проверяет безопасность)
sudo chmod 600 /etc/tproxy-server/profiles.json

4. Создание службы Systemd
Создаем службу для автозапуска ретранслятора:
sudo nano /etc/systemd/system/tg-web-relay.service
Вставляем содержимое:
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
Запускаем:
sudo systemctl daemon-reload
sudo systemctl enable --now tg-web-relay
5. Настройка веб-сервера Caddy
Редактируем /etc/caddy/Caddyfile:
{
    servers {
        protocols h1 h2
    }
}

proxy.example.com {
    reverse_proxy 127.0.0.1:8444

    log {
        output file /var/log/caddy/tg-access.log
    }
}
Перезапускаем Caddy:
sudo systemctl restart caddy

⚙️ Настройка в Telegram Desktop
Перейдите в Настройки ➔ Продвинутые настройки ➔ Тип соединения ➔ Использовать собственный прокси.

Добавьте прокси типа WEB.

Web proxy hostname: proxy.example.com (без https:// и портов).

Ключ: ваш 32-значный hex-ключ (без префиксов ee/dd).

⚠️ Важные нюансы и грабли
Cloudflare WAF: Если поддомен проксируется через Cloudflare (оранжевое облако), клиент Telegram не сможет установить сессию. В DNS необходимо выставить DNS only (серое облако).

Требование к public_dir: tproxy-server завершает работу с ошибкой, если в указанной директории отсутствует файл index.html.

Права на profiles.json: Демон принудительно проверяет права файла ключей. При правах шире 600 служба завершается с кодом ошибки.

Формат секретов: В WEB-протоколе не используются TLS/FakeTLS префиксы (ee... / dd...), используется чистый 16-байтный (32 hex) ключ.
