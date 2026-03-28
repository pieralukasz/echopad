#!/usr/bin/env python3
"""Meeting Recorder — menu bar app for recording meetings and transcribing to Obsidian."""

import json
import os
import signal
import subprocess
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path

import rumps

# ─── Config ──────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent
CONFIG_PATH = SCRIPT_DIR / "config.json"
AUDIO_CAPTURE_BIN = SCRIPT_DIR / "audio-capture"

DEFAULT_CONFIG = {
    "vault_path": "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Life",
    "meetings_dir": "Meetings",
    "model": "mlx-community/whisper-large-v3-turbo",
    "include_mic": True,
    "sample_rate": 16000,
    "language": None,
    "open_in_obsidian": True,
}


def load_config():
    config = DEFAULT_CONFIG.copy()
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            config.update(json.load(f))
    config["vault_path"] = os.path.expanduser(config["vault_path"])
    return config


# ─── Transcription ───────────────────────────────────────────────────────────


def transcribe(audio_path: str, model: str, language: str | None = None):
    """Run mlx-whisper transcription. Returns dict with 'text', 'segments', 'language'."""
    import mlx_whisper

    kwargs = {
        "path_or_hf_repo": model,
        "word_timestamps": False,
        "verbose": False,
    }
    if language:
        kwargs["language"] = language

    return mlx_whisper.transcribe(audio_path, **kwargs)


def format_timestamp(seconds: float) -> str:
    """Format seconds as [MM:SS] or [HH:MM:SS] for long meetings."""
    td = timedelta(seconds=int(seconds))
    total_seconds = int(td.total_seconds())
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    secs = total_seconds % 60
    if hours > 0:
        return f"[{hours}:{minutes:02d}:{secs:02d}]"
    return f"[{minutes:02d}:{secs:02d}]"


def format_duration(seconds: float) -> str:
    """Format total duration as HH:MM:SS."""
    total = int(seconds)
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    return f"{h:02d}:{m:02d}:{s:02d}"


def format_elapsed(seconds: int) -> str:
    """Format elapsed time for menu bar display."""
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def generate_markdown(result: dict, title: str, date: str, duration: float, audio_filename: str, model: str) -> str:
    """Generate Obsidian markdown from transcription result."""
    lang = result.get("language", "unknown")
    segments = result.get("segments", [])

    lines = [
        "---",
        "type: meeting_transcript",
        f"date: {date}",
        f'title: "{title}"',
        f"language: {lang}",
        f'source: "meeting-recorder"',
        f'duration: "{format_duration(duration)}"',
        f'model: "{model.split("/")[-1]}"',
        f'audio: "[[{audio_filename}]]"',
        "---",
        "",
        f"# {title} — Transcript",
        "",
    ]

    for seg in segments:
        ts = format_timestamp(seg["start"])
        text = seg["text"].strip()
        if text:
            lines.append(f"{ts} {text}")
            lines.append("")

    # If no segments but we have full text
    if not segments and result.get("text"):
        lines.append(result["text"].strip())
        lines.append("")

    return "\n".join(lines)


# ─── App ─────────────────────────────────────────────────────────────────────


class MeetingRecorder(rumps.App):
    def __init__(self):
        super().__init__("Meeting Recorder", title="🎙 Ready")

        self.config = load_config()
        self.recording = False
        self.transcribing = False
        self.capture_process = None
        self.audio_path = None
        self.start_time = None
        self._timer = None

        # Language submenu
        self.lang_auto = rumps.MenuItem("Auto (detect)", callback=self.set_lang_auto)
        self.lang_pl = rumps.MenuItem("Polski", callback=self.set_lang_pl)
        self.lang_en = rumps.MenuItem("English", callback=self.set_lang_en)
        self._update_lang_checks()

        lang_menu = rumps.MenuItem("Language")
        lang_menu.update([self.lang_auto, self.lang_pl, self.lang_en])

        self.record_button = rumps.MenuItem("Start Recording", callback=self.toggle_recording, key="r")

        self.menu = [
            self.record_button,
            None,
            lang_menu,
        ]

    def _update_lang_checks(self):
        lang = self.config.get("language")
        self.lang_auto.state = 1 if lang is None else 0
        self.lang_pl.state = 1 if lang == "pl" else 0
        self.lang_en.state = 1 if lang == "en" else 0

    def set_lang_auto(self, _):
        self.config["language"] = None
        self._update_lang_checks()

    def set_lang_pl(self, _):
        self.config["language"] = "pl"
        self._update_lang_checks()

    def set_lang_en(self, _):
        self.config["language"] = "en"
        self._update_lang_checks()

    def toggle_recording(self, sender):
        if not self.recording:
            self.start_recording()
        else:
            self.stop_recording()

    def _update_title(self, _=None):
        """Update menu bar title with elapsed time."""
        if not self.recording:
            if self._timer:
                self._timer.stop()
                self._timer = None
            return
        elapsed = int(time.time() - self.start_time)
        self.title = f"🔴 REC {format_elapsed(elapsed)}"

    def start_recording(self):
        meetings_dir = Path(self.config["vault_path"]) / self.config["meetings_dir"]
        meetings_dir.mkdir(parents=True, exist_ok=True)

        timestamp = datetime.now().strftime("%Y-%m-%d %H.%M")
        temp_name = f"{timestamp} - Meeting"
        self.audio_path = str(meetings_dir / f"{temp_name}.wav")

        cmd = [str(AUDIO_CAPTURE_BIN), "--output", self.audio_path, "--sample-rate", str(self.config["sample_rate"])]
        if not self.config.get("include_mic", True):
            cmd.append("--no-mic")

        self.capture_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.start_time = time.time()
        self.recording = True

        self.title = "🔴 REC 00:00"
        self.record_button.title = "⏹ Stop Recording"

        # Start timer to update elapsed time in menu bar
        self._timer = rumps.Timer(self._update_title, 1)
        self._timer.start()

        rumps.notification(
            title="Meeting Recorder",
            subtitle="Recording started",
            message="Click 'Stop Recording' when done.",
        )

    def stop_recording(self):
        if not self.recording or not self.capture_process:
            return

        self.recording = False
        duration = time.time() - self.start_time

        if self._timer:
            self._timer.stop()
            self._timer = None

        # Send SIGINT to the Swift capture process
        self.capture_process.send_signal(signal.SIGINT)
        try:
            self.capture_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.capture_process.terminate()
            self.capture_process.wait(timeout=3)

        self.title = "🎙 Stopped"
        self.record_button.title = "▶ Start Recording"

        rumps.notification(
            title="Meeting Recorder",
            subtitle="Recording stopped",
            message=f"Duration: {format_duration(duration)}. Enter title...",
        )

        # Ask for meeting title
        response = rumps.Window(
            message="Enter a title for this meeting:",
            title="Meeting Title",
            default_text="Meeting",
            ok="Save",
            cancel="Cancel",
            dimensions=(320, 24),
        ).run()

        meeting_title = response.text.strip() if response.clicked else "Meeting"
        if not meeting_title:
            meeting_title = "Meeting"

        # Rename audio file with the title
        meetings_dir = Path(self.config["vault_path"]) / self.config["meetings_dir"]
        date_str = datetime.now().strftime("%Y-%m-%d")
        time_str = datetime.fromtimestamp(self.start_time).strftime("%H.%M")
        final_name = f"{date_str} {time_str} - {meeting_title}"
        final_audio = str(meetings_dir / f"{final_name}.wav")

        if self.audio_path != final_audio:
            os.rename(self.audio_path, final_audio)
            self.audio_path = final_audio

        # Transcribe in background
        self.transcribing = True
        self.title = "🎙 Transcribing..."
        threading.Thread(
            target=self._transcribe_and_save,
            args=(self.audio_path, meeting_title, date_str, duration, f"{final_name}.wav"),
            daemon=True,
        ).start()

    def _transcribe_and_save(self, audio_path, title, date_str, duration, audio_filename):
        try:
            result = transcribe(
                audio_path,
                model=self.config["model"],
                language=self.config.get("language"),
            )

            markdown = generate_markdown(result, title, date_str, duration, audio_filename, self.config["model"])

            # Save markdown next to audio file
            md_path = audio_path.rsplit(".", 1)[0] + ".md"
            with open(md_path, "w") as f:
                f.write(markdown)

            detected_lang = result.get("language", "?")
            rumps.notification(
                title="Meeting Recorder",
                subtitle="Transcription complete",
                message=f"Language: {detected_lang}. Saved to Obsidian.",
            )

            # Open in Obsidian
            if self.config.get("open_in_obsidian", True):
                vault_name = Path(self.config["vault_path"]).name
                meetings_dir = self.config["meetings_dir"]
                note_name = Path(md_path).stem
                from urllib.parse import quote
                file_path = quote(f"{meetings_dir}/{note_name}")
                vault_encoded = quote(vault_name)
                uri = f"obsidian://open?vault={vault_encoded}&file={file_path}"
                subprocess.run(["open", uri], check=False)

        except Exception as e:
            rumps.notification(
                title="Meeting Recorder",
                subtitle="Transcription failed",
                message=str(e)[:100],
            )
            import traceback
            traceback.print_exc()
        finally:
            self.transcribing = False
            self.title = "🎙 Ready"


if __name__ == "__main__":
    MeetingRecorder().run()
