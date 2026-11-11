#!/bin/zsh
# Stops the SurfaceHeadphonesMuteBridge login agent and removes the installed files.
# Remove the leftover entry in the Accessibility list by hand in System Settings.
set -uo pipefail

LABEL=local.surface-headphones-mute-bridge
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/SurfaceHeadphonesMuteBridge.app"
echo "Removed. The log is kept at $HOME/Library/Logs/SurfaceHeadphonesMuteBridge.log."
