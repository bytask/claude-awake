#!/bin/bash
# claude-awake アンインストーラ。hooks は settings.json から claude-awake 行だけ外す。
#
#   ./uninstall.sh                     launchd + 本体を撤去
#   ./uninstall.sh --hooks ~/.claude   hooks も外す
#   ./uninstall.sh --sudoers           /etc/sudoers.d/claude-pmset も削除（要 sudo）
set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LABEL="${AWAKE_LABEL:-local.claude-awake.reap}"
AGENT_DIR="$HOME/Library/LaunchAgents"
BIN="$BIN_DIR/claude-awake.sh"
WANT_SUDOERS=0
HOOK_DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --hooks)   HOOK_DIRS+=("${2:?}"); shift 2 ;;
    --sudoers) WANT_SUDOERS=1; shift ;;
    --label)   LABEL="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say() { printf '==> %s\n' "$*"; }

# 抑止状態を戻してから撤去する
if [ -x "$BIN" ]; then
  rm -f "$HOME/.claude/awake/"* 2>/dev/null || true
  "$BIN" reap >/dev/null 2>&1 || true
fi

say "launchd $LABEL を停止"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$AGENT_DIR/$LABEL.plist"

for dir in ${HOOK_DIRS[@]+"${HOOK_DIRS[@]}"}; do
  dir="${dir/#\~/$HOME}"
  settings="$dir/settings.json"
  [ -f "$settings" ] || continue
  command -v jq >/dev/null || { echo "jq が必要です" >&2; exit 1; }
  cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  jq '
    .hooks = ((.hooks // {}) | with_entries(.value |= [ .[]
        | .hooks = [ (.hooks // [])[] | select(((.command // "") | test("claude-awake")) | not) ]
        | select((.hooks | length) > 0) ]))
  ' "$settings" > "$tmp"
  mv "$tmp" "$settings"
  say "hooks を除去: $settings"
done

if [ "$WANT_SUDOERS" = 1 ]; then
  say "/etc/sudoers.d/claude-pmset を削除"
  sudo rm -f /etc/sudoers.d/claude-pmset
fi

say "本体を削除: $BIN"
rm -f "$BIN"
rmdir "$HOME/.claude/awake" 2>/dev/null || true
say "完了（SleepDisabled は $(pmset -g | awk '/SleepDisabled/{print $NF}') です）"
