#!/bin/bash
# claude-awake.sh — Claude Code の処理中だけ macOS の蓋閉じスリープ(disablesleep)を抑止する。
#
# 参照カウント方式: 処理中セッションのマーカーファイルが 1 つでもあれば
# disablesleep=1、0 になれば 0 に戻す。複数セッションの同時起動に対応する。
#   acquire <sid>  処理開始 (UserPromptSubmit hook)
#   release <sid>  処理完了 (Stop / SessionEnd hook)
#   reap           孤児マーカー掃除 + 再評価 (launchd / SessionStart)
#   hold           手動ホールド (セッションと無関係に disablesleep=1 を維持。reap で消えない。旧 Capsomnia の代替)
#   unhold         手動ホールド解除
#   status         マーカー一覧と現在の SleepDisabled を表示
set -u

AWAKE_DIR="$HOME/.claude/awake"
LOCKDIR="$HOME/.claude/awake.lock.d"
STALE_MIN=180   # 処理開始から 3 時間超のマーカーは中断放置とみなし掃除する

action="${1:-}"
session="$(printf '%s' "${2:-unknown}" | tr -cd 'A-Za-z0-9._-')"
[ -z "$session" ] && session="unknown"

mkdir -p "$AWAKE_DIR"

# 排他ロック — flock は macOS に無いので mkdir のアトミック性を使う。
# 最大 5 秒待って取れなければロック無しで続行 (競合時の取りこぼしは reap が回収)。
for _ in $(seq 1 100); do
  if mkdir "$LOCKDIR" 2>/dev/null; then
    trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
    break
  fi
  sleep 0.05
done

case "$action" in
  acquire) : > "$AWAKE_DIR/$session" ;;
  release) rm -f "$AWAKE_DIR/$session" ;;
  reap)    find "$AWAKE_DIR" -type f ! -name hold -mmin +"$STALE_MIN" -delete 2>/dev/null ;;
  hold)    : > "$AWAKE_DIR/hold" ;;
  unhold)  rm -f "$AWAKE_DIR/hold" ;;
  status)
    printf 'SleepDisabled=%s\n' "$(pmset -g | awk '/SleepDisabled/{print $NF}')"
    ls -lt "$AWAKE_DIR" 2>/dev/null | awk 'NR>1{print "  " $9 "  (" $6" "$7" "$8 ")"}'
    exit 0 ;;
  *) echo "usage: $0 {acquire|release|reap|hold|unhold|status} [session_id]" >&2; exit 2 ;;
esac

# マーカー数に応じて disablesleep を切替える。
count=$(find "$AWAKE_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -gt 0 ]; then want=1; else want=0; fi

cur=$(pmset -g | awk '/SleepDisabled/{print $NF}')
[ -z "$cur" ] && cur=0
if [ "$cur" != "$want" ]; then
  sudo -n /usr/bin/pmset -a disablesleep "$want" 2>/dev/null || true
fi
