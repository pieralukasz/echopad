# Meeting Recorder

Local-first CLI tool for recording meetings with **live transcription** in the terminal. Records microphone + system audio (Zoom, Google Meet, Teams), transcribes using Whisper models running entirely on your Mac, and saves everything to Obsidian.

No cloud services. No subscriptions. Everything runs on-device.

## Features

- **Live transcription** - see what you're saying in real-time while recording
- **System audio capture** - records both your microphone and remote participants (Zoom/Meet/Teams) via ScreenCaptureKit
- **Speaker identification** - labels segments as "Ja" (you, from mic) and "Rozmowca" (others, from system audio)
- **Two-pass transcription** - fast live preview (whisper-stream + medium model), then high-quality final transcription (mlx-whisper + large-v3-turbo)
- **Obsidian integration** - saves markdown transcript + audio file to your vault, opens the note automatically
- **Multi-language** - auto-detects Polish, English, and 90+ other languages
- **Hallucination filter** - filters out common Whisper artifacts on silence ("Thank you for watching", etc.)

## Requirements

- **macOS 15+** (Sequoia) on Apple Silicon (M1/M2/M3/M4)
- **Xcode Command Line Tools** (for compiling the Swift audio capture tool)
- **Homebrew** packages
- **Python 3.11+** with specific packages
- **Obsidian** (optional, for saving transcripts)

## Installation

### 1. Install Homebrew dependencies

```bash
brew install whisper-cpp ffmpeg
```

`whisper-cpp` provides `whisper-stream` (live transcription). `ffmpeg` is used to merge mic + system audio.

### 2. Install Python dependencies

```bash
pip3 install mlx-whisper sounddevice soundfile numpy
```

| Package | Purpose |
|---------|---------|
| `mlx-whisper` | Final high-quality transcription (Apple Silicon optimized) |
| `sounddevice` | Microphone recording |
| `soundfile` | WAV file writing |
| `numpy` | Audio buffer handling |

### 3. Download Whisper models

**For live transcription** (whisper-stream needs a ggml model):

```bash
# Create model directory
mkdir -p ~/.config/open-wispr/models

# Download medium model (~1.5 GB) - good balance of speed/quality for live preview
curl -L "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin" \
  -o ~/.config/open-wispr/models/ggml-medium.bin
```

**For final transcription** (mlx-whisper downloads automatically on first run):

The `mlx-community/whisper-large-v3-turbo` model (~1.5 GB) will be downloaded automatically to `~/.cache/huggingface/` the first time you run a transcription.

### 4. Clone and build

```bash
git clone https://github.com/pieralukasz/meeting-recorder.git
cd meeting-recorder

# Compile the Swift audio capture tool (ScreenCaptureKit)
swiftc -O -o audio-capture audio-capture.swift \
  -framework ScreenCaptureKit -framework CoreMedia -framework AVFoundation
```

### 5. Add to PATH

```bash
# Symlink to a directory in your PATH
ln -sf "$(pwd)/record-meeting.py" ~/.local/bin/record-meeting

# Make sure ~/.local/bin is in your PATH (add to ~/.zshrc if needed)
export PATH="$HOME/.local/bin:$PATH"
```

### 6. Configure (optional)

Edit `config.json` to point to your Obsidian vault:

```json
{
  "vault_path": "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault",
  "meetings_dir": "Meetings",
  "model": "mlx-community/whisper-large-v3-turbo",
  "sample_rate": 16000,
  "language": null,
  "open_in_obsidian": true,
  "capture_system_audio": true
}
```

| Setting | Description | Default |
|---------|-------------|---------|
| `vault_path` | Path to your Obsidian vault | `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Life` |
| `meetings_dir` | Folder for transcripts inside vault | `Meetings` |
| `model` | MLX Whisper model for final transcription | `mlx-community/whisper-large-v3-turbo` |
| `sample_rate` | Audio sample rate in Hz | `16000` |
| `language` | Force language (`pl`, `en`, etc.) or `null` for auto-detect | `null` |
| `open_in_obsidian` | Open transcript in Obsidian after saving | `true` |
| `capture_system_audio` | Record system audio (Zoom/Meet) alongside mic | `true` |

## Permissions

On first run, macOS will ask for:

1. **Microphone access** - for recording your voice
2. **Screen Recording** - for capturing system audio via ScreenCaptureKit (even though no video is recorded)

Grant both in **System Settings > Privacy & Security**.

## Usage

```bash
# Basic - auto-detect language, record mic + system audio
record-meeting

# Set title upfront
record-meeting "Sprint Planning"

# Force Polish language
record-meeting --pl

# Force English
record-meeting --en "Team Standup"

# Mic only (no system audio - for in-person meetings)
record-meeting --no-system

# Combine flags
record-meeting --pl --no-system "Spotkanie zespolu"
```

## How it works

When you run `record-meeting`, three processes start in parallel:

```
sounddevice      -->  mic.wav      (your microphone)
audio-capture    -->  sys.wav      (system audio: Zoom/Meet/Teams)
whisper-stream   -->  terminal     (live transcription preview)
```

### During recording

You see live transcription in the terminal as you speak:

```
  🎙 Meeting Recorder
  Language: auto-detect | Audio: mic + system

  ● REC (mic + system audio)  Press Enter to stop

  ● 00:05  Hello everyone, welcome to the meeting
  ● 00:12  Today we're going to discuss the Q2 roadmap
  ● 00:18  First item on the agenda is the authentication system
```

Press **Enter** to stop recording.

### After recording

1. `ffmpeg` merges mic + system audio into one WAV (for archival)
2. `mlx-whisper` transcribes each source separately with speaker labels
3. Segments are interleaved by timestamp
4. Markdown + WAV are saved to your Obsidian vault

```
  ■ Stopped after 05:23

  Meeting title: Sprint Planning

  ⟳ Transcribing mic (Ja)...
  ⟳ Transcribing system audio (Rozmowca)...

  Language: en

  [00:00] (Ja) Hello everyone, welcome to the meeting.
  [00:05] (Rozmowca) Hi! Can you hear me okay?
  [00:08] (Ja) Yes, loud and clear. Let's start.
  [00:12] (Rozmowca) Sure. So for Q2, I think we should focus on...

  ✓ Saved to Obsidian: 2026-03-28 14.00 - Sprint Planning.md
  ✓ Opened in Obsidian
```

## Output

### File structure in Obsidian

```
My Vault/
  Meetings/
    2026-03-28 14.00 - Sprint Planning.md     <-- transcript
    2026-03-28 15.30 - Team Standup.md
  attachments/meetings/
    2026-03-28 14.00 - Sprint Planning.wav     <-- audio
    2026-03-28 15.30 - Team Standup.wav
```

### Transcript format

```markdown
---
type: meeting_transcript
date: 2026-03-28
title: "Sprint Planning"
language: en
source: "meeting-recorder"
duration: "00:47:23"
model: "whisper-large-v3-turbo"
audio: "[[attachments/meetings/2026-03-28 14.00 - Sprint Planning.wav]]"
---

# Sprint Planning — Transcript

[00:00] **(Ja)** Hello everyone, welcome to the meeting.

[00:05] **(Rozmowca)** Hi! Can you hear me okay?

[00:08] **(Ja)** Yes, loud and clear. Let's start with the Q2 roadmap.
```

## Architecture

```
record-meeting.py          CLI entry point (Python)
  ├── sounddevice          Microphone recording
  ├── audio-capture        System audio capture (Swift/ScreenCaptureKit)
  ├── whisper-stream       Live transcription preview (whisper.cpp)
  ├── ffmpeg               Audio merging (mic + system)
  ├── mlx-whisper          Final transcription (Apple Silicon optimized)
  └── obsidian://          Opens transcript in Obsidian

audio-capture.swift        ScreenCaptureKit CLI (~160 lines)
  ├── SCStream             Captures all system audio
  ├── SCStreamOutput       Receives CMSampleBuffer callbacks
  ├── Float32 → Int16      Converts to PCM
  └── WAV writer           Writes standard WAV file

config.json                User configuration
```

## Troubleshooting

**"Thank you for watching" in live preview**
Whisper hallucinates on silence. The hallucination filter catches most cases. If it persists, specify a language explicitly: `record-meeting --en` or `record-meeting --pl`.

**No system audio captured**
Make sure you granted **Screen Recording** permission to your terminal app (Terminal, iTerm2, etc.) in System Settings > Privacy & Security > Screen Recording.

**whisper-stream not found**
Install it: `brew install whisper-cpp`

**Transcription is slow**
The first run downloads the `whisper-large-v3-turbo` model (~1.5 GB). Subsequent runs are fast. On M1 Max, a 1-hour meeting transcribes in ~2 minutes.

**Audio quality is poor**
The default sample rate is 16 kHz (optimal for Whisper). For better audio archival quality, change `sample_rate` to `44100` in `config.json`, though this won't improve transcription quality.

## License

MIT
