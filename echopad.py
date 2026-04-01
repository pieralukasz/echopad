#!/usr/bin/env python3
"""echopad — record a meeting with live transcription, save to Obsidian."""

import io
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

# ─── Config ──────────────────────────────────────────────────────────────────

PROJECT_DIR = Path.home() / "Projects" / "echopad"
CONFIG_PATH = PROJECT_DIR / "config.json"
AUDIO_CAPTURE_BIN = PROJECT_DIR / "audio-capture"
WHISPER_STREAM_BIN = "/opt/homebrew/bin/whisper-stream"
STREAM_MODEL = Path.home() / ".config/open-wispr/models/ggml-medium.bin"
USERNAME = os.environ.get("USER", "user")

DEFAULT_CONFIG = {
    "vault_path": "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Life",
    "meetings_dir": "Meetings",
    "model": "mlx-community/whisper-large-v3-turbo",
    "sample_rate": 16000,
    "language": None,
    "open_in_obsidian": True,
    "capture_system_audio": True,
    "diarization": True,
    "diarization_device": "mps",
    "hf_token": None,
}

HALLUCINATION_PATTERNS = {
    "thank you", "thanks for watching", "subscribe", "like and subscribe",
    "thank you for watching", "see you next time", "bye", "goodbye",
    "blank_audio", "blank audio", "typing", "keyboard",
    "wrong", "gracias", "продолжение следует", "sous-titrage",
    "sous-titres", "amara.org", "silencio", "music", "applause",
    "laughter", "you", "the end", "to be continued",
}


def is_repetition(text: str) -> bool:
    """Detect repeated word/phrase hallucinations like 'Wrong Wrong Wrong...'."""
    words = text.strip().split()
    if len(words) < 4:
        return False
    first = words[0].lower()
    return all(w.lower() == first for w in words)


def load_config():
    config = DEFAULT_CONFIG.copy()
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH) as f:
                config.update(json.load(f))
        except json.JSONDecodeError as e:
            print(f"  \033[93m!\033[0m Invalid config.json: {e}. Using defaults.", file=sys.stderr)
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
    return re.sub(r"\x1b\[[0-9;]*[a-zA-Z]|\x1b\[2K", "", text)


FILLER_WORDS = {"yeah", "yes", "yep", "yup", "okay", "ok", "mhm", "hmm", "uh",
                "um", "right", "sure", "great", "cool", "alright", "ah", "oh"}


def is_hallucination(text: str) -> bool:
    clean = text.strip().lower().strip("[]() .")
    return any(h in clean for h in HALLUCINATION_PATTERNS) or len(clean) < 2


def is_filler(text: str) -> bool:
    words = set(text.strip().lower().strip(".,!?").split())
    return bool(words) and len(words) <= 2 and words.issubset(FILLER_WORDS)


def filter_repeated_segments(segments: list[dict]) -> list[dict]:
    """Remove segments whose text appears 3+ times total (hallucination on silence)."""
    if not segments:
        return segments
    counts = Counter(seg["text"].strip().lower() for seg in segments)
    return [seg for seg in segments if counts[seg["text"].strip().lower()] < 3]


def filter_fillers(segments: list[dict]) -> list[dict]:
    """Remove runs of 3+ consecutive filler-only segments from the same speaker."""
    if not segments:
        return segments

    result = []
    filler_run = []

    def flush_run():
        if len(filler_run) < 3:
            result.extend(filler_run)
        # else: drop the entire run (3+ consecutive fillers)

    for seg in segments:
        if is_filler(seg["text"]):
            if filler_run and filler_run[-1].get("speaker") != seg.get("speaker"):
                flush_run()
                filler_run = []
            filler_run.append(seg)
        else:
            flush_run()
            filler_run = []
            result.append(seg)

    flush_run()
    return result


def _kill_proc(proc):
    """Safely kill a subprocess."""
    if proc and proc.poll() is None:
        proc.kill()
        proc.wait()


def transcribe_quiet(audio, config: dict) -> dict:
    """Transcribe with mlx-whisper, suppressing progress output.
    audio: file path (str) or numpy float32 array."""
    import mlx_whisper

    kwargs = {"path_or_hf_repo": config["model"], "verbose": False}
    if config.get("language"):
        kwargs["language"] = config["language"]

    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    try:
        return mlx_whisper.transcribe(audio, **kwargs)
    finally:
        sys.stdout = old_stdout


# ─── Chunked Transcriber ───────────────────────────────────────────────────

CHUNK_SECONDS = 30
CHUNK_SAMPLES = CHUNK_SECONDS * 16000  # 480000 samples at 16kHz


class ChunkedTranscriber:
    """Transcribes audio chunks in a background thread during recording."""

    def __init__(self, config: dict):
        self.config = config
        self._segments: list[dict] = []
        self._lock = threading.Lock()
        self._done = threading.Event()
        self._queue: queue.Queue = queue.Queue()
        self._chunks_done = 0
        self._finished = False

    def submit(self, audio_float32: np.ndarray, offset_seconds: float):
        if self._finished:
            return
        self._queue.put((audio_float32, offset_seconds))

    def finish(self):
        if self._finished:
            return
        self._finished = True
        self._queue.put(None)

    @property
    def pending(self) -> int:
        return self._queue.qsize()

    def run(self):
        """Process chunks until finish() is called. Run in a background thread."""
        try:
            while True:
                item = self._queue.get()
                if item is None:
                    break
                audio, offset = item
                try:
                    result = transcribe_quiet(audio, self.config)
                except Exception as e:
                    print(f"\n  \033[93m!\033[0m Chunk at {offset:.0f}s failed: {e}",
                          file=sys.stderr, flush=True)
                    with self._lock:
                        self._chunks_done += 1
                    continue
                with self._lock:
                    for seg in result.get("segments", []):
                        text = seg["text"].strip()
                        if text and not is_hallucination(text) and not is_repetition(text):
                            self._segments.append({
                                "start": seg["start"] + offset,
                                "text": text,
                            })
                    self._chunks_done += 1
        except Exception as e:
            print(f"\n  \033[91m!\033[0m Transcription thread crashed: {e}",
                  file=sys.stderr, flush=True)
        finally:
            self._done.set()

    def wait(self, timeout=None):
        return self._done.wait(timeout=timeout)

    def get_segments(self) -> list[dict]:
        with self._lock:
            return sorted(
                [dict(s) for s in self._segments],
                key=lambda s: s["start"],
            )

    @property
    def chunks_done(self) -> int:
        with self._lock:
            return self._chunks_done


# ─── Record ──────────────────────────────────────────────────────────────────


def record(config: dict, daemon_mode: bool = False):
    """Record mic + system audio, whisper-stream live preview, chunked transcription.
    Returns (final_wav, mic_wav, sys_wav, duration, transcriber)."""
    if daemon_mode:
        subprocess.run(["osascript", "-e", "set volume input volume 75"],
                       capture_output=True)

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

    # ── Mic ──
    mic_chunks = []
    mic_lock = threading.Lock()

    def audio_callback(indata, frames, time_info, status):
        if status:
            print(f"\n  \033[93m!\033[0m Audio: {status}\033[K", file=sys.stderr, flush=True)
        with mic_lock:
            mic_chunks.append(indata.copy())

    try:
        mic_stream = sd.InputStream(samplerate=sample_rate, channels=1, dtype="int16", callback=audio_callback)
    except sd.PortAudioError as e:
        print(f"\n  \033[91mError:\033[0m Cannot open microphone: {e}", file=sys.stderr)
        print("  Check System Settings > Privacy & Security > Microphone.", file=sys.stderr)
        sys.exit(1)

    # ── System audio (with --pipe for real-time PCM streaming) ──
    sys_proc = None
    sys_buffer = bytearray()
    sys_buf_lock = threading.Lock()

    if capture_system:
        if not AUDIO_CAPTURE_BIN.exists():
            print(f"  \033[93m!\033[0m audio-capture binary not found at {AUDIO_CAPTURE_BIN}. Skipping system audio.", file=sys.stderr)
            capture_system = False
        else:
            sys_proc = subprocess.Popen(
                [str(AUDIO_CAPTURE_BIN), "--output", sys_wav, "--sample-rate", str(sample_rate),
                 "--no-mic", "--pipe"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            time.sleep(0.5)
            if sys_proc.poll() is not None:
                stderr_out = ""
                try:
                    stderr_out = sys_proc.stderr.read().decode(errors="replace").strip()
                except Exception:
                    pass
                msg = "audio-capture crashed on start"
                if stderr_out:
                    msg += f": {stderr_out}"
                print(f"  \033[93m!\033[0m {msg}. Recording mic only.", file=sys.stderr)
                sys_proc = None
                capture_system = False

    # ── Thread: read system audio PCM from pipe ──
    def read_sys_pipe(proc):
        try:
            while True:
                data = proc.stdout.read(8192)
                if not data:
                    break
                with sys_buf_lock:
                    sys_buffer.extend(data)
        except (IOError, ValueError, AttributeError):
            pass

    if sys_proc:
        threading.Thread(target=read_sys_pipe, args=(sys_proc,), daemon=True).start()

    # ── Chunked transcriber ──
    transcriber = ChunkedTranscriber(config)
    threading.Thread(target=transcriber.run, daemon=True).start()

    # ── whisper-stream (live preview, skipped in daemon mode) ──
    lang = config.get("language") or "auto"
    whisper_proc = None
    if not daemon_mode and Path(WHISPER_STREAM_BIN).exists() and STREAM_MODEL.exists():
        try:
            whisper_proc = subprocess.Popen(
                [WHISPER_STREAM_BIN, "-m", str(STREAM_MODEL), "-l", lang,
                 "--step", "3000", "--length", "10000", "--keep", "200", "--vad-thold", "0.6"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                text=True, bufsize=1,
            )
            time.sleep(0.5)
            if whisper_proc.poll() is not None:
                print(f"  \033[93m!\033[0m whisper-stream crashed. Live preview disabled.", file=sys.stderr)
                whisper_proc = None
        except FileNotFoundError:
            whisper_proc = None
    elif not daemon_mode:
        if not Path(WHISPER_STREAM_BIN).exists():
            print(f"  \033[93m!\033[0m whisper-stream not found. Install: brew install whisper-cpp", file=sys.stderr)
        if not STREAM_MODEL.exists():
            print(f"  \033[93m!\033[0m Stream model not found at {STREAM_MODEL}", file=sys.stderr)

    mic_stream.start()
    start = time.time()
    stop = False
    last_text = ""
    chunk_index = 0
    mic_chunk_cursor = 0  # index into mic_chunks for chunked transcription

    def handle_term(signum, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, handle_term)

    print()
    sources = "mic + system" if capture_system else "mic"
    live_status = "live preview on" if whisper_proc else "live preview off"
    print(f"  \033[91m●\033[0m REC ({sources})  Press \033[1mEnter\033[0m to stop")
    print(f"  \033[90m  {live_status} — transcribing in real-time with large-v3-turbo\033[0m")
    print()

    # ── Thread: read whisper-stream ──
    def read_stream():
        nonlocal last_text
        try:
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
        except (IOError, UnicodeDecodeError):
            if not stop:
                print(f"\n  \033[93m!\033[0m Live preview stopped unexpectedly\033[K", flush=True)

    if whisper_proc:
        threading.Thread(target=read_stream, daemon=True).start()

    def wait_for_enter():
        nonlocal stop
        try:
            input()
        except EOFError:
            return
        stop = True
    threading.Thread(target=wait_for_enter, daemon=True).start()

    # ── Helper: extract and mix a chunk for transcription ──
    def submit_chunk():
        nonlocal chunk_index, mic_chunk_cursor
        chunk_offset = chunk_index * CHUNK_SECONDS
        try:
            # Get new mic audio since last chunk (avoids re-concatenating full history)
            with mic_lock:
                new_mic_chunks = mic_chunks[mic_chunk_cursor:]
                mic_chunk_cursor = len(mic_chunks)
            if new_mic_chunks:
                mic_slice = np.concatenate(new_mic_chunks).flatten()
            else:
                mic_slice = np.array([], dtype=np.int16)

            # Get sys audio for this chunk
            with sys_buf_lock:
                sys_bytes = bytes(sys_buffer)
                sys_buffer.clear()
            # Ensure even byte count for int16
            if len(sys_bytes) % 2 != 0:
                sys_bytes = sys_bytes[:len(sys_bytes) - 1]
            if sys_bytes:
                sys_slice = np.frombuffer(sys_bytes, dtype=np.int16)
            else:
                sys_slice = np.array([], dtype=np.int16)

            # Mix: pad shorter to match longer, then add
            max_len = max(len(mic_slice), len(sys_slice))
            if max_len == 0:
                chunk_index += 1
                return

            mic_padded = np.zeros(max_len, dtype=np.int32)
            sys_padded = np.zeros(max_len, dtype=np.int32)
            if len(mic_slice) > 0:
                mic_padded[:len(mic_slice)] = mic_slice.astype(np.int32)
            if len(sys_slice) > 0:
                sys_padded[:len(sys_slice)] = sys_slice.astype(np.int32)

            mixed = np.clip(mic_padded + sys_padded, -32768, 32767).astype(np.int16)
            audio_f32 = mixed.astype(np.float32) / 32768.0

            transcriber.submit(audio_f32, chunk_offset)
        except Exception as e:
            print(f"\n  \033[93m!\033[0m Failed to process chunk {chunk_index}: {e}\033[K",
                  file=sys.stderr, flush=True)
        chunk_index += 1

    try:
        last_chunk_time = time.time()
        while not stop:
            time.sleep(0.5)
            # Submit a chunk every CHUNK_SECONDS
            if time.time() - last_chunk_time >= CHUNK_SECONDS:
                submit_chunk()
                last_chunk_time = time.time()
            # Monitor system audio process
            if sys_proc and sys_proc.poll() is not None and not stop:
                stderr_out = ""
                try:
                    stderr_out = sys_proc.stderr.read().decode(errors="replace").strip()
                except Exception:
                    pass
                msg = "System audio capture stopped unexpectedly"
                if stderr_out:
                    msg += f": {stderr_out}"
                print(f"\n  \033[93m!\033[0m {msg}\033[K", flush=True)
                sys_proc = None
    except KeyboardInterrupt:
        stop = True

    duration = time.time() - start

    # ── Stop ──
    # Use abort() instead of stop() — stop() can deadlock in PortAudio
    try:
        mic_stream.abort()
        mic_stream.close()
    except Exception:
        pass

    if whisper_proc:
        whisper_proc.kill()
        try:
            whisper_proc.stdout.close()
        except OSError:
            pass
        whisper_proc.wait()

    if sys_proc:
        sys_proc.send_signal(signal.SIGINT)
        try:
            sys_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            sys_proc.kill()
            sys_proc.wait()
        # Give the reader thread a moment to drain the remaining pipe bytes
        time.sleep(0.2)

    # Submit final remaining audio chunk
    submit_chunk()
    transcriber.finish()

    print(f"\n\n  \033[92m■\033[0m Stopped after {fmt_elapsed(int(duration))}")

    # ── Save mic WAV ──
    if mic_chunks:
        audio_data = np.concatenate(mic_chunks)
    else:
        audio_data = np.array([], dtype=np.int16)
        print("  \033[93m!\033[0m No mic audio recorded", file=sys.stderr)
    sf.write(mic_wav, audio_data, sample_rate)

    has_sys = capture_system and os.path.exists(sys_wav) and os.path.getsize(sys_wav) > 44

    # ── Merge for archival ──
    if has_sys:
        print("  \033[93m⟳\033[0m Mixing audio...")
        try:
            r = subprocess.run(
                ["ffmpeg", "-y", "-i", mic_wav, "-i", sys_wav,
                 "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest[out]",
                 "-map", "[out]", "-ar", str(sample_rate), "-ac", "1", final_wav],
                capture_output=True,
            )
            if r.returncode != 0:
                print(f"  \033[93m!\033[0m ffmpeg merge failed. Keeping separate mic/system files.", file=sys.stderr)
                shutil.move(mic_wav, final_wav)
                has_sys = False
        except FileNotFoundError:
            print(f"  \033[93m!\033[0m ffmpeg not found. Install: brew install ffmpeg", file=sys.stderr)
            shutil.move(mic_wav, final_wav)
            has_sys = False
    else:
        shutil.move(mic_wav, final_wav)

    return final_wav, mic_wav if has_sys else None, sys_wav if has_sys else None, duration, transcriber


# ─── Save to Obsidian ────────────────────────────────────────────────────────


def save_to_obsidian(wav_path: str, segments: list[dict], title: str, duration: float, config: dict) -> str:
    vault_path = Path(config["vault_path"])
    meetings_dir = vault_path / config["meetings_dir"]
    meetings_dir.mkdir(parents=True, exist_ok=True)

    date_str = datetime.now().strftime("%Y-%m-%d")
    start_time = os.path.getmtime(wav_path)
    time_str = datetime.fromtimestamp(start_time).strftime("%H.%M")
    safe_title = re.sub(r'[/:*?"<>|\\]', '-', title.replace('\n', ' ').replace('\r', ''))[:120]
    final_name = f"{date_str} {time_str} - {safe_title}"

    audio_dir = vault_path / "attachments" / "meetings"
    final_wav = str(audio_dir / f"{final_name}.wav")
    if wav_path != final_wav:
        shutil.move(wav_path, final_wav)

    audio_filename = f"attachments/meetings/{final_name}.wav"
    lang = config.get("language") or "auto"

    lines = [
        "---",
        "type: meeting_transcript",
        f"date: {date_str}",
        f'title: "{title}"',
        f"language: {lang}",
        f'source: "echopad"',
        f'duration: "{fmt_duration(duration)}"',
        f'audio: "[[{audio_filename}]]"',
        "---",
        "",
        f"# {title} — Transcript",
        "",
    ]

    for seg in segments:
        ts = fmt_timestamp(seg["start"])
        speaker = seg.get("speaker", "")
        if speaker:
            lines.append(f"{ts} **({speaker})** {seg['text']}")
        else:
            lines.append(f"{ts} {seg['text']}")
        lines.append("")

    md_path = str(meetings_dir / f"{final_name}.md")
    try:
        with open(md_path, "w") as f:
            f.write("\n".join(lines))
    except OSError as e:
        print(f"  \033[91m!\033[0m Failed to write transcript: {e}", file=sys.stderr)
        print("\n  --- Transcript ---")
        for line in lines:
            print(f"  {line}")
        return ""

    return md_path


# ─── Main ────────────────────────────────────────────────────────────────────


def main():
    config = load_config()

    title = None
    daemon_mode = False
    for i, arg in enumerate(sys.argv[1:], 1):
        if arg in ("--pl", "-pl"):
            config["language"] = "pl"
        elif arg in ("--en", "-en"):
            config["language"] = "en"
        elif arg == "--auto":
            config["language"] = None
        elif arg == "--no-system":
            config["capture_system_audio"] = False
        elif arg == "--daemon":
            daemon_mode = True
        elif not arg.startswith("-"):
            title = " ".join(sys.argv[i:])
            break

    print()
    print("  \033[1m🎙 echopad\033[0m")
    lang_display = config.get("language") or "auto-detect"
    sys_display = "mic + system" if config.get("capture_system_audio", True) else "mic only"
    print(f"  Language: {lang_display} | Audio: {sys_display}")

    wav_path, mic_wav, sys_wav, duration, transcriber = record(config, daemon_mode)

    if not title:
        if daemon_mode:
            title = "Meeting"
        else:
            print()
            title = input("  Meeting title: ").strip() or "Meeting"

    # Wait for chunked transcription to finish (last chunk + queue drain)
    pending = transcriber.pending
    if pending > 0:
        print(f"  \033[93m⟳\033[0m Finishing transcription ({pending} chunk{'s' if pending != 1 else ''} remaining)...")
    if not transcriber.wait(timeout=300):
        print("  \033[93m!\033[0m Transcription timed out — transcript may be incomplete.", file=sys.stderr)
    segments = transcriber.get_segments()

    # Speaker diarization (optional — requires pyannote.audio + HF token)
    if config.get("diarization", True) and segments:
        token = config.get("hf_token")
        if not token:
            print("  \033[90m  Diarization skipped: set hf_token in config.json"
                  " (see https://hf.co/pyannote/speaker-diarization-3.1)\033[0m", file=sys.stderr)
        else:
            try:
                from diarize import assign_speakers, diarize as run_diarize

                device = config.get("diarization_device", "mps")
                print(f"  \033[93m⟳\033[0m Identifying speakers...")
                turns = run_diarize(wav_path, token=token, device=device)
                segments = assign_speakers(segments, turns, username=USERNAME, mic_wav=mic_wav)
            except ImportError:
                print("  \033[90m  Diarization skipped (pyannote.audio not installed)\033[0m", file=sys.stderr)
            except Exception as e:
                print(f"  \033[93m!\033[0m Diarization failed ({type(e).__name__}): {e}", file=sys.stderr)

    # Filter filler sequences
    segments = filter_repeated_segments(segments)
    segments = filter_fillers(segments)

    # Clean up separate mic/sys files
    for tmp in (mic_wav, sys_wav):
        if tmp and os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass

    print()
    for seg in segments:
        ts = fmt_timestamp(seg["start"])
        speaker = seg.get("speaker", "")
        if speaker:
            print(f"  \033[90m{ts}\033[0m \033[1m({speaker})\033[0m {seg['text']}")
        else:
            print(f"  \033[90m{ts}\033[0m {seg['text']}")

    md_path = save_to_obsidian(wav_path, segments, title, duration, config)

    if md_path:
        print(f"\n  \033[92m✓\033[0m Saved to Obsidian: {Path(md_path).name}")

        if daemon_mode:
            subprocess.Popen(
                ["osascript", "-e",
                 'display notification "Transcript saved to Obsidian" with title "echopad"'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

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
