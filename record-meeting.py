#!/usr/bin/env python3
"""Record a meeting → live transcription in terminal → save to Obsidian."""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

# ─── Config ──────────────────────────────────────────────────────────────────

PROJECT_DIR = Path.home() / "Projects" / "meeting-recorder"
CONFIG_PATH = PROJECT_DIR / "config.json"
AUDIO_CAPTURE_BIN = PROJECT_DIR / "audio-capture"
WHISPER_STREAM_BIN = "/opt/homebrew/bin/whisper-stream"
STREAM_MODEL = Path.home() / ".config/open-wispr/models/ggml-medium.bin"

DEFAULT_CONFIG = {
    "vault_path": "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Life",
    "meetings_dir": "Meetings",
    "model": "mlx-community/whisper-large-v3-turbo",
    "sample_rate": 16000,
    "language": None,
    "open_in_obsidian": True,
    "capture_system_audio": True,
}

# Whisper hallucinations on silence — filter these out
HALLUCINATION_PATTERNS = {
    "thank you", "thanks for watching", "subscribe", "like and subscribe",
    "thank you for watching", "see you next time", "bye", "goodbye",
    "blank_audio", "blank audio", "typing", "keyboard",
    "music", "applause", "laughter",
}


def load_config():
    config = DEFAULT_CONFIG.copy()
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            config.update(json.load(f))
    config["vault_path"] = os.path.expanduser(config["vault_path"])
    return config


# ─── Helpers ─────────────────────────────────────────────────────────────────


def fmt_elapsed(seconds: int) -> str:
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def fmt_duration(seconds: float) -> str:
    total = int(seconds)
    h, r = divmod(total, 3600)
    m, s = divmod(r, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def fmt_timestamp(seconds: float) -> str:
    total = int(seconds)
    h, r = divmod(total, 3600)
    m, s = divmod(r, 60)
    return f"[{h}:{m:02d}:{s:02d}]" if h else f"[{m:02d}:{s:02d}]"


def strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from text."""
    return re.sub(r"\x1b\[[0-9;]*[a-zA-Z]|\x1b\[2K", "", text)


def is_hallucination(text: str) -> bool:
    """Check if text is a known Whisper hallucination on silence."""
    clean = text.strip().lower().strip("[]() .")
    return any(h in clean for h in HALLUCINATION_PATTERNS) or len(clean) < 2


# ─── Record with Live Transcription ─────────────────────────────────────────


def record_with_live_transcription(config: dict) -> tuple[str, float]:
    """Record mic + system audio + show live transcription. Returns (wav_path, duration)."""
    vault_path = Path(config["vault_path"])
    audio_dir = vault_path / "attachments" / "meetings"
    audio_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y-%m-%d %H.%M")
    temp_name = f"{timestamp} - Meeting"
    mic_wav = str(audio_dir / f"{temp_name}_mic.wav")
    sys_wav = str(audio_dir / f"{temp_name}_sys.wav")
    final_wav = str(audio_dir / f"{temp_name}.wav")
    sample_rate = config["sample_rate"]
    capture_system = config.get("capture_system_audio", True)

    # ── 1. Start mic recording (sounddevice) ──
    chunks = []

    def audio_callback(indata, frames, time_info, status):
        chunks.append(indata.copy())

    mic_stream = sd.InputStream(
        samplerate=sample_rate,
        channels=1,
        dtype="int16",
        callback=audio_callback,
    )

    # ── 2. Start system audio capture (ScreenCaptureKit) ──
    sys_proc = None
    if capture_system:
        sys_cmd = [str(AUDIO_CAPTURE_BIN), "--output", sys_wav, "--sample-rate", str(sample_rate), "--no-mic"]
        sys_proc = subprocess.Popen(sys_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    # ── 3. Start whisper-stream for live transcription ──
    lang = config.get("language") or "auto"
    stream_cmd = [
        WHISPER_STREAM_BIN,
        "-m", str(STREAM_MODEL),
        "-l", lang,
        "--step", "3000",
        "--length", "10000",
        "--keep", "200",
        "--vad-thold", "0.6",
    ]

    whisper_proc = subprocess.Popen(
        stream_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    mic_stream.start()
    start = time.time()
    stop = False
    last_text = ""

    print()
    sources = "mic + system audio" if capture_system else "mic only"
    print(f"  \033[91m●\033[0m REC ({sources})  Press \033[1mEnter\033[0m to stop")
    print()

    # ── Thread: read whisper-stream output ──
    def read_stream():
        nonlocal last_text
        for line in whisper_proc.stdout:
            if stop:
                break
            clean = strip_ansi(line).strip()
            if not clean or clean == "[Start speaking]":
                continue
            if is_hallucination(clean):
                continue
            if clean == last_text:
                continue

            elapsed = int(time.time() - start)
            ts = fmt_elapsed(elapsed)

            is_refinement = False
            if last_text:
                if clean.startswith(last_text) or last_text.startswith(clean):
                    is_refinement = True
                else:
                    last_words = set(last_text.lower().split())
                    new_words = set(clean.lower().split())
                    if last_words and len(last_words & new_words) / len(last_words) > 0.5:
                        is_refinement = True

            last_text = clean

            if is_refinement:
                print(f"\r  \033[91m●\033[0m \033[90m{ts}\033[0m  {clean}\033[K", end="", flush=True)
            else:
                print(f"\n  \033[91m●\033[0m \033[90m{ts}\033[0m  {clean}\033[K", end="", flush=True)

    stream_thread = threading.Thread(target=read_stream, daemon=True)
    stream_thread.start()

    # ── Thread: wait for Enter ──
    def wait_for_enter():
        nonlocal stop
        input()
        stop = True

    enter_thread = threading.Thread(target=wait_for_enter, daemon=True)
    enter_thread.start()

    try:
        while not stop:
            time.sleep(0.5)
    except KeyboardInterrupt:
        stop = True

    duration = time.time() - start

    # ── Stop everything ──
    mic_stream.stop()
    mic_stream.close()

    whisper_proc.send_signal(signal.SIGINT)
    try:
        whisper_proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        whisper_proc.kill()
        whisper_proc.wait()

    if sys_proc:
        sys_proc.send_signal(signal.SIGINT)
        try:
            sys_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            sys_proc.terminate()
            sys_proc.wait()

    print(f"\n  \033[92m■\033[0m Stopped after {fmt_elapsed(int(duration))}                    ")

    # ── Save mic WAV ──
    audio_data = np.concatenate(chunks)
    sf.write(mic_wav, audio_data, sample_rate)

    has_sys = capture_system and os.path.exists(sys_wav) and os.path.getsize(sys_wav) > 44

    # ── Merge mic + system audio for archival WAV ──
    if has_sys:
        print("  \033[93m⟳\033[0m Mixing mic + system audio...")
        merge_cmd = [
            "ffmpeg", "-y", "-i", mic_wav, "-i", sys_wav,
            "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest[out]",
            "-map", "[out]", "-ar", str(sample_rate), "-ac", "1", final_wav,
        ]
        result = subprocess.run(merge_cmd, capture_output=True)
        if result.returncode == 0:
            print("  \033[92m✓\033[0m Audio merged")
        else:
            os.rename(mic_wav, final_wav)
            has_sys = False
            print("  \033[93m!\033[0m Merge failed, using mic audio only")
    else:
        os.rename(mic_wav, final_wav)

    # Return paths: final (merged), mic, sys (for separate transcription)
    return final_wav, mic_wav if has_sys else None, sys_wav if has_sys else None, duration


# ─── Final Transcription ─────────────────────────────────────────────────────


def _transcribe_wav(wav_path: str, config: dict):
    """Transcribe a single WAV with mlx-whisper. Returns result dict."""
    import mlx_whisper

    kwargs = {
        "path_or_hf_repo": config["model"],
        "word_timestamps": False,
        "verbose": False,
    }
    if config.get("language"):
        kwargs["language"] = config["language"]

    return mlx_whisper.transcribe(wav_path, **kwargs)


def transcribe_final(wav_path: str, mic_wav: str | None, sys_wav: str | None, config: dict) -> dict:
    """Transcribe with speaker labels. Returns result dict with labeled segments."""
    print()

    if mic_wav and sys_wav and os.path.exists(mic_wav) and os.path.exists(sys_wav):
        # ── Two sources: transcribe separately, interleave with speaker labels ──
        print("  \033[93m⟳\033[0m Transcribing mic (Ja)...")
        mic_result = _transcribe_wav(mic_wav, config)

        print("  \033[93m⟳\033[0m Transcribing system audio (Rozmówca)...")
        sys_result = _transcribe_wav(sys_wav, config)

        # Merge segments with speaker labels
        all_segments = []
        for seg in mic_result.get("segments", []):
            text = seg["text"].strip()
            if text and not is_hallucination(text):
                all_segments.append({"start": seg["start"], "end": seg["end"], "text": text, "speaker": "Ja"})

        for seg in sys_result.get("segments", []):
            text = seg["text"].strip()
            if text and not is_hallucination(text):
                all_segments.append({"start": seg["start"], "end": seg["end"], "text": text, "speaker": "Rozmówca"})

        all_segments.sort(key=lambda s: s["start"])

        lang = mic_result.get("language", sys_result.get("language", "?"))
        print(f"\n  Language: \033[1m{lang}\033[0m")
        print()

        for seg in all_segments:
            ts = fmt_timestamp(seg["start"])
            speaker = seg["speaker"]
            print(f"  \033[90m{ts}\033[0m \033[1m({speaker})\033[0m {seg['text']}")

        # Clean up separate WAVs
        os.remove(mic_wav)
        os.remove(sys_wav)

        print()
        return {"language": lang, "segments": all_segments}

    else:
        # ── Single source: transcribe merged/mic only ──
        print("  \033[93m⟳\033[0m Final transcription (whisper-large-v3-turbo)...")
        result = _transcribe_wav(wav_path, config)

        lang = result.get("language", "?")
        print(f"\n  Language: \033[1m{lang}\033[0m")
        print()

        for seg in result.get("segments", []):
            ts = fmt_timestamp(seg["start"])
            text = seg["text"].strip()
            if text:
                print(f"  \033[90m{ts}\033[0m {text}")

        if not result.get("segments") and result.get("text"):
            print(f"  {result['text'].strip()}")

        print()
        return result


# ─── Save to Obsidian ────────────────────────────────────────────────────────


def save_to_obsidian(wav_path: str, result: dict, title: str, duration: float, config: dict) -> str:
    """Generate markdown and save next to WAV. Returns md path."""
    lang = result.get("language", "unknown")
    segments = result.get("segments", [])
    date_str = datetime.now().strftime("%Y-%m-%d")
    model_short = config["model"].split("/")[-1]

    vault_path = Path(config["vault_path"])
    meetings_dir = vault_path / config["meetings_dir"]
    meetings_dir.mkdir(parents=True, exist_ok=True)
    audio_dir = vault_path / "attachments" / "meetings"
    audio_dir.mkdir(parents=True, exist_ok=True)

    start_time = os.path.getmtime(wav_path)
    time_str = datetime.fromtimestamp(start_time).strftime("%H.%M")
    final_name = f"{date_str} {time_str} - {title}"
    final_wav = str(audio_dir / f"{final_name}.wav")

    if wav_path != final_wav:
        os.rename(wav_path, final_wav)

    audio_filename = f"attachments/meetings/{final_name}.wav"

    lines = [
        "---",
        "type: meeting_transcript",
        f"date: {date_str}",
        f'title: "{title}"',
        f"language: {lang}",
        f'source: "meeting-recorder"',
        f'duration: "{fmt_duration(duration)}"',
        f'model: "{model_short}"',
        f'audio: "[[{audio_filename}]]"',
        "---",
        "",
        f"# {title} — Transcript",
        "",
    ]

    for seg in segments:
        ts = fmt_timestamp(seg["start"])
        text = seg.get("text", "").strip() if isinstance(seg, dict) else ""
        speaker = seg.get("speaker", "") if isinstance(seg, dict) else ""
        if text:
            if speaker:
                lines.append(f"{ts} **({speaker})** {text}")
            else:
                lines.append(f"{ts} {text}")
            lines.append("")

    if not segments and result.get("text"):
        lines.append(result["text"].strip())
        lines.append("")

    md_path = str(meetings_dir / f"{final_name}.md")
    with open(md_path, "w") as f:
        f.write("\n".join(lines))

    return md_path


# ─── Main ────────────────────────────────────────────────────────────────────


def main():
    config = load_config()

    # Parse optional args
    title = None
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg in ("--pl", "-pl"):
            config["language"] = "pl"
        elif arg in ("--en", "-en"):
            config["language"] = "en"
        elif arg == "--auto":
            config["language"] = None
        elif arg == "--no-system":
            config["capture_system_audio"] = False
        elif not arg.startswith("-"):
            title = " ".join(sys.argv[i:])
            break

    print()
    print("  \033[1m🎙 Meeting Recorder\033[0m")
    lang_display = config.get("language") or "auto-detect"
    sys_display = "mic + system" if config.get("capture_system_audio", True) else "mic only"
    print(f"  Language: {lang_display} | Audio: {sys_display}")

    # Record with live transcription
    wav_path, mic_wav, sys_wav, duration = record_with_live_transcription(config)

    # Ask for title
    if not title:
        print()
        title = input("  Meeting title: ").strip() or "Meeting"

    # Final transcription with speaker labels
    result = transcribe_final(wav_path, mic_wav, sys_wav, config)

    # Save
    md_path = save_to_obsidian(wav_path, result, title, duration, config)

    print(f"  \033[92m✓\033[0m Saved to Obsidian: {Path(md_path).name}")

    if config.get("open_in_obsidian", True):
        from urllib.parse import quote
        vault_name = Path(config["vault_path"]).name
        meetings_dir = config["meetings_dir"]
        note_name = Path(md_path).stem
        uri = f"obsidian://open?vault={quote(vault_name)}&file={quote(f'{meetings_dir}/{note_name}')}"
        subprocess.run(["open", uri], check=False)
        print(f"  \033[92m✓\033[0m Opened in Obsidian")

    print()


if __name__ == "__main__":
    main()
