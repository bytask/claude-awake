# claude-awake

Claude Code が処理している間だけ macOS のスリープ（**蓋閉じスリープを含む**）を抑止する仕組み。
処理が終われば自動で元に戻るので、常時スリープ無効のアプリを常駐させる必要がない。

## なぜ必要か

Claude Code を `caffeinate -i` で包むだけでは足りない。

| 段 | 仕組み | 抑止される期間 | 蓋閉じ |
|---|---|---|---|
| ① `caffeinate -i claude` | alias で `claude` を包む | セッション起動〜終了 | ✗ |
| ② **claude-awake**（これ） | hooks + `pmset -a disablesleep` | プロンプト実行中のみ | ✓ |

`caffeinate` が抑止できるのはアイドルスリープだけで、蓋を閉じると寝る。
蓋を閉じても長い処理を走り切らせたいなら `pmset -a disablesleep 1` が必要で、
これは root 権限が要る＝入れっぱなしにしたくない。②はそれを**処理中だけ**に絞る。

①と②は併用推奨。`~/.zshrc` に以下を置いておくと①が効く。

```sh
alias claude='caffeinate -i claude'
```

## 動作

参照カウント方式。`~/.claude/awake/<session_id>` をマーカーとして置き、
1 つでもあれば `disablesleep=1`、0 になれば `0` に戻す。複数セッションの同時起動に対応する。

| サブコマンド | 呼ばれる場所 | 動作 |
|---|---|---|
| `acquire <sid>` | hook `UserPromptSubmit` | マーカー作成（処理開始） |
| `release <sid>` | hook `Stop` / `SessionEnd` | マーカー削除（処理完了） |
| `reap` | hook `SessionStart`、launchd 5 分毎 | 3 時間超の孤児マーカーを掃除して再評価 |
| `hold` / `unhold` | 手動 | セッションと無関係に `disablesleep=1` を維持 / 解除 |
| `status` | 手動 | マーカー一覧と現在の `SleepDisabled` を表示 |

クラッシュや強制終了でマーカーが残っても、launchd の `reap` が 3 時間で回収する
（`hold` マーカーは回収対象外）。

## インストール

```sh
git clone https://github.com/bytask/claude-awake.git
cd claude-awake
./install.sh --hooks ~/.claude
```

やっていること:

1. `claude-awake.sh` を `~/.local/bin/` に設置
2. `/etc/sudoers.d/claude-pmset` を作成（**`pmset -a disablesleep 0|1` だけ** を NOPASSWD 許可。`visudo -cf` で構文検証してから設置）→ sudo のパスワードを 1 度聞かれる
3. LaunchAgent `local.claude-awake.reap` を登録（5 分毎に `reap`）
4. `--hooks <設定ディレクトリ>` を渡すと `settings.json` の `hooks` へマージ（既存 hooks は保持、変更前に `.bak.<timestamp>` を残す）

複数アカウントを使っているなら設定ディレクトリごとに渡す。マーカーは共通なので相互に干渉しない。

```sh
./install.sh --hooks ~/.claude --hooks ~/.claude-two
```

`--no-sudoers` で sudoers を省略できるが、その場合②は実質無効（`disablesleep` が変更できない）。
オプションは `BIN_DIR` / `AWAKE_LABEL` 環境変数と `--label` / `--bin-dir` で変えられる。

### 前提

- macOS（`pmset` / `launchctl` 依存）
- `jq`（hooks マージと hook 内での session_id 取得に使う。`brew install jq`）

## 使い方

```sh
claude-awake.sh status     # いま抑止されているか、誰が握っているか
claude-awake.sh hold       # 蓋を閉じて長時間回すとき（セッションと無関係に維持）
claude-awake.sh unhold     # 解除
```

`hold` を入れたままにすると永久にスリープしなくなるので、使ったら戻す。

## 既知の競合

**`disablesleep` を触る常駐アプリと併用不可。** 例えば Caps Lock で
スリープを制御する Capsomnia は 10 秒ごとに自分の状態へ `disablesleep` を戻すため、
claude-awake が立てた `1` を打ち消す（症状: `status` が `1` を返しても実際には蓋を閉じると寝る）。
同種のアプリは停止すること。

```sh
launchctl bootout "gui/$(id -u)/<アプリのラベル>"
launchctl disable "gui/$(id -u)/<アプリのラベル>"
```

他に `pmset -g assertions` で `PreventUserIdleSystemSleep` を握りっぱなしのアプリが
いる場合、①相当が常時オンになっているのと同じ状態になる。挙動が想定と違うときはここを見る。

## 確認

```sh
pmset -g | grep SleepDisabled      # 処理中は 1、終わると 0
pmset -g assertions                # caffeinate など他の抑止要因の一覧
launchctl print "gui/$(id -u)/local.claude-awake.reap" | head
sudo -n -l | grep pmset            # sudoers ルールが入っているか
```

## アンインストール

```sh
./uninstall.sh --hooks ~/.claude --sudoers
```

マーカーを消して `disablesleep` を 0 に戻してから、launchd・本体・hooks・sudoers を撤去する。

## ライセンス

MIT
