#!/bin/bash
# claude-awake インストーラ（macOS 専用）
#
#   ./install.sh                                  スクリプト + launchd + sudoers を設置
#   ./install.sh --hooks ~/.claude                さらに hooks を settings.json へマージ
#   ./install.sh --hooks ~/.claude --hooks ~/.claude-two   複数アカウントぶん
#   ./install.sh --no-sudoers                     sudo を使わない（蓋閉じ抑止は無効のまま）
#
# 環境変数: BIN_DIR（既定 ~/.local/bin）、AWAKE_LABEL（既定 local.claude-awake.reap）
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
LABEL="${AWAKE_LABEL:-local.claude-awake.reap}"
# 作者環境で使っていた旧ラベル。存在すれば install 時に停止・退避する（無い環境では無害）。
LEGACY_LABELS=(com.task.claude-awake-reap)
AGENT_DIR="$HOME/Library/LaunchAgents"
SUDOERS_PATH=/etc/sudoers.d/claude-pmset
BIN="$BIN_DIR/claude-awake.sh"
WANT_SUDOERS=1
HOOK_DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --hooks)      HOOK_DIRS+=("${2:?--hooks には設定ディレクトリを渡す}"); shift 2 ;;
    --no-sudoers) WANT_SUDOERS=0; shift ;;
    --label)      LABEL="${2:?}"; shift 2 ;;
    --bin-dir)    BIN_DIR="${2:?}"; BIN="$BIN_DIR/claude-awake.sh"; shift 2 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    *)            echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "macOS 専用です" >&2; exit 1; }

say() { printf '==> %s\n' "$*"; }

# 1. 本体
say "$BIN へ設置"
/usr/bin/install -d "$BIN_DIR"
/usr/bin/install -m 755 "$SRC/claude-awake.sh" "$BIN"

# 2. sudoers — pmset の disablesleep トグルだけを NOPASSWD にする
if [ "$WANT_SUDOERS" = 1 ]; then
  tmp="$(mktemp)"
  sed "s|__USER__|$(id -un)|g" "$SRC/templates/sudoers" > "$tmp"
  if /usr/sbin/visudo -cf "$tmp" >/dev/null; then
    say "$SUDOERS_PATH を設置（sudo のパスワードを聞かれます）"
    sudo /usr/bin/install -m 440 -o root -g wheel "$tmp" "$SUDOERS_PATH"
  else
    echo "sudoers の構文チェックに失敗したので中止しました: $tmp" >&2
    exit 1
  fi
  rm -f "$tmp"
else
  say "sudoers はスキップ（蓋閉じスリープの抑止は効きません）"
fi

# 3. launchd — 孤児マーカーの定期回収
for legacy in "${LEGACY_LABELS[@]}"; do
  if [ "$legacy" != "$LABEL" ] && [ -f "$AGENT_DIR/$legacy.plist" ]; then
    say "旧ラベル $legacy を停止"
    launchctl bootout "gui/$(id -u)/$legacy" 2>/dev/null || true
    mv "$AGENT_DIR/$legacy.plist" "$AGENT_DIR/$legacy.plist.replaced-by-claude-awake"
  fi
done
say "launchd $LABEL を登録"
/usr/bin/install -d "$AGENT_DIR"
sed -e "s|__LABEL__|$LABEL|g" -e "s|__BIN__|$BIN|g" \
  "$SRC/templates/launchagent.plist" > "$AGENT_DIR/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_DIR/$LABEL.plist"

# 4. hooks
if [ "${#HOOK_DIRS[@]}" -gt 0 ]; then
  command -v jq >/dev/null || { echo "hooks のマージには jq が必要です（brew install jq）" >&2; exit 1; }
  add="$(sed "s|__BIN__|$BIN|g" "$SRC/hooks.example.json")"
  for dir in "${HOOK_DIRS[@]}"; do
    dir="${dir/#\~/$HOME}"
    mkdir -p "$dir"
    settings="$dir/settings.json"
    [ -f "$settings" ] || echo '{}' > "$settings"
    backup="$settings.bak.$(date +%Y%m%d%H%M%S)"
    cp "$settings" "$backup"
    tmp="$(mktemp)"
    jq --argjson add "$add" '
      (.hooks // {}) as $cur
      | ($cur | with_entries(.value |= [ .[]
          | .hooks = [ (.hooks // [])[] | select(((.command // "") | test("claude-awake")) | not) ]
          | select((.hooks | length) > 0) ])) as $clean
      | .hooks = reduce ($add.hooks | to_entries[]) as $e ($clean;
          .[$e.key] = ((.[$e.key] // []) + $e.value))
    ' "$settings" > "$tmp"
    mv "$tmp" "$settings"
    say "hooks をマージ: $settings（バックアップ $backup）"
  done
else
  cat <<MSG

hooks は未設定です。処理中だけ蓋閉じスリープを止めるには、Claude Code の
設定ディレクトリごとに hooks を入れてください（既存の hooks は保持されます）:

  ./install.sh --hooks ~/.claude

手で書く場合は hooks.example.json の __BIN__ を $BIN に置換して
settings.json の "hooks" へマージします。
MSG
fi

say "完了"
"$BIN" status || true
