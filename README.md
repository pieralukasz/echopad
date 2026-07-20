# echopad

Local-first macOS menu bar app and CLI for recording meetings. It records microphone + system audio (Zoom, Google Meet, Teams), transcribes locally with Parakeet v3 or Whisper, and saves everything to Obsidian.

No cloud services. No subscriptions. **Everything runs on-device.**

## Quick install — menu bar app

Requirements: Apple Silicon Mac with macOS 14+, Homebrew, Xcode Command Line Tools, and Obsidian.

```bash
brew install python ffmpeg whisper-cpp
git clone https://github.com/pieralukasz/echopad.git
cd echopad

python3 -m venv .venv
.venv/bin/pip install -r requirements.txt

scripts/build-app.sh --install
open ~/Applications/EchoPad.app
```

On first launch, EchoPad asks you to select an Obsidian vault. It then downloads Parakeet v3 once and keeps it loaded while the app is running. Grant Microphone and Screen Recording permissions when macOS asks.

For speaker identification, install the optional dependencies with `.venv/bin/pip install -r requirements-diarization.txt`, then follow the diarization setup below.

## Privacy

echopad is fully local. Your audio never leaves your computer.

- **Transcription** — runs on Apple Silicon via FluidAudio/Parakeet v3 or `mlx-whisper` (no cloud API)
- **Speaker diarization** — runs on Apple Silicon via `pyannote.audio` (no cloud API)
- **Audio capture** — macOS ScreenCaptureKit (system API, no third-party drivers)
- **Storage** — audio + transcripts saved to your local Obsidian vault

The only network request is a **one-time model download** (~470 MB for Parakeet v3, ~1.5 GB for Whisper, ~300 MB for pyannote) on first run. After that, echopad works fully offline.

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

- **Native menu bar app** — click the waveform icon or use Cmd+Shift+E from any app
- **Fast Polish transcription** — Parakeet v3 stays loaded in the menu app and uses Apple Silicon acceleration
- **Whisper fallback** — switch to Large v3 Turbo or Small from the menu
- **System audio capture** — records remote participants (Zoom/Meet/Teams) via ScreenCaptureKit, no virtual audio drivers needed
- **Speaker diarization** — identifies individual speakers using pyannote.audio, labels your voice with your username
- **Live preview** — see approximate transcription in the terminal while recording
- **Global hotkey** — Cmd+Shift+E to start/stop recording from any app (daemon mode)
- **Filler filtering** — automatically removes runs of "yeah", "okay", "mhm" filler sequences
- **Hallucination filter** — filters out common Whisper artifacts on silence
- **Obsidian integration** — saves markdown transcript + WAV audio to your vault
- **Multi-language** — auto-detects Polish, English, and 90+ other languages
- **Fully local** — no cloud, no subscriptions, no data leaves your machine

## Requirements

- **macOS 14+** on Apple Silicon
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
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
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

# The native app build compiles audio-capture automatically.
scripts/build-app.sh --install
```

### 5. Build the native menu bar app

The build downloads and pins FluidAudio, embeds the Parakeet runtime, signs the app locally, and installs it in `~/Applications`:

```bash
scripts/build-app.sh --install
open ~/Applications/EchoPad.app
```

On its first launch EchoPad downloads Parakeet v3. Keep the app running in the menu bar so the model remains warm; subsequent transcriptions start immediately. The app also creates `~/Library/LaunchAgents/com.echopad.app.plist` so it starts after login.

### 6. Add to PATH

```bash
ln -sf "$(pwd)/echopad.py" ~/.local/bin/echopad

# Make sure ~/.local/bin is in your PATH (add to ~/.zshrc if needed)
export PATH="$HOME/.local/bin:$PATH"
```

### 7. Set up speaker diarization (free, optional)

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

### 8. Configure (optional)

The app creates `config.json` after you choose a vault. To configure it manually, start from the safe example:

```bash
cp config.example.json config.json
```

Available settings:

```json
{
  "vault_path": "~/path/to/your/obsidian/vault",
  "meetings_dir": "Meetings",
  "transcription_backend": "parakeet",
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
| `transcription_backend` | Final transcription engine: `parakeet` or `whisper` | `parakeet` |
| `model` | MLX Whisper model for final transcription | `mlx-community/whisper-large-v3-turbo` |
| `sample_rate` | Audio sample rate in Hz | `16000` |
| `language` | Force language (`pl`, `en`) or `null` for auto | `null` |
| `open_in_obsidian` | Open transcript in Obsidian after saving | `true` |
| `capture_system_audio` | Record system audio alongside mic | `true` |
| `diarization` | Enable speaker identification | `true` |
| `diarization_device` | PyTorch device for diarization (`mps`, `cpu`) | `mps` |
| `hf_token` | HuggingFace token for pyannote model | `null` |

## Usage

### Menu bar app (recommended)

- Click the waveform icon and choose **Rozpocznij nagrywanie**, or press **Cmd+Shift+E**.
- Press **Cmd+Shift+E** again to stop. The icon shows transcription, diarization, and saving progress.
- Choose **Nagraj z tytułem…** when you want to name the Obsidian note first.
- Choose **Vault: …** at any time to select a different Obsidian vault. New notes and audio will be saved there immediately; no restart is needed.
- Keep **Parakeet v3 — bardzo szybki** selected for fast Polish transcription.
- Enable **Rozpoznawaj mówców (wolniej)** only when speaker labels are worth the additional wait.

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

### Legacy hotkey daemon

The standalone hotkey daemon below is retained for older installations. New installations should use the menu bar app, which registers the shortcut without an Accessibility event tap.

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

4. **Test**: Press **Cmd+Shift+E** — you should get a notification "Recording: [tab title]". Press again to stop.

#### How it works

- `echopad-hotkey` — Swift binary that registers a global CGEvent tap for Cmd+Shift+E
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

With the default Parakeet backend:

```
sounddevice      -->  mic buffer     (your microphone)
audio-capture    -->  sys.wav + pipe (system audio: Zoom/Meet/Teams)
final mixed WAV  -->  menu app       (resident FluidAudio/Parakeet v3)
                                      --> Obsidian note
```

The menu app loads Parakeet once and exposes it only on localhost. The Python recorder sends the final WAV to that resident process, avoiding model startup cost for every note. If the service is unavailable, EchoPad starts its bundled Parakeet helper as a fallback. The Whisper backend retains chunked transcription and terminal live preview.

After you stop:

1. Mic and system audio are merged and transcribed locally
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
  |- Parakeet client      Resident FluidAudio service, with CLI fallback
  |- ChunkedTranscriber   Optional MLX Whisper backend
  |- ffmpeg               Audio merge (mic + system -> meeting.wav)
  |- diarize.py           Speaker diarization (pyannote.audio)
  '- obsidian://          Opens transcript in Obsidian

audio-capture.swift       ScreenCaptureKit CLI
macos/EchoPadApp.swift    Native menu bar app, hotkey, status UI, Parakeet service
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
Set `hf_token` in `config.json`. See [Set up speaker diarization](#7-set-up-speaker-diarization-free-optional).

**"Could not use mps" warning**
Some PyTorch operations may not be supported on MPS yet. echopad falls back to CPU automatically. CPU diarization is slower (~10-15 min for 1h meeting) but works.

## License

MIT
