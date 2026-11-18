#!/usr/bin/env bash
# Докачивает программы агентов, если npm пропустил их части для Linux (бывает при обрывах связи).
#   bash fix-agents        журнал: /root/orchestra-agents.log
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
if [[ -z "${FIX_BG:-}" ]]; then
  export FIX_BG=1; nohup bash "$0" > /root/orchestra-agents.log 2>&1 &
  echo "Докачка идёт в фоне, Termius можно закрыть. Ход: tail -f /root/orchestra-agents.log"
  tail -n +1 -f /root/orchestra-agents.log --pid=$!; exit 0
fi
umask 022
O=/opt/orchestra; export PATH="$O/node/bin:$O/npm/bin:$PATH"
npm config set fetch-retries 10 >/dev/null; npm config set fetch-retry-maxtimeout 120000 >/dev/null; npm config set fetch-timeout 1800000 >/dev/null
ok() { timeout 60 "$1" --version >/dev/null 2>&1; }
for pkg in @anthropic-ai/claude-code @openai/codex @google/gemini-cli; do
  [[ -d "$O/npm/lib/node_modules/$pkg" ]] || { echo "▸ Ставлю $pkg"; npm install -g --prefix $O/npm --no-fund --no-audit --loglevel=error "$pkg"; }
done
D=$O/npm/lib/node_modules/@anthropic-ai/claude-code
if ! ok claude; then
  V=$(node -p "require('$D/package.json').version")
  echo "▸ Claude Code: докачиваю программу для Linux (около 200 МБ)"
  for t in 1 2 3 4 5; do
    (cd "$D" && npm install --no-save --no-fund --no-audit --loglevel=error "@anthropic-ai/claude-code-linux-x64@$V") && break
    echo "  попытка $t не удалась, повторяю"
  done
  (cd "$D" && node install.cjs)
fi
D=$O/npm/lib/node_modules/@openai/codex
if ! ok codex; then
  V=$(node -p "require('$D/package.json').version")
  echo "▸ Codex: докачиваю программу для Linux"
  for t in 1 2 3 4 5; do
    (cd "$D" && npm install --no-save --no-fund --no-audit --loglevel=error "@openai/codex-linux-x64@npm:@openai/codex@$V-linux-x64") && break
    echo "  попытка $t не удалась, повторяю"
  done
fi
chmod -R a+rX $O/npm
echo; for b in claude codex gemini; do printf '%-7s ' $b; ok $b && timeout 60 $b --version 2>/dev/null | head -1 || echo "НЕ РАБОТАЕТ"; done
echo "ГОТОВО"
