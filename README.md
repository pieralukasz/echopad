# echopad

Local-first CLI tool for recording meetings with **live transcription** in the terminal. Records microphone + system audio (Zoom, Google Meet, Teams), transcribes using Whisper models running entirely on your Mac, and saves everything to Obsidian.

No cloud services. No subscriptions. **Everything runs on-device.**

## Privacy

echopad is fully local. Your audio never leaves your computer.

- **Transcription** — runs on Apple Silicon via `mlx-whisper` (no cloud API)
- **Speaker diarization** — runs on Apple Silicon via `pyannote.audio` (no cloud API)
- **Audio capture** — macOS ScreenCaptureKit (system API, no third-party drivers)
- **Storage** — audio + transcripts saved to your local Obsidian vault

The only network request is a **one-time model download** (~1.5 GB for Whisper, ~300 MB for pyannote) from HuggingFace on first run. After that, echopad works fully offline.

## Demo

```
  echopad
  Language: auto-detect | Audio: mic + system

  REC (mic + system)  Press Enter to stop
    live preview on — transcribing in real-time with large-v3-turbo

  00:05  Alright, let's kick off the sprint planning.
  00:11  Can everyone see my screen?
  00:17  Yeah, looks good. So for Q2, the main focus is auth.

  Stopped after 05:23
  Mixing audio...
  Identifying speakers...

  [00:00] (Lukasz) Alright, let's kick off the sprint planning.
          Can everyone see my screen?
  [00:08] (Speaker 1) Yeah, looks good. I can see it.
  [00:12] (Lukasz) Great. So for Q2, the main focus is the new
          authentication system. We need to migrate from
          session tokens to JWTs.
  [00:25] (Speaker 1) Makes sense. What's the timeline on that?

  Saved to Obsidian: 2026-03-28 14.00 - Sprint Planning.md
  Opened in Obsidian
```

## Features

- **Real-time chunked transcription** — transcribes in 30-second chunks during recording, near-zero wait after you stop
- **System audio capture** — records remote participants (Zoom/Meet/Teams) via ScreenCaptureKit, no virtual audio drivers needed
- **Speaker diarization** — identifies individual speakers using pyannote.audio, labels your voice with your username
- **Live preview** — see approximate transcription in the terminal while recording
- **Global hotkey** — Ctrl+Shift+E to start/stop recording from any app (daemon mode)
- **Filler filtering** — automatically removes runs of "yeah", "okay", "mhm" filler sequences
- **Hallucination filter** — filters out common Whisper artifacts on silence
- **Obsidian integration** — saves markdown transcript + WAV audio to your vault
- **Multi-language** — auto-detects Polish, English, and 90+ other languages
- **Fully local** — no cloud, no subscriptions, no data leaves your machine

## Requirements

- **macOS 15+** (Sequoia) on Apple Silicon (M1/M2/M3/M4)
- **Xcode Command Line Tools** (for compiling Swift tools)
- **Homebrew** packages
- **Python 3.11+** with specific packages
- **Obsidian** (optional, for saving transcripts)

## Installation

### 1. Install Homebrew dependencies

```bash
brew install whisper-cpp ffmpeg
```

`whisper-cpp` provides `whisper-stream` (live transcription). `ffmpeg` merges mic + system audio.

### 2. Install Python dependencies

```bash
pip3 install --break-system-packages mlx-whisper sounddevice soundfile numpy pyannote.audio
```

| Package | Purpose |
|---------|---------|
| `mlx-whisper` | Final high-quality transcription (Apple Silicon optimized) |
| `sounddevice` | Microphone recording |
| `soundfile` | WAV file writing |
| `numpy` | Audio buffer handling |
| `pyannote.audio` | Speaker diarization (who said what) |

### 3. Download Whisper models

**For live preview** (whisper-stream needs a ggml model):

```bash
mkdir -p ~/.config/open-wispr/models

curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin" \
  -o ~/.config/open-wispr/models/ggml-medium.bin
```

**For final transcription** (downloads automatically on first run):

The `mlx-community/whisper-large-v3-turbo` model (~1.5 GB) will be downloaded automatically to `~/.cache/huggingface/` on first use.

### 4. Clone and build

```bash
git clone https://github.com/pieralukasz/echopad.git
cd echopad

# Compile Swift tools
swiftc -O -o audio-capture audio-capture.swift \
  -framework ScreenCaptureKit -framework CoreMedia -framework AVFoundation

swiftc -O -o echopad-hotkey echopad-hotkey.swift \
  -framework Cocoa -framework Carbon

# Compile mic-monitor (needed for watcher mode only)
swiftc -O -o mic-monitor mic-monitor.swift \
  -framework CoreAudio -framework AudioToolbox
```

### 5. Add to PATH

```bash
ln -sf "$(pwd)/echopad.py" ~/.local/bin/echopad

# Make sure ~/.local/bin is in your PATH (add to ~/.zshrc if needed)
export PATH="$HOME/.local/bin:$PATH"
```

### 6. Set up speaker diarization (free, optional)

Speaker diarization identifies **who said what** in your meetings. The pyannote model is free but requires a HuggingFace account to accept the license terms.

1. Create a free account at [huggingface.co](https://huggingface.co)
2. Visit [pyannote/speaker-diarization-3.1](https://hf.co/pyannote/speaker-diarization-3.1) and click **Agree** to accept the model terms
3. Generate an access token at [huggingface.co/settings/tokens](https://hf.co/settings/tokens)
4. Add the token to `config.json`:

```json
{
  "hf_token": "hf_your_token_here"
}
```

The model (~300 MB) downloads once on first use and then runs **entirely on your machine**. No audio is ever sent to HuggingFace — the token is only used to download the model files.

Without this step, echopad still works — you just won't get speaker labels in the transcript.

### 7. Configure (optional)

Copy and edit `config.json`:

```json
{
  "vault_path": "~/path/to/your/obsidian/vault",
  "meetings_dir": "Meetings",
  "model": "mlx-community/whisper-large-v3-turbo",
  "sample_rate": 16000,
  "language": null,
  "open_in_obsidian": true,
  "capture_system_audio": true,
  "diarization": true,
  "diarization_device": "mps",
  "hf_token": null
}
```

| Setting | Description | Default |
|---------|-------------|---------|
| `vault_path` | Path to your Obsidian vault | iCloud Obsidian path |
| `meetings_dir` | Folder for transcripts inside vault | `Meetings` |
| `model` | MLX Whisper model for final transcription | `mlx-community/whisper-large-v3-turbo` |
| `sample_rate` | Audio sample rate in Hz | `16000` |
| `language` | Force language (`pl`, `en`) or `null` for auto | `null` |
| `open_in_obsidian` | Open transcript in Obsidian after saving | `true` |
| `capture_system_audio` | Record system audio alongside mic | `true` |
| `diarization` | Enable speaker identification | `true` |
| `diarization_device` | PyTorch device for diarization (`mps`, `cpu`) | `mps` |
| `hf_token` | HuggingFace token for pyannote model | `null` |

## Usage

### Interactive mode (CLI)

```bash
echopad                              # auto-detect language, mic + system
echopad "Sprint Planning"            # with title
echopad --pl                         # force Polish
echopad --en "Team Standup"          # force English + title
echopad --no-system                  # mic only (in-person meetings)
echopad --pl --no-system "Standup"   # combine flags
```

Press **Enter** to stop recording.

### Daemon mode (keyboard shortcut)

Start/stop recording with a global hotkey (**Ctrl+Shift+E**) from any app, including Brave and other Chromium browsers.

#### Setup

1. **Create the .app bundle** (for Accessibility permission):

```bash
mkdir -p EchopadHotkey.app/Contents/MacOS
cp echopad-hotkey EchopadHotkey.app/Contents/MacOS/EchopadHotkey

cat > EchopadHotkey.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.echopad.hotkey</string>
    <key>CFBundleName</key>
    <string>EchopadHotkey</string>
    <key>CFBundleExecutable</key>
    <string>EchopadHotkey</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
```

2. **Grant Accessibility permission**: System Settings > Privacy & Security > Accessibility > add `EchopadHotkey.app`

3. **Install the LaunchAgent** (auto-start on login):

```bash
cat > ~/Library/LaunchAgents/com.echopad.hotkey.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.echopad.hotkey</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(pwd)/EchopadHotkey.app/Contents/MacOS/EchopadHotkey</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/echopad-hotkey.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/echopad-hotkey.log</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LimitLoadToSessionType</key>
    <array>
        <string>Aqua</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
</dict>
</plist>
EOF

launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.echopad.hotkey.plist
```

4. **Test**: Press **Ctrl+Shift+E** — you should get a notification "Recording: [tab title]". Press again to stop.

#### How it works

- `echopad-hotkey` — Swift binary that registers a global CGEvent tap for Ctrl+Shift+E
- `echopad-toggle` — Shell script that starts/stops echopad via PID file
- On start: gets the active browser tab title, launches `echopad.py --daemon`
- On stop: sends SIGTERM, echopad transcribes and saves to Obsidian
- macOS notification on start ("Recording: ...") and on finish ("Transcript saved to Obsidian")

## Permissions

On first run, macOS will ask for:

1. **Microphone access** — for recording your voice
2. **Screen Recording** — for capturing system audio via ScreenCaptureKit
3. **Accessibility** — for the global hotkey (daemon mode only)

Grant all in **System Settings > Privacy & Security**.

## How it works

During recording, four processes run in parallel:

```
sounddevice      -->  mic buffer     (your microphone)
audio-capture    -->  sys.wav + pipe (system audio: Zoom/Meet/Teams)
whisper-stream   -->  terminal       (live preview, medium model)
ChunkedTranscriber    <-- mixed chunks every 30s --> mlx-whisper (large-v3-turbo)
```

Every 30 seconds, mic and system audio are mixed into a chunk and transcribed by `mlx-whisper` in a background thread. This spreads the CPU load over the entire recording instead of spiking at the end.

After you stop:

1. Final audio chunk is submitted and transcribed (seconds, not minutes)
2. `ffmpeg` merges mic + system into one WAV for archival/playback
3. `pyannote.audio` runs speaker diarization on the mixed audio (optional, ~3-5 min for 1h meeting)
4. Speaker labels mapped to transcription segments, local user identified via mic energy correlation
5. Filler sequences collapsed, transcript saved as markdown to Obsidian

## Output

### File structure

```
Obsidian Vault/
  Meetings/
    2026-03-28 14.00 - Sprint Planning.md      <-- transcript
  attachments/meetings/
    2026-03-28 14.00 - Sprint Planning.wav      <-- audio (mic + system merged)
```

### Transcript format

```markdown
---
type: meeting_transcript
date: 2026-03-28
title: "Sprint Planning"
language: auto
source: "echopad"
duration: "00:47:23"
audio: "[[attachments/meetings/2026-03-28 14.00 - Sprint Planning.wav]]"
---

# Sprint Planning — Transcript

[00:00] **(Lukasz)** Alright, let's kick off the sprint planning.

[00:08] **(Speaker 1)** Yeah, looks good. I can see your screen.

[00:12] **(Lukasz)** Great. So for Q2, the main focus is the new auth system.
```

## Architecture

```
echopad.py               CLI entry point (Python)
  |- sounddevice          Microphone recording -> mic buffer
  |- audio-capture        System audio (Swift/ScreenCaptureKit) -> sys.wav + stdout pipe
  |- whisper-stream       Live preview (whisper.cpp, medium model)
  |- ChunkedTranscriber   Real-time 30s chunk transcription (mlx-whisper, large-v3-turbo)
  |- ffmpeg               Audio merge (mic + system -> meeting.wav)
  |- diarize.py           Speaker diarization (pyannote.audio)
  '- obsidian://          Opens transcript in Obsidian

audio-capture.swift       ScreenCaptureKit CLI
echopad-hotkey.swift      Global hotkey daemon (CGEvent tap)
echopad-toggle            Shell script for daemon start/stop
diarize.py                Speaker diarization module
mic-monitor.swift         CoreAudio mic activity monitor (for watcher mode)
echopad-watcher.py        Auto-detection daemon (deprecated, use hotkey instead)
```

## Troubleshooting

**Hotkey not working**
Check `~/Library/Logs/echopad-hotkey.log`. If it says "Failed to create event tap", add `EchopadHotkey.app` to Accessibility in System Settings. If you recompile echopad-hotkey, you need to re-add the .app to Accessibility (macOS resets permission for changed binaries).

**"Thank you for watching" in live preview**
Whisper hallucinates on silence. The hallucination filter catches most cases. Specify a language explicitly to reduce this: `echopad --en` or `echopad --pl`.

**No system audio captured**
Grant **Screen Recording** permission to your terminal app in System Settings > Privacy & Security > Screen Recording.

**whisper-stream not found**
`brew install whisper-cpp`

**First run is slow**
Models download on first use: `large-v3-turbo` (~1.5 GB) and `pyannote/speaker-diarization-3.1` (~300 MB). After that, everything is cached locally.

**Diarization skipped**
Set `hf_token` in `config.json`. See [Set up speaker diarization](#6-set-up-speaker-diarization-free-optional).

**"Could not use mps" warning**
Some PyTorch operations may not be supported on MPS yet. echopad falls back to CPU automatically. CPU diarization is slower (~10-15 min for 1h meeting) but works.

## License

MIT
