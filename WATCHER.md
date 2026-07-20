# echopad-watcher

Auto-starts echopad when a meeting begins (Google Meet in Brave, Slack Huddle) and stops when the meeting ends.

## Start

```bash
# Load LaunchAgent (starts now + on every login):
launchctl load ~/Library/LaunchAgents/com.echopad.watcher.plist

# Or run manually (foreground, for testing):
python3 ~/Projects/echopad/echopad-watcher.py
```

## Stop

```bash
# Unload LaunchAgent (stops now + won't start on login):
launchctl unload ~/Library/LaunchAgents/com.echopad.watcher.plist

# If running manually, just Ctrl+C
```

## Status

```bash
# Check if watcher is running:
launchctl list | grep echopad

# View logs:
tail -f ~/Library/Logs/echopad-watcher.log
```

## How it works

- Polls every 5s via AppleScript (Brave tabs + Slack windows)
- Starts echopad after 15s of confirmed meeting detection
- Stops echopad after 20s of no meeting detected
- 30s cooldown between meetings
- macOS notifications on start/stop
- Meeting title extracted from source (e.g. "Sprint Planning" from Meet tab title)
