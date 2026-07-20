#!/usr/bin/env python3
"""One-off: transcribe an existing wav using echopad's own engine + Obsidian saver.

Usage: transcribe_file.py <wav_path> [title...]
Skips diarization (lecture/system-audio = single speaker).
"""
import sys
import soundfile as sf

from echopad import (
    load_config,
    transcribe_quiet,
    filter_repeated_segments,
    filter_fillers,
    save_to_obsidian,
    fmt_timestamp,
)


def main():
    if len(sys.argv) < 2:
        print("usage: transcribe_file.py <wav> [title...]", file=sys.stderr)
        sys.exit(1)

    wav_path = sys.argv[1]
    title = " ".join(sys.argv[2:]) or "Meeting"
    config = load_config()
    config["diarization"] = False  # single-speaker lecture, skip

    info = sf.info(wav_path)
    duration = info.frames / info.samplerate
    print(f"  Transcribing {wav_path} ({duration:.0f}s) ...", flush=True)

    result = transcribe_quiet(wav_path, config)
    segments = result.get("segments", [])
    segments = filter_repeated_segments(segments)
    segments = filter_fillers(segments)

    print(f"  {len(segments)} segments. Detected lang: {result.get('language')}\n")
    for seg in segments[:8]:
        print(f"    {fmt_timestamp(seg['start'])} {seg['text']}")
    if len(segments) > 8:
        print("    ...")

    md_path = save_to_obsidian(wav_path, segments, title, duration, config)
    if md_path:
        print(f"\n  Saved: {md_path}")


if __name__ == "__main__":
    main()
