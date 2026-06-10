#!/usr/bin/env bash
# Install plan-bot autostart-at-login for the CURRENT USER.
#   macOS -> ~/Library/LaunchAgents LaunchAgent (launchd, RunAtLoad)
#   Linux -> systemd --user service if available, else ~/.config/autostart (XDG desktop login)
# Idempotent. On/off stays AUTOSTART in bot/.env (read by start-bot.sh --auto), same as Windows.
#
# NOTE: autostart only LAUNCHES the bot. It still needs, on THIS machine:
#   the `claude` CLI authenticated, the target repos checked out, and a Unix-path .env.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LAUNCHER="$DIR/start-bot.sh"
[ -f "$LAUNCHER" ] || { echo "missing $LAUNCHER"; exit 1; }
chmod +x "$LAUNCHER" || true

OS="$(uname -s)"
case "$OS" in
  Darwin)
    LABEL="com.plan-bot.autostart"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$LAUNCHER</string>
    <string>--auto</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>StandardOutPath</key><string>$DIR/bot.out.log</string>
  <key>StandardErrorPath</key><string>$DIR/bot.err.log</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load -w "$PLIST"
    echo "OK (macOS): installed LaunchAgent -> $PLIST"
    echo "  toggle:  edit AUTOSTART in $DIR/.env   (1=on, 0=off)"
    echo "  remove:  launchctl unload -w \"$PLIST\" && rm \"$PLIST\""
    ;;
  Linux)
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      UNIT="$HOME/.config/systemd/user/plan-bot.service"
      mkdir -p "$HOME/.config/systemd/user"
      cat > "$UNIT" <<EOF
[Unit]
Description=plan-bot Telegram launcher
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DIR
ExecStart=/usr/bin/env bash "$LAUNCHER" --auto

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload
      systemctl --user enable plan-bot.service
      systemctl --user start plan-bot.service || true
      echo "OK (Linux/systemd --user): installed -> $UNIT"
      echo "  headless server (start at boot without GUI login): sudo loginctl enable-linger \"$USER\""
      echo "  toggle:  edit AUTOSTART in $DIR/.env   (1=on, 0=off)"
      echo "  remove:  systemctl --user disable --now plan-bot.service && rm \"$UNIT\""
    else
      DESK="$HOME/.config/autostart/plan-bot.desktop"
      mkdir -p "$HOME/.config/autostart"
      cat > "$DESK" <<EOF
[Desktop Entry]
Type=Application
Name=plan-bot
Exec=/usr/bin/env bash "$LAUNCHER" --auto
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
      echo "OK (Linux/XDG): installed -> $DESK (runs at desktop login)"
      echo "  toggle:  edit AUTOSTART in $DIR/.env   (1=on, 0=off)"
      echo "  remove:  rm \"$DESK\""
    fi
    ;;
  *)
    echo "Unsupported OS: $OS  (Windows uses start-bot.ps1 + the Startup .vbs)"; exit 1 ;;
esac
