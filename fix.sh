#!/usr/bin/env bash
# Чинит зависший Docker и доустанавливает CRM. Журнал: ~/mk-fix.log
exec > >(tee -a ~/mk-fix.log) 2>&1
say() { printf '\n\033[1;32m▸ %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m! %s\033[0m\n' "$*"; }
say "Старт $(date '+%F %T'), нагрузка: $(cut -d' ' -f1-3 /proc/loadavg), ядер: $(nproc)"
say "Кто грузит процессор (снимок для диагностики)"
top -bn2 -d3 -o %CPU | awk '/^top -/{n++} n==2' | sed -n '7,16p' | cut -c1-110

say "Останавливаю зависшие проверки обновлений Ubuntu"
systemctl stop packagekit unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null
pkill -9 -f update-notifier/apt-check; pkill -9 packagekitd
if pgrep -x dpkg >/dev/null; then warn "Идёт установка пакета (dpkg), её не прерываю"; else pkill -9 -f unattended-upgrade; fi

say "Даю Docker больше времени на запуск и перезапускаю его"
mkdir -p /etc/systemd/system/docker.service.d
printf '[Service]\nTimeoutStartSec=15min\n' > /etc/systemd/system/docker.service.d/mk-timeout.conf
systemctl daemon-reload
systemctl reset-failed docker 2>/dev/null
systemctl restart containerd
timeout 1000 systemctl restart docker
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 10; done
if ! docker info >/dev/null 2>&1; then
  warn "Docker так и не запустился. Журнал Docker:"; journalctl -u docker -n 25 --no-pager | cut -c1-200; exit 1
fi
say "Docker работает. Контейнеры:"; docker ps --format '{{.Names}}: {{.Status}}'

say "Скачиваю образы с зеркала Google (до 3 попыток)"
for img in postgres:16 python:3.13-slim; do
  docker image inspect "$img" >/dev/null 2>&1 && { echo "$img уже есть"; continue; }
  for t in 1 2 3; do
    timeout 900 docker pull -q "mirror.gcr.io/library/$img" && docker tag "mirror.gcr.io/library/$img" "$img" && break
    timeout 900 docker pull -q "$img" && break
    warn "Попытка $t для $img не удалась"
  done
done

say "Запускаю установку CRM"
MK_BG=1 bash ~/mk-service/ops/install.sh
[ -z "$(dpkg --audit 2>/dev/null)" ] || { say "Довожу прерванные обновления Ubuntu"; timeout 900 dpkg --configure -a; }
say "Итог $(date '+%F %T'): нагрузка $(cut -d' ' -f1-3 /proc/loadavg)"
docker ps --format '{{.Names}}: {{.Status}}'
