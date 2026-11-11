# SurfaceMuteBridge

Surface Headphones のミュート操作で、Mac 上の通話アプリのミュートを切り替える常駐ヘルパーです。
通話アプリが前面になくても効きます。

| アプリ | 送るショートカット | 条件 |
|---|---|---|
| Microsoft Teams | Cmd+Shift+M | なし |
| Zoom | Cmd+Shift+A | なし |
| Google Meet (Chrome) | Cmd+D | Chrome の最前面ウィンドウで Meet のタブが表示中のときだけ |

## なぜ必要か

Surface Headphones は Bluetooth では HFP / A2DP / AVRCP しか提供しておらず、
通話アプリがミュート同期に使う HID の通知がありません。そのためヘッドフォンのミュート操作は
アプリに伝わりません。

## 仕組み

1. ミュート操作をすると、ヘッドフォンは HFP で「マイク音量 0」を Mac に 1 回通知する。
2. Mac 側の入力音量が一瞬 0 になる（多くの場合 0.02 秒ほどで元に戻される）。
3. ヘルパーは CoreAudio の入力音量の変化を監視し、この 0 を「1 回の押下」とみなす。
4. その時点でマイクを使っているアプリを調べ、対応アプリにミュート切り替えのショートカットを送る。

ヘルパーは押すたびに切り替えるだけで、いまミュートかどうかは把握しません。
状態はアプリの画面表示で確認してください。

## インストール

Xcode のコマンドラインツール（`swiftc`）が必要です。

```bash
./install.sh
```

`~/Applications/SurfaceMuteBridge.app` に設置され、ログイン時に自動で起動します。
初回と、作り直すたびに、次の許可が必要です。

- **アクセシビリティ**: システム設定 → プライバシーとセキュリティ → アクセシビリティで
  SurfaceMuteBridge をオンにする。作り直した後は一度オフ→オンにし直す。
- **Chrome の制御**（Meet を使う場合）: 初めて Meet で押したときに出る確認を許可する。

## 動かないとき

```bash
tail -20 ~/Library/Logs/SurfaceMuteBridge.log
```

- 押しても「ミュート操作を検知」が出ない: ヘッドフォンが入力デバイスとして使われているか確認する。
  通知が来るのは通話中（マイク使用中）だけです。
- 「アクセシビリティ: 未許可」: 上の許可をやり直す。
- 「マイク使用中の対応アプリなし」: 対応していないアプリがマイクを使っている。

## アンインストール

```bash
./uninstall.sh
```

## 手動で試す

```bash
swiftc -O SurfaceMuteBridge.swift -o SurfaceMuteBridge
./SurfaceMuteBridge --verbose          # 検知のみ。生の通知も表示
./SurfaceMuteBridge --teams            # 検知して通話アプリへ送る
./SurfaceMuteBridge --device "名前の一部"  # 別の名前のヘッドフォンを監視
```

## 制約

- 動作確認は Surface Headphones（ファームウェア 16.1.0）と macOS 26 の組み合わせのみ。
- アプリ側がショートカットを変えた場合は `SurfaceMuteBridge.swift` の `callApps` を直す必要があります。
- 同じウィンドウで Meet 以外のタブを表示している間は、Meet には送りません
  （Cmd+D が「ブックマークに追加」になるため）。

## ライセンス

[MIT](LICENSE)
