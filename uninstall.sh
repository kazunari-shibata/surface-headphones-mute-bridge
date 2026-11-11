#!/bin/zsh
# SurfaceMuteBridge の常駐を止め、設置したファイルを取り除く。
# アクセシビリティの一覧に残る項目は、システム設定から手動で外すこと。
set -uo pipefail

LABEL=local.surface-mute-bridge
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/SurfaceMuteBridge.app"
echo "取り除きました。ログは $HOME/Library/Logs/SurfaceMuteBridge.log に残っています。"
