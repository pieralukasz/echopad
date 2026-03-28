# echopad

Local-first CLI tool for recording meetings with **live transcription** in the terminal. Records microphone + system audio (Zoom, Google Meet, Teams), transcribes using Whisper models running entirely on your Mac, and saves everything to Obsidian.

No cloud services. No subscriptions. Everything runs on-device.

## Demo

```
  🎙 echopad
  Language: auto-detect | Audio: mic + system

  ● REC (mic + system)  Press Enter to stop
    live preview (medium model) — final transcript uses large-v3-turbo

  ● 00:05  Alright, let's kick off the sprint planning.
  ● 00:11  Can everyone see my screen?
  ● 00:17  Yeah, looks good. So for Q2, the main focus is auth.

  ■ Stopped after 05:23
  ⟳ Mixing audio...

  Meeting title: Sprint Planning

  ⟳ Transcribing (alex)...
  ⟳ Transcribing (system)...

  [00:00] (alex) Alright, let's kick off the sprint planning.
          Can everyone see my screen?
  [00:08] (system) Yeah, looks good. I can see it.
  [00:12] (alex) Great. So for Q2, the main focus is the new
          authentication system. We need to migrate from
          session tokens to JWTs.
  [00:25] (system) Makes sense. What's the timeline on that?
  [00:30] (alex) We're targeting end of April. I've broken it
          down into three epics — let me walk you through them.
  [00:42] (system) Sounds good. One thing — are we also
          handling the mobile token refresh in this sprint?
  [00:50] (alex) Good question. Let's add that as a separate
          story under the second epic.

  ✓ Saved to Obsidian: 2026-03-28 14.00 - Sprint Planning.md
  ✓ Opened in Obsidian
```

**Two-pass transcription:**
- **Live preview** (during recording) — `whisper-stream` with medium model. Fast but approximate.
- **Final transcript** (after recording) — `mlx-whisper` with `large-v3-turbo`. High quality, with speaker labels (`username` for mic, `system` for Zoom/Meet/Teams audio).

## Features

- **Live transcription** — see what's being said in real-time while recording
- **System audio capture** — records remote participants (Zoom/Meet/Teams) via ScreenCaptureKit, no virtual audio drivers needed
- **Speaker identification** — mic transcribed as your macOS username, system audio as `system`
- **Two-pass transcription** — fast live preview + high-quality final with `large-v3-turbo`
- **Obsidian integration** — saves markdown transcript + WAV audio to your vault
- **Multi-language** — auto-detects Polish, English, and 90+ other languages
- **Hallucination filter** — filters out common Whisper artifacts on silence

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

`whisper-cpp` provides `whisper-stream` (live transcription). `ffmpeg` merges mic + system audio.

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

# Compile the Swift audio capture tool
swiftc -O -o audio-capture audio-capture.swift \
  -framework ScreenCaptureKit -framework CoreMedia -framework AVFoundation
```

### 5. Add to PATH

```bash
ln -sf "$(pwd)/record-meeting.py" ~/.local/bin/record-meeting

# Make sure ~/.local/bin is in your PATH (add to ~/.zshrc if needed)
export PATH="$HOME/.local/bin:$PATH"
```

That's it. Run `record-meeting` from any terminal window and recording starts immediately.

### 6. Configure (optional)

Edit `config.json` to point to your Obsidian vault:

```json
{
  "vault_path": "~/Documents/Obsidian/Vault",
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
| `vault_path` | Path to your Obsidian vault | iCloud Obsidian path |
| `meetings_dir` | Folder for transcripts inside vault | `Meetings` |
| `model` | MLX Whisper model for final transcription | `mlx-community/whisper-large-v3-turbo` |
| `sample_rate` | Audio sample rate in Hz | `16000` |
| `language` | Force language (`pl`, `en`) or `null` for auto | `null` |
| `open_in_obsidian` | Open transcript in Obsidian after saving | `true` |
| `capture_system_audio` | Record system audio alongside mic | `true` |

## Permissions

On first run, macOS will ask for:

1. **Microphone access** — for recording your voice
2. **Screen Recording** — for capturing system audio via ScreenCaptureKit

Grant both in **System Settings > Privacy & Security**.

## Usage

```bash
record-meeting                              # auto-detect language, mic + system
record-meeting "Sprint Planning"            # with title
record-meeting --pl                         # force Polish
record-meeting --en "Team Standup"          # force English + title
record-meeting --no-system                  # mic only (in-person meetings)
record-meeting --pl --no-system "Standup"   # combine flags
```

## How it works

Three processes run in parallel during recording:

```
sounddevice      -->  mic.wav      (your microphone)
audio-capture    -->  sys.wav      (system audio: Zoom/Meet/Teams)
whisper-stream   -->  terminal     (live preview, medium model)
```

After you press **Enter**:

1. `ffmpeg` merges mic + system into one WAV (for archival/playback)
2. `mlx-whisper` (`large-v3-turbo`) transcribes mic and system **separately**
3. Mic segments labeled as your macOS username, system segments as `system`
4. Segments interleaved by timestamp, saved as markdown to Obsidian

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

[00:00] **(alex)** Alright, let's kick off the sprint planning.

[00:08] **(system)** Yeah, looks good. I can see your screen.

[00:12] **(alex)** Great. So for Q2, the main focus is the new auth system.
```

## Architecture

```
record-meeting.py          CLI entry point (Python)
  ├── sounddevice          Microphone recording → mic.wav
  ├── audio-capture        System audio (Swift/ScreenCaptureKit) → sys.wav
  ├── whisper-stream       Live preview (whisper.cpp, medium model)
  ├── ffmpeg               Audio merge (mic + system → meeting.wav)
  ├── mlx-whisper          Final transcription (large-v3-turbo, separate mic/system)
  └── obsidian://          Opens transcript in Obsidian

audio-capture.swift        ScreenCaptureKit CLI (~160 lines)
  ├── SCStream             Captures all system audio
  ├── SCStreamOutput       Receives CMSampleBuffer callbacks
  ├── Float32 → Int16      Converts to PCM
  └── WAV writer           Writes standard WAV file
```

## Troubleshooting

**"Thank you for watching" in live preview**
Whisper hallucinates on silence. The hallucination filter catches most cases. Specify a language explicitly to reduce this: `record-meeting --en` or `record-meeting --pl`.

**No system audio captured**
Grant **Screen Recording** permission to your terminal app in System Settings > Privacy & Security > Screen Recording.

**whisper-stream not found**
`brew install whisper-cpp`

**First run is slow**
The `large-v3-turbo` model (~1.5 GB) downloads on first use. After that, transcription is fast (~2 min for a 1-hour meeting on M1 Max).

## License

MIT
