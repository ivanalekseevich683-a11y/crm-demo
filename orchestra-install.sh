#!/usr/bin/env bash
# Установка оркестра агентов (Claude Code, Codex, Gemini CLI, Grok Build) на сервер рядом с другими сайтами.
#   bash install.sh                       # пустой проект
#   bash install.sh https://...git        # взять проект из git (для закрытого репозитория — адрес с токеном)
# Повторный запуск обновляет программы и код оркестра, задачи и вход агентов сохраняются.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_URL="${1:-}"
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
LOG=/root/orchestra-install.log
if [[ -z "${ORCH_BG:-}" ]]; then
  export ORCH_BG=1
  ( umask 077; nohup bash "$0" "$@" > "$LOG" 2>&1 & echo $! > "$LOG.pid" )
  PID=$(cat "$LOG.pid"); rm -f "$LOG.pid"
  echo "Установка идёт в фоне. Если связь оборвётся: tail -f $LOG"
  tail -n +1 -f "$LOG" --pid="$PID"; exit 0
fi
umask 022  # журнал закрыт от посторонних, а файлы оркестра должны быть доступны его пользователям
say() { printf '\n\033[1;32m▸ %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m! %s\033[0m\n' "$*"; }
O=/opt/orchestra; S=/srv/orchestra
AGENTS="claude codex gemini grok"

say "Системные пакеты"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git sudo python3-venv xz-utils curl >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git sudo python3-venv xz-utils curl; }

if ! swapon --show | grep -q .; then
  say "Добавляю файл подкачки 4 ГБ (агентам нужна память)"
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

say "Пользователи: оркестр и по одному на агента"
getent group orchgit >/dev/null || groupadd --system orchgit
id orchestra >/dev/null 2>&1 || useradd --system --home-dir $S --shell /usr/sbin/nologin orchestra
usermod -aG orchgit orchestra
for a in $AGENTS; do
  id "agent-$a" >/dev/null 2>&1 || useradd -m -s /bin/bash "agent-$a"
  usermod -aG orchgit "agent-$a"; chmod 700 "/home/agent-$a"
done
mkdir -p $O/bin $O/app $S/data /etc/orchestra; chmod 755 $O $O/bin $O/app /etc/orchestra
chown orchestra:orchgit $S; chmod 751 $S
chown orchestra:orchestra $S/data; chmod 700 $S/data

say "Node.js"
NODE_TAR=$(ls "$HERE"/vendor/node-*-linux-x64.tar.xz 2>/dev/null | head -1)
if [[ -n "$NODE_TAR" ]]; then rm -rf $O/node && mkdir -p $O/node && tar -xJf "$NODE_TAR" -C $O/node --strip-components=1; fi
export PATH="$O/node/bin:$O/npm/bin:$PATH"
node -v || { warn "Node.js не установился"; exit 1; }

say "Программы агентов (Claude Code, Codex, Gemini CLI). Скачивание до 10–15 минут"
npm config set fetch-retries 10 >/dev/null; npm config set fetch-retry-maxtimeout 120000 >/dev/null; npm config set fetch-timeout 900000 >/dev/null
for pkg in @anthropic-ai/claude-code @openai/codex @google/gemini-cli; do
  [[ -d "$O/npm/lib/node_modules/$pkg" ]] && { echo "$pkg уже установлен"; continue; }
  for t in 1 2 3; do
    npm install -g --prefix $O/npm --no-fund --no-audit --loglevel=error "$pkg" && break
    warn "$pkg: попытка $t не удалась, повторяю"
  done
done
FIX_BG=1 bash "$HERE"/bin/fix-agents | grep -v '^$' || true
chmod -R a+rX $O/npm $O/node

say "Grok Build (официальный установщик xAI) для пользователя agent-grok"
sudo -iu agent-grok bash -c 'command -v grok >/dev/null || ls ~/.grok/bin/grok ~/.local/bin/grok >/dev/null 2>&1 || (curl -fsSL --retry 5 https://x.ai/cli/install.sh | bash)' \
  || warn "Grok Build не установился. Повторить позже: sudo -iu agent-grok bash -c 'curl -fsSL https://x.ai/cli/install.sh | bash'"

say "Общий репозиторий проекта"
if [[ ! -d $S/repo.git ]]; then
  git init -q --bare --shared=group -b main $S/repo.git
  git -C $S/repo.git config receive.denyNonFastForwards false
  TMP=$(mktemp -d)
  if [[ -n "$PROJECT_URL" ]]; then
    git clone -q "$PROJECT_URL" "$TMP/p" && git -C "$TMP/p" push -q $S/repo.git HEAD:main || warn "Не удалось взять проект по адресу"
  fi
  if ! git -C $S/repo.git rev-parse -q --verify main >/dev/null; then
    git init -q -b main "$TMP/p2" && echo "# Проект команды агентов" > "$TMP/p2/README.md"
    git -C "$TMP/p2" -c user.name=orchestra -c user.email=orchestra@orchestra.local commit -qam init 2>/dev/null \
      || { git -C "$TMP/p2" add . && git -C "$TMP/p2" -c user.name=orchestra -c user.email=orchestra@orchestra.local commit -qm init; }
    git -C "$TMP/p2" push -q $S/repo.git main
  fi
  rm -rf "$TMP"
fi
git config --system --get-all safe.directory | grep -qx $S/repo.git || git config --system --add safe.directory $S/repo.git
chown -R orchestra:orchgit $S/repo.git; chmod -R g+rwX $S/repo.git; find $S/repo.git -type d -exec chmod g+s {} +

say "Оркестратор"
cp "$HERE"/app.py "$HERE"/totp.py $O/app/; mkdir -p $O/app/static; cp "$HERE"/static/* $O/app/static/
install -m 755 "$HERE"/bin/run-agent $O/bin/run-agent
install -m 755 "$HERE"/bin/orchestra-login /usr/local/bin/orchestra-login
[[ -f /etc/orchestra/agents.conf ]] || install -m 644 "$HERE"/agents.conf /etc/orchestra/agents.conf
[[ -d $O/venv ]] || python3 -m venv $O/venv
$O/venv/bin/pip install -q --no-index --find-links "$HERE"/vendor/wheels -r "$HERE"/requirements.txt \
  || $O/venv/bin/pip install -q --retries 10 -r "$HERE"/requirements.txt
cat > /etc/sudoers.d/orchestra <<'SUDO'
orchestra ALL=(agent-claude,agent-codex,agent-gemini,agent-grok) NOPASSWD: /opt/orchestra/bin/run-agent
SUDO
chmod 440 /etc/sudoers.d/orchestra; visudo -cq || { rm -f /etc/sudoers.d/orchestra; warn "Ошибка в правилах sudo"; exit 1; }

cat > /etc/systemd/system/orchestra.service <<UNIT
[Unit]
Description=Оркестр агентов
After=network-online.target
[Service]
User=orchestra
WorkingDirectory=$O/app
Environment=ORCH_DATA=$S/data ORCH_REPO=$S/repo.git ORCH_MERGE=$S/data/merge
ExecStart=$O/venv/bin/uvicorn app:app --host 127.0.0.1 --port 8030 --proxy-headers --forwarded-allow-ips=127.0.0.1
Restart=always
# Агенты работают с низким приоритетом и ограничением памяти, чтобы CRM на этом сервере не тормозила.
Nice=15
IOSchedulingClass=idle
CPUWeight=20
MemoryHigh=60%
MemoryMax=75%
[Install]
WantedBy=multi-user.target
UNIT
CREDS=""
if [[ ! -f $S/data/.password-issued ]]; then
  CREDS=$(cd $O/app && sudo -u orchestra env ORCH_DATA=$S/data $O/venv/bin/python app.py set-password) && touch $S/data/.password-issued
fi
systemctl daemon-reload; systemctl enable -q orchestra; systemctl restart orchestra
for i in $(seq 1 30); do curl -fsS http://127.0.0.1:8030/api/me >/dev/null 2>&1 && break; sleep 1; done
curl -fsS http://127.0.0.1:8030/api/me >/dev/null || { warn "Оркестр не запустился: journalctl -u orchestra -n 30"; exit 1; }

MYIP=$(curl -fsS4 --max-time 8 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
DOMAIN="agents-${MYIP//./-}.sslip.io"
say "Сайт оркестра: https://$DOMAIN"
if command -v caddy >/dev/null; then
  CF=/etc/caddy/Caddyfile
  if ! grep -q "^${DOMAIN} " "$CF" 2>/dev/null; then
    BAK="$CF.bak.$(date +%s)"; cp "$CF" "$BAK"
    printf '\n# Оркестр агентов\n%s {\n\tencode gzip\n\treverse_proxy 127.0.0.1:8030\n}\n' "$DOMAIN" >> "$CF"
    if ! caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1; then
      cp "$BAK" "$CF"; warn "Настройки Caddy не прошли проверку: вернул прежний файл, сайт CRM не затронут"; exit 1
    fi
  fi
  systemctl reload caddy
else
  apt-get install -y -qq caddy >/dev/null && printf '%s {\n\tencode gzip\n\treverse_proxy 127.0.0.1:8030\n}\n' "$DOMAIN" > /etc/caddy/Caddyfile && systemctl reload caddy
fi
for i in $(seq 1 30); do curl -fsS "https://$DOMAIN/api/me" >/dev/null 2>&1 && break; sleep 3; done

say "Проверка агентов"
for a in $AGENTS; do printf '  %-7s ' "$a"; sudo -u orchestra sudo -n -H -u "agent-$a" $O/bin/run-agent "$a" 0 check </dev/null | sed 's/@@STATUS //'; done

printf '\n\033[1;32m════════ ГОТОВО ════════\033[0m\n'
echo "Оркестр: https://$DOMAIN"
[[ -n "$CREDS" ]] && echo "Пароль (показан один раз): ${CREDS#PASSWORD }"
echo "При первом входе страница покажет QR-код для Google Authenticator."
echo "Вход агентов в свои аккаунты (по одному разу): orchestra-login claude | codex | gemini | grok"
