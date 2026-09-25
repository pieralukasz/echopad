"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/cn";

export type PillState = "recording" | "transcribing" | "saved";

/** How long each state lasts in the looping demo, in milliseconds. */
const CYCLE: { state: PillState | "hidden"; duration: number }[] = [
  { state: "recording", duration: 4200 },
  { state: "transcribing", duration: 1800 },
  { state: "saved", duration: 1600 },
  { state: "hidden", duration: 700 },
];

/** Padding, dot, timer and stop button, plus 6px for every waveform bar. */
function width(state: PillState, bars: number) {
  if (state === "transcribing") return 172;
  if (state === "saved") return 128;
  return 150 + bars * 6;
}

const LABEL: Record<PillState, string> = {
  recording: "EchoPad is recording, with a timer and a live waveform",
  transcribing: "EchoPad is transcribing the recording",
  saved: "EchoPad has saved the transcript",
};

/**
 * The recording pill rebuilt in HTML, so it can move on the page: timer and
 * waveform while recording, then "Transcribing", then "Saved". Pass `state`
 * for one fixed state, or leave it out to loop.
 */
export function LivePill({
  state,
  bars = 28,
  className,
}: {
  state?: PillState;
  /** Waveform bars while recording; the pill is as wide as they need. */
  bars?: number;
  className?: string;
}) {
  const cycling = useCycle(state === undefined);
  const current = state ?? (cycling === "hidden" ? "saved" : cycling);
  const hidden = state === undefined && cycling === "hidden";
  const seconds = useTimer(current === "recording" && state === undefined);

  return (
    <div
      role="img"
      aria-label={LABEL[current]}
      className={cn("echo-pill", hidden && "echo-pill-hidden", className)}
      style={{ width: width(current, bars), height: 48 }}
    >
      <Layer active={current === "recording"} spread>
        <span className="flex items-center gap-2.5">
          <span className="echo-pill-dot" />
          <span className="echo-pill-time">
            {state === undefined ? clock(seconds) : "12:48"}
          </span>
        </span>
        <span className="flex h-5 items-center gap-[3px]">
          {Array.from({ length: bars }, (_, index) => (
            <span
              // biome-ignore lint/suspicious/noArrayIndexKey: bars never reorder
              key={index}
              className="echo-pill-bar"
              style={barStyle(index)}
            />
          ))}
        </span>
        <span className="echo-pill-stop" />
      </Layer>
      <Layer active={current === "transcribing"}>
        <span className="flex items-center gap-1.5">
          {[0, 1, 2].map((dot) => (
            <span
              key={dot}
              className="echo-pill-thinking"
              style={{ animationDelay: `${dot * 160}ms` }}
            />
          ))}
        </span>
        <span className="echo-pill-label">Transcribing</span>
      </Layer>
      <Layer active={current === "saved"}>
        <svg
          viewBox="0 0 24 24"
          className="size-5 text-fd-primary"
          fill="none"
          aria-hidden="true"
        >
          <path
            key={current === "saved" ? "drawn" : "idle"}
            className={cn("echo-pill-check", state && "echo-pill-check-static")}
            d="M5 12.5l4.5 4.5L19 7.5"
            stroke="currentColor"
            strokeWidth="3"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
        <span className="echo-pill-label">Saved</span>
      </Layer>
    </div>
  );
}

function Layer({
  active,
  spread = false,
  children,
}: {
  active: boolean;
  spread?: boolean;
  children: React.ReactNode;
}) {
  return (
    <span
      aria-hidden="true"
      className={cn(
        "absolute inset-0 flex items-center gap-2.5 transition-[opacity,transform] duration-300",
        spread ? "justify-between pr-2 pl-4" : "justify-center px-4",
        active
          ? "opacity-100 scale-100"
          : "pointer-events-none opacity-0 scale-75",
      )}
    >
      {children}
    </span>
  );
}

function clock(seconds: number) {
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, "0")}`;
}

/** A speech-like spread of heights and speeds, the same on server and client. */
function barStyle(index: number) {
  const envelope =
    0.35 +
    0.65 * Math.abs(Math.sin(index * 0.55) * Math.sin(index * 0.21 + 0.6));
  return {
    height: `${Math.round(6 + envelope * 14)}px`,
    animationDuration: `${620 + ((index * 137) % 420)}ms`,
    animationDelay: `${-((index * 89) % 700)}ms`,
  };
}

/** Counts up from 12:44 while recording, like a call that is already going. */
function useTimer(running: boolean) {
  const [seconds, setSeconds] = useState(12 * 60 + 44);
  useEffect(() => {
    if (!running) return;
    const timer = window.setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => window.clearInterval(timer);
  }, [running]);
  return seconds;
}

/** Steps through CYCLE forever, unless the reader prefers reduced motion. */
function useCycle(enabled: boolean) {
  const [step, setStep] = useState(0);

  useEffect(() => {
    if (!enabled) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timer = window.setTimeout(
      () => setStep((current) => (current + 1) % CYCLE.length),
      CYCLE[step].duration,
    );
    return () => window.clearTimeout(timer);
  }, [enabled, step]);

  return CYCLE[step].state;
}

/**
 * A small desktop for the pill to sit on: the looping demo near the bottom,
 * as on a real screen, and each state below it with its caption.
 */
export function PillStage() {
  return (
    <div className="not-prose my-6 space-y-4">
      <div className="echo-desk relative flex h-56 items-end justify-center overflow-hidden rounded-2xl border pb-7">
        <LivePill />
      </div>
      <div className="grid gap-4 sm:grid-cols-3">
        {(
          [
            ["recording", "Recording: timer, waveform, stop"],
            ["transcribing", "Transcribing on your Mac"],
            ["saved", "Saved to your folder"],
          ] as const
        ).map(([state, caption]) => (
          <figure
            key={state}
            className="echo-desk flex flex-col items-center gap-3 overflow-hidden rounded-2xl border px-4 pt-8 pb-4"
          >
            <LivePill state={state} bars={6} />
            <figcaption className="text-sm text-fd-muted-foreground">
              {caption}
            </figcaption>
          </figure>
        ))}
      </div>
    </div>
  );
}
