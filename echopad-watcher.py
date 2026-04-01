#!/usr/bin/env python3
"""echopad-watcher — auto-start echopad when a meeting is detected.

Event-driven: listens for microphone activation via mic-monitor (CoreAudio),
then runs AppleScript detectors to identify the meeting app. Zero CPU when idle.
"""

import logging
import os
import signal
import subprocess
import sys
import threading
import time

# ─── Config ──────────────────────────────────────────────────────────────────

COOLDOWN_SECONDS = 30
MEETING_CHECK_INTERVAL = 30  # seconds between meeting-still-active checks during recording
TRANSCRIPTION_RATIO = 0.3
TRANSCRIPTION_MIN   = 300
TRANSCRIPTION_MAX   = 7200
SAFETY_POLL_INTERVAL = 60  # low-frequency fallback poll (seconds)

PROJECT_DIR = os.path.expanduser("~/Projects/echopad")
MIC_MONITOR_BIN = os.path.join(PROJECT_DIR, "mic-monitor")
ECHOPAD_CMD = ["/opt/homebrew/bin/python3", os.path.join(PROJECT_DIR, "echopad.py")]
LOG_PATH = os.path.expanduser("~/Library/Logs/echopad-watcher.log")
PID_FILE = os.path.join(PROJECT_DIR, ".echopad-watcher.pid")

# ─── Logging ─────────────────────────────────────────────────────────────────

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("echopad-watcher")


# ─── Title Detection ─────────────────────────────────────────────────────────

def _run_applescript(script: str) -> str:
    try:
        r = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=10,
        )
        return r.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def get_meeting_title() -> str:
    """Try to extract a useful title from the frontmost app/window/tab."""
    # Try Brave Browser active tab title
    title = _run_applescript('''
tell application "System Events"
    if not (exists process "Brave Browser") then return ""
end tell
tell application "Brave Browser"
    try
        return title of active tab of front window
    end try
end tell
return ""
''')
    if title:
        # Clean up common patterns
        for prefix in ["Meet - ", "Meet – "]:
            if prefix in title:
                return title.split(prefix, 1)[1].strip()
        return title

    # Try Slack window name
    title = _run_applescript('''
tell application "System Events"
    if not (exists process "Slack") then return ""
    tell process "Slack"
        try
            return name of front window
        end try
    end tell
end tell
return ""
''')
    if title:
        return title

    # Try frontmost app window name as fallback
    title = _run_applescript('''
tell application "System Events"
    try
        set frontApp to first application process whose frontmost is true
        return name of front window of frontApp
    end try
end tell
return ""
''')
    if title:
        return title

    return "Meeting"


def get_active_tab_url() -> str:
    """Get the URL of the active Brave Browser tab."""
    return _run_applescript('''
tell application "System Events"
    if not (exists process "Brave Browser") then return ""
end tell
tell application "Brave Browser"
    try
        return URL of active tab of front window
    end try
end tell
return ""
''')


def is_tab_still_open(url: str) -> bool:
    """Check if a tab with the given URL (or domain) is still open in Brave."""
    if not url:
        return False
    # Extract domain for fuzzy matching
    import re
    m = re.search(r'https?://([^/]+)', url)
    domain = m.group(1) if m else url
    result = _run_applescript(f'''
tell application "System Events"
    if not (exists process "Brave Browser") then return "no"
end tell
tell application "Brave Browser"
    repeat with w in every window
        repeat with t in every tab of w
            if URL of t contains "{domain}" then return "yes"
        end repeat
    end repeat
end tell
return "no"
''')
    return result == "yes"


def is_meeting_still_active() -> bool:
    """Check if a meeting/call app is still running (browser with audio, Slack, etc.)."""
    # Check Brave for audio-playing tabs (speaker icon) or known meeting URLs
    result = _run_applescript('''
tell application "System Events"
    if not (exists process "Brave Browser") then return "no"
end tell
tell application "Brave Browser"
    repeat with w in every window
        repeat with t in every tab of w
            set tabURL to URL of t
            if tabURL contains "meet.google.com" or tabURL contains "/live/" or tabURL contains "zoom.us" or tabURL contains "teams.microsoft.com" then
                return "yes"
            end if
        end repeat
    end repeat
end tell
return "no"
''')
    if result == "yes":
        return True

    # Check if Slack huddle is active
    result = _run_applescript('''
tell application "System Events"
    if not (exists process "Slack") then return "no"
    tell process "Slack"
        set windowNames to name of every window
        repeat with wn in windowNames
            if wn contains "Huddle" then return "yes"
        end repeat
    end tell
end tell
return "no"
''')
    if result == "yes":
        return True

    return False


# ─── Notifications ───────────────────────────────────────────────────────────

def notify(title: str, message: str, sound: str = "default"):
    subprocess.Popen(
        ["osascript", "-e",
         f'display notification "{message}" with title "{title}" sound name "{sound}"'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


# ─── Process Management ─────────────────────────────────────────────────────

def is_echopad_running() -> bool:
    try:
        r = subprocess.run(["pgrep", "-f", "echopad.py"], capture_output=True, text=True)
        our_pid = str(os.getpid())
        pids = [p.strip() for p in r.stdout.strip().split("\n") if p.strip() and p.strip() != our_pid]
        return len(pids) > 0
    except Exception:
        return False


def start_echopad(title: str) -> subprocess.Popen | None:
    try:
        log_file = open(LOG_PATH, "a")
        proc = subprocess.Popen(
            ECHOPAD_CMD + ["--daemon", title],
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=log_file,
        )
        log_file.close()  # Popen inherited the fd
        log.info("Started echopad (PID %d) with title: %s", proc.pid, title)
        return proc
    except Exception as e:
        log.error("Failed to start echopad: %s", e)
        notify("echopad", f"Failed to start: {e}")
        return None


def stop_echopad(proc: subprocess.Popen, recording_secs: float = 0):
    if proc is None or proc.poll() is not None:
        return
    timeout = int(max(TRANSCRIPTION_MIN,
                      min(TRANSCRIPTION_MAX, recording_secs * TRANSCRIPTION_RATIO + 120)))
    log.info("Stopping echopad (PID %d), transcription timeout %ds...", proc.pid, timeout)
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=timeout)
        log.info("echopad stopped gracefully")
    except subprocess.TimeoutExpired:
        log.warning("echopad did not stop in %ds, killing", timeout)
        proc.kill()
        proc.wait()


# ─── PID File ────────────────────────────────────────────────────────────────

def write_pid_file():
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))


def remove_pid_file():
    try:
        os.remove(PID_FILE)
    except FileNotFoundError:
        pass


# ─── Main Loop (Event-Driven) ───────────────────────────────────────────────

def main():
    write_pid_file()
    log.info("echopad-watcher started (PID %d), event-driven mode", os.getpid())

    if not os.path.exists(MIC_MONITOR_BIN):
        log.error("mic-monitor binary not found at %s", MIC_MONITOR_BIN)
        print(f"Error: mic-monitor not found. Compile it first:\n"
              f"  swiftc -O -o mic-monitor mic-monitor.swift -framework CoreAudio -framework AudioToolbox",
              file=sys.stderr)
        remove_pid_file()
        sys.exit(1)

    state = "IDLE"
    echopad_proc = None
    cooldown_until = 0.0
    recording_start = 0.0
    recording_tab_url = ""  # URL of the tab that triggered recording

    def handle_shutdown(signum, frame):
        log.info("Received signal %d, shutting down", signum)
        if echopad_proc and echopad_proc.poll() is None:
            echopad_proc.send_signal(signal.SIGTERM)
            log.info("Sent SIGTERM to echopad (PID %d), letting it finish independently", echopad_proc.pid)
        remove_pid_file()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_shutdown)
    signal.signal(signal.SIGINT, handle_shutdown)

    # Launch mic-monitor
    mic_proc = subprocess.Popen(
        [MIC_MONITOR_BIN],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
    log.info("mic-monitor started (PID %d)", mic_proc.pid)

    def on_mic_on():
        nonlocal state, echopad_proc, recording_start, cooldown_until, recording_tab_url

        if state == "RECORDING":
            return  # Already recording, mic just unmuted

        if time.time() < cooldown_until:
            log.debug("Mic on during cooldown, ignoring")
            return

        if is_echopad_running():
            log.info("Mic on but echopad already running")
            return

        # Mic activated — try to get a useful title from frontmost app
        title = get_meeting_title()
        recording_tab_url = get_active_tab_url()
        log.info("Mic activated, starting recording: %s (URL: %s)", title, recording_tab_url)

        echopad_proc = start_echopad(title)
        if echopad_proc:
            notify("echopad", f"Recording: {title}")
            state = "RECORDING"
            recording_start = time.time()
            log.info("State -> RECORDING (%s)", title)

    def on_mic_off():
        if state != "RECORDING":
            return
        # Ignore MIC_OFF during recording — echopad holds the mic open,
        # so MIC_OFF only fires when echopad itself stops (not useful).
        # Meeting-end detection is done by the meeting_checker thread.

    # Periodically check if the meeting is still active during recording
    def meeting_checker():
        nonlocal state, echopad_proc, cooldown_until, recording_start
        inactive_streak = 0
        while True:
            time.sleep(MEETING_CHECK_INTERVAL)

            # Check for echopad crash
            if state == "RECORDING" and echopad_proc and echopad_proc.poll() is not None:
                exit_code = echopad_proc.returncode
                log.warning("echopad exited unexpectedly (code %d)", exit_code)
                echopad_proc = None
                state = "IDLE"
                inactive_streak = 0
                # If meeting is still active, restart recording immediately
                if is_meeting_still_active() or is_tab_still_open(recording_tab_url):
                    log.info("Meeting still active after crash, restarting recording")
                    on_mic_on()
                else:
                    cooldown_until = time.time() + COOLDOWN_SECONDS
                    log.info("State -> IDLE (echopad crashed, cooldown %ds)", COOLDOWN_SECONDS)
                continue

            # Check if meeting is still active (require 2 consecutive checks)
            # Use both generic meeting detection AND tracked tab URL
            if state == "RECORDING":
                meeting_active = is_meeting_still_active() or is_tab_still_open(recording_tab_url)
                if not meeting_active:
                    inactive_streak += 1
                    log.info("Meeting inactive check %d/2 (tab URL: %s)", inactive_streak, recording_tab_url)
                    if inactive_streak >= 2:
                        recording_duration = time.time() - recording_start
                        log.info("Meeting confirmed inactive, stopping recording after %.0fs", recording_duration)
                        notify("echopad", "Meeting ended. Transcribing...")
                        stop_echopad(echopad_proc, recording_duration)
                        notify("echopad", "Transcript saved to Obsidian.")
                        echopad_proc = None
                        state = "IDLE"
                        inactive_streak = 0
                        cooldown_until = time.time() + COOLDOWN_SECONDS
                        log.info("State -> IDLE (meeting ended, cooldown %ds)", COOLDOWN_SECONDS)
                else:
                    if inactive_streak > 0:
                        log.info("Meeting active again, resetting inactive streak")
                    inactive_streak = 0

    checker_thread = threading.Thread(target=meeting_checker, daemon=True)
    checker_thread.start()

    # Main event loop — read from mic-monitor stdout
    try:
        for line in mic_proc.stdout:
            event = line.strip()
            if event == "MIC_ON":
                on_mic_on()
            elif event == "MIC_OFF":
                on_mic_off()
            # Ignore other output

    except Exception as e:
        log.error("Fatal error: %s", e, exc_info=True)
        if echopad_proc and echopad_proc.poll() is None:
            echopad_proc.send_signal(signal.SIGTERM)
            log.info("Sent SIGTERM to echopad on fatal error")
    finally:
        # Clean up mic-monitor
        if mic_proc.poll() is None:
            mic_proc.kill()
            mic_proc.wait()
        remove_pid_file()


if __name__ == "__main__":
    main()
