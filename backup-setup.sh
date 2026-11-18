#!/usr/bin/env bash
# Резервное копирование сервера в Cloudflare R2: зашифрованно (restic), каждую ночь, с хранением истории.
#   bash setup.sh          — настройка (спросит ключи R2) и первая копия
# После настройки:
#   mk-backup              — сделать копию сейчас
#   mk-backup snapshots    — список копий
#   mk-backup restore latest --target /root/restore   — восстановить последнюю копию в папку
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
say() { printf '\n\033[1;32m▸ %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m! %s\033[0m\n' "$*"; }
CONF=/etc/mk-backup
mkdir -p $CONF; chmod 700 $CONF

say "Программа restic (шифрование и отправка копий)"
if ! command -v restic >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic >/dev/null 2>&1 || {
    curl -fL --retry 10 --retry-all-errors -o /tmp/restic.bz2 https://raw.githubusercontent.com/ivanalekseevich683-a11y/crm-demo/deploy/restic.bz2 \
      && bunzip2 -f /tmp/restic.bz2 && install -m 755 /tmp/restic /usr/local/bin/restic; }
fi
restic version || { warn "restic не установился"; exit 1; }

if [[ -f $CONF/env ]]; then
  say "Ключи Cloudflare уже сохранены, использую их (чтобы ввести заново: rm $CONF/env и запустить снова)"
else
  echo
  echo "Данные из Cloudflare: R2 → Overview (Account ID) и R2 → Manage API tokens (ключи)."
  echo "При вставке ключей символы не видны — это нормально."
  read -rp  "1) Account ID: " ACC
  read -rp  "2) Access Key ID: " KEY
  read -rsp "3) Secret Access Key: " SEC; echo
  read -rp  "4) Имя бакета [mk-backups]: " BUCKET; BUCKET=${BUCKET:-mk-backups}
  ACC=$(echo "$ACC" | tr -d ' '); KEY=$(echo "$KEY" | tr -d ' '); SEC=$(echo "$SEC" | tr -d ' ')
  [[ -n "$ACC" && -n "$KEY" && -n "$SEC" ]] || { warn "Нужны все три значения"; exit 1; }
  umask 077
  cat > $CONF/env <<ENV
export RESTIC_REPOSITORY=s3:https://${ACC}.r2.cloudflarestorage.com/${BUCKET}/$(hostname -s)
export RESTIC_PASSWORD_FILE=$CONF/password
export AWS_ACCESS_KEY_ID=${KEY}
export AWS_SECRET_ACCESS_KEY=${SEC}
export AWS_DEFAULT_REGION=auto
# Что копировать (через пробел). Папки, которых нет на сервере, пропускаются.
export BACKUP_PATHS="/root /home /srv /opt /etc /var/lib/docker/volumes /var/spool/cron"
ENV
  umask 022
fi
NEWPASS=0
if [[ ! -f $CONF/password ]]; then
  ( umask 077; openssl rand -base64 33 > $CONF/password ); NEWPASS=1
fi
# shellcheck source=/dev/null
source $CONF/env

say "Проверяю доступ к Cloudflare R2"
if ! restic cat config >/dev/null 2>&1; then
  restic init || { warn "Не удалось создать хранилище. Проверьте Account ID, ключи и имя бакета (бакет должен быть создан в R2)."; exit 1; }
fi

say "Ставлю ежедневную копию"
cat > /usr/local/bin/mk-backup <<'RUN'
#!/usr/bin/env bash
# Копия сервера в Cloudflare R2. Без аргументов — сделать копию; с аргументами — команда restic (snapshots, restore ...).
set -uo pipefail
source /etc/mk-backup/env
[[ $# -gt 0 ]] && exec restic "$@"
DUMP=/var/backups/mk-dumps; EXC=$(mktemp)
rm -rf "$DUMP"; mkdir -p "$DUMP"; chmod 700 "$DUMP"
printf '%s\n' '**/node_modules' '**/.cache' '**/__pycache__' '**/venv' '**/.venv' '**/.npm' '/opt/orchestra/node' \
  '/opt/orchestra/npm' '/root/.cache' '/var/backups/mk-dumps.old' '**/*.tmp' > "$EXC"
echo "Базы данных:"
if command -v docker >/dev/null && timeout 20 docker info >/dev/null 2>&1; then
  for c in $(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /postgres/ {print $1}'); do
    U=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | sed -n 's/^POSTGRES_USER=//p' | head -1)
    if timeout 3600 docker exec "$c" pg_dumpall -U "${U:-postgres}" | gzip > "$DUMP/$c.sql.gz" && [[ -s "$DUMP/$c.sql.gz" ]]; then
      echo "  $c: дамп готов"
      # файлы самой базы не копируем: в работе они несогласованы, восстанавливаем из дампа
      docker inspect -f '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' "$c" \
        | awk '$2 ~ /postgresql/ {print $1}' >> "$EXC"
    else
      echo "  $c: ДАМП НЕ ПОЛУЧИЛСЯ"
    fi
  done
else
  echo "  Docker не отвечает — копирую только файлы"
fi
if command -v pg_dumpall >/dev/null && systemctl is-active -q postgresql 2>/dev/null; then
  sudo -u postgres pg_dumpall | gzip > "$DUMP/host-postgres.sql.gz" && echo "  postgres на сервере: дамп готов"
fi
# SQLite: согласованные копии через встроенный механизм Python
python3 - "$DUMP" <<'PY' 2>/dev/null || true
import os, sqlite3, sys
out = os.path.join(sys.argv[1], 'sqlite'); os.makedirs(out, exist_ok=True)
for root in ('/root', '/home', '/srv', '/opt', '/var/lib/docker/volumes'):
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in ('node_modules', '.cache', 'venv', '.venv', '__pycache__', '.git')]
        for f in files:
            if f.endswith(('.db', '.sqlite', '.sqlite3')):
                p = os.path.join(d, f)
                try:
                    if os.path.getsize(p) > 2 * 1024**3:
                        continue
                    with open(p, 'rb') as fh:
                        if fh.read(16) != b'SQLite format 3\x00':
                            continue
                    dst = sqlite3.connect(os.path.join(out, p.strip('/').replace('/', '__')))
                    src = sqlite3.connect(f'file:{p}?mode=ro', uri=True); src.backup(dst); src.close(); dst.close()
                    print('  sqlite:', p)
                except Exception as e:
                    print('  sqlite не скопирован:', p, e)
PY
PATHS=""; for p in $BACKUP_PATHS "$DUMP"; do [[ -e "$p" ]] && PATHS="$PATHS $p"; done
echo "Отправляю в Cloudflare R2:$PATHS"
restic backup $PATHS --exclude-file "$EXC" --exclude-caches --exclude-larger-than 2G --tag auto --host "$(hostname -s)"
code=$?
restic forget --host "$(hostname -s)" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune -q || true
[[ $(date +%u) -eq 7 ]] && restic check -q || true
rm -f "$EXC"
echo "$(date '+%F %T') код $code" > /var/log/mk-backup.status
[[ $code -eq 0 || $code -eq 3 ]] && echo "КОПИЯ ГОТОВА" || echo "КОПИЯ НЕ УДАЛАСЬ (код $code)"
exit $code
RUN
chmod 700 /usr/local/bin/mk-backup

cat > /etc/systemd/system/mk-backup.service <<'UNIT'
[Unit]
Description=Резервная копия сервера в Cloudflare R2
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/mk-backup
Nice=19
IOSchedulingClass=idle
CPUQuota=60%
UNIT
cat > /etc/systemd/system/mk-backup.timer <<'UNIT'
[Unit]
Description=Ежедневная резервная копия
[Timer]
OnCalendar=*-*-* 03:30
RandomizedDelaySec=30min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload; systemctl enable -q --now mk-backup.timer

say "Первая копия запущена в фоне (может идти от нескольких минут до часа)"
systemctl start --no-block mk-backup.service
printf '\n\033[1;32m════════ ГОТОВО ════════\033[0m\n'
if [[ $NEWPASS -eq 1 ]]; then
  echo "ПАРОЛЬ ШИФРОВАНИЯ — сохраните его в надёжном месте (заметки, менеджер паролей)."
  echo "Без него копии восстановить нельзя, даже если сервер пропадёт:"
  echo; echo "   $(cat $CONF/password)"; echo
fi
echo "Ход первой копии:   journalctl -u mk-backup -f      (выйти: Ctrl+C)"
echo "Список копий:       mk-backup snapshots"
echo "Копии делаются каждую ночь около 03:30–04:00 по времени сервера."
