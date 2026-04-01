"""Speaker diarization for echopad using pyannote.audio."""

import sys

import numpy as np


def diarize(wav_path: str, token: str | None = None, device: str = "mps") -> list[tuple[str, float, float]]:
    """Run speaker diarization on a WAV file.

    Returns list of (speaker_label, start_seconds, end_seconds).
    """
    import torch
    from pyannote.audio import Pipeline

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=token,
    )

    try:
        pipeline.to(torch.device(device))
    except Exception as e:
        print(f"  \033[93m!\033[0m Could not use {device}: {e}. Falling back to CPU.",
              file=sys.stderr)
        pipeline.to(torch.device("cpu"))

    result = pipeline(wav_path)

    # pyannote 4.x returns DiarizeOutput; extract the Annotation
    diarization = getattr(result, "speaker_diarization", result)

    turns = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        turns.append((speaker, turn.start, turn.end))
    return turns


def assign_speakers(
    segments: list[dict],
    turns: list[tuple[str, float, float]],
    username: str | None = None,
    mic_wav: str | None = None,
) -> list[dict]:
    """Map diarization speaker labels to transcription segments.

    Each segment gets a 'speaker' key assigned based on which diarization
    speaker has the most temporal overlap with that segment.

    If username and mic_wav are provided, tries to identify which diarization
    speaker is the local user by correlating with mic audio energy.
    """
    if not turns:
        return segments

    # Compute estimated end times without mutating segment dicts
    ends = []
    for i, seg in enumerate(segments):
        if i + 1 < len(segments):
            ends.append(min(segments[i + 1]["start"], seg["start"] + 30.0))
        else:
            ends.append(seg["start"] + 5.0)

    # Assign speaker with maximum overlap to each segment
    for i, seg in enumerate(segments):
        seg_start = seg["start"]
        seg_end = ends[i]
        best_speaker = None
        best_overlap = 0.0

        for speaker, turn_start, turn_end in turns:
            overlap_start = max(seg_start, turn_start)
            overlap_end = min(seg_end, turn_end)
            overlap = max(0.0, overlap_end - overlap_start)
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = speaker

        if best_speaker:
            seg["speaker"] = best_speaker

    # Try to identify local user via mic energy correlation
    if username and mic_wav:
        _identify_local_user(segments, turns, username, mic_wav)

    # Rename anonymous labels to friendly names
    _rename_speakers(segments, username)

    return segments


def _identify_local_user(
    segments: list[dict],
    turns: list[tuple[str, float, float]],
    username: str,
    mic_wav: str,
):
    """Identify which diarization speaker corresponds to the local user
    by checking which speaker's segments overlap with mic audio energy."""
    try:
        import soundfile as sf
        audio, sr = sf.read(mic_wav, dtype="int16")
        audio = audio.flatten()
    except ImportError:
        print("  \033[90m  Speaker identification skipped: soundfile not installed\033[0m",
              file=sys.stderr)
        return
    except Exception as e:
        print(f"  \033[93m!\033[0m Could not identify local speaker: {e}",
              file=sys.stderr)
        return

    # Compute RMS energy in 1-second windows
    window = sr
    n_windows = len(audio) // window
    if n_windows == 0:
        return
    energy = np.array([
        np.sqrt(np.mean(audio[i * window:(i + 1) * window].astype(np.float32) ** 2))
        for i in range(n_windows)
    ])
    threshold = np.percentile(energy, 60)
    mic_active_seconds = {i for i in range(n_windows) if energy[i] > threshold}

    if not mic_active_seconds:
        return

    # Score each speaker: how much do their turns overlap with mic-active seconds?
    speaker_scores: dict[str, int] = {}
    for speaker, turn_start, turn_end in turns:
        overlap = 0
        for sec in range(int(turn_start), int(turn_end) + 1):
            if sec in mic_active_seconds:
                overlap += 1
        speaker_scores[speaker] = speaker_scores.get(speaker, 0) + overlap

    if speaker_scores:
        local_speaker = max(speaker_scores, key=speaker_scores.get)
        for seg in segments:
            if seg.get("speaker") == local_speaker:
                seg["speaker"] = username


def _rename_speakers(segments: list[dict], username: str | None):
    """Rename SPEAKER_00/01/... to Speaker 1, Speaker 2, ... (skip the local user)."""
    seen: dict[str, str] = {}
    counter = 1

    for seg in segments:
        speaker = seg.get("speaker", "")
        if not speaker or speaker == username:
            continue
        if speaker not in seen:
            seen[speaker] = f"Speaker {counter}"
            counter += 1
        seg["speaker"] = seen[speaker]
