"use client";

import { useEffect, useState } from "react";
import { LivePill } from "@/components/live-pill";
import { cn } from "@/lib/cn";
import { asset } from "@/lib/shared";
import { call, formats } from "./sample-call";

/**
 * Marks the page as scripted and plays each [data-reveal] group once as it
 * enters. Without script nothing is hidden.
 */
export function Reveal() {
  useEffect(() => {
    const root = document.documentElement;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    root.classList.add("ep-js");
    const groups = document.querySelectorAll<HTMLElement>("[data-reveal]");
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          entry.target.classList.add("is-in");
          observer.unobserve(entry.target);
        }
      },
      { rootMargin: "0px 0px -8% 0px" },
    );
    for (const group of groups) {
      Array.from(group.children).forEach((child, index) => {
        (child as HTMLElement).style.setProperty("--i", String(index));
      });
      observer.observe(group);
    }
    return () => {
      observer.disconnect();
      root.classList.remove("ep-js");
    };
  }, []);
  return null;
}

const STAGE_SHOTS = [
  {
    name: "conversations",
    alt: "The EchoPad window: a Zoom call titled Weekly product sync, its transcript split between Lukasz, Anna and Marek",
  },
  {
    name: "settings-transcription",
    alt: "Transcription settings: Parakeet TDT 0.6B v3 with pyannote, status Ready, runs on the Apple Neural Engine, fully offline",
  },
  {
    name: "settings-recording",
    alt: "Recording settings: your microphone on one track, everything this Mac plays on the other, captured with Core Audio",
  },
];

/**
 * The half of the first screens that never moves: the real app on the brand
 * blue, changing to the screen that matches the text beside it.
 */
export function StickyStage() {
  const [active, setActive] = useState(0);

  useEffect(() => {
    const blocks = document.querySelectorAll<HTMLElement>("[data-stage]");
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting)
            setActive(Number(entry.target.getAttribute("data-stage")));
        }
      },
      { rootMargin: "-45% 0px -45% 0px" },
    );
    for (const block of blocks) observer.observe(block);
    return () => observer.disconnect();
  }, []);

  return (
    <div className="ep-stage" data-ui>
      {STAGE_SHOTS.map((shot, index) => (
        // biome-ignore lint/performance/noImgElement: static export serves plain files
        <img
          key={shot.name}
          src={asset(`/screenshots/${shot.name}.png`)}
          alt={index === active ? shot.alt : ""}
          aria-hidden={index === active ? undefined : true}
          width={2154}
          height={1280}
          className={cn("ep-stage-shot", index === active && "is-on")}
          loading={index === 0 ? "eager" : "lazy"}
        />
      ))}
      <div className="ep-stage-pill">
        <LivePill bars={22} />
      </div>
    </div>
  );
}

const STEPS = [
  {
    name: "Call",
    clause: "First, a call starts",
    text: "Zoom, Teams, Google Meet in a browser, Slack, FaceTime, Webex, Discord, WhatsApp, Signal or Telegram takes the microphone, and EchoPad offers to record. It never starts on its own.",
  },
  {
    name: "Record",
    clause: "Then the pill keeps time",
    text: "Your microphone and the sound of the call go on two tracks. Stop from the pill, the menu bar or with ⇧⌘E.",
  },
  {
    name: "Transcribe",
    clause: "Then your Mac writes it",
    text: "Parakeet TDT v3 transcribes on the Neural Engine and tells the other speakers apart. Your track is always you.",
  },
  {
    name: "Save",
    clause: "Finally, the note is filed",
    text: "The transcript lands in your folder, named by your template, in every format you ticked.",
  },
];

/** How it works: one slider drives the clause and the app's own state. */
export function StageSlider() {
  const [step, setStep] = useState(0);
  const current = STEPS[step];

  return (
    <section className="ep-steps" aria-labelledby="ep-steps-title">
      <div className="ep-steps-clause">
        <div key={current.name} className="ep-fade">
          <h2 id="ep-steps-title" className="ep-display">
            {current.clause}
          </h2>
          <p className="ep-steps-text">{current.text}</p>
        </div>
      </div>
      <div className="ep-steps-fragment">
        <div key={current.name} className="ep-fade">
          <StepFragment step={step} />
        </div>
      </div>
      <div className="ep-steps-control">
        <input
          type="range"
          min={0}
          max={STEPS.length - 1}
          step={1}
          value={step}
          onChange={(event) => setStep(Number(event.target.value))}
          aria-label="Stage of a recording"
          aria-valuetext={current.name}
          className="ep-range"
          style={
            {
              "--fill": `${(step / (STEPS.length - 1)) * 100}%`,
            } as React.CSSProperties
          }
        />
        <ol className="ep-steps-names">
          {STEPS.map((item, index) => (
            <li key={item.name}>
              <button
                type="button"
                onClick={() => setStep(index)}
                className={cn(index === step && "is-on")}
                aria-pressed={index === step}
              >
                {item.name}
              </button>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}

function StepFragment({ step }: { step: number }) {
  if (step === 0) {
    return (
      <div className="ep-note" data-ui>
        {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
        <img src={asset("/icon-256.png")} alt="" width={40} height={40} />
        <div className="ep-note-body">
          <p className="ep-note-app">EchoPad</p>
          <p className="ep-note-title">Zoom is using the microphone</p>
          <p className="ep-note-text">
            Record and transcribe this conversation with EchoPad?
          </p>
        </div>
        <span className="ep-note-action">Record</span>
      </div>
    );
  }
  if (step === 3) {
    return (
      <div className="ep-saved" data-ui>
        <LivePill state="saved" />
        <div className="ep-finder">
          <p className="ep-finder-path">{call.folder}</p>
          <p className="ep-finder-file is-on">{call.fileBase}.md</p>
          <p className="ep-finder-file">{call.fileBase}.srt</p>
        </div>
      </div>
    );
  }
  return (
    <div data-ui className="ep-pill-holder">
      <LivePill state={step === 1 ? "recording" : "transcribing"} bars={24} />
    </div>
  );
}

/** The live sheet: the same call as each file EchoPad can write. */
export function FormatSheet() {
  const [index, setIndex] = useState(0);
  const format = formats[index];

  return (
    <section className="ep-files" aria-labelledby="ep-files-title">
      <div className="ep-files-index">
        <h2 id="ep-files-title" className="ep-visually-hidden">
          One call, five files
        </h2>
        <p className="ep-files-intro">
          One call, five files. Pick a format to see the file EchoPad writes for
          it.
        </p>
        <div className="ep-files-names" role="tablist" aria-label="File format">
          {formats.map((item, i) => (
            <button
              key={item.id}
              type="button"
              role="tab"
              id={`ep-tab-${item.id}`}
              aria-selected={i === index}
              aria-controls="ep-sheet"
              className={cn(i === index && "is-on")}
              onClick={() => setIndex(i)}
            >
              {item.name}
            </button>
          ))}
        </div>
      </div>
      <div className="ep-files-stage">
        <div
          id="ep-sheet"
          role="tabpanel"
          aria-labelledby={`ep-tab-${format.id}`}
          key={format.id}
          className={cn(
            "ep-sheet ep-fade",
            format.id === "srt" || format.id === "vtt" ? "is-narrow" : "",
          )}
          data-ui
        >
          <p className="ep-sheet-name">
            {call.fileBase}.{format.id}
          </p>
          <pre>
            <code>{format.render()}</code>
          </pre>
        </div>
      </div>
    </section>
  );
}

const INSTALL =
  "git clone https://github.com/pieralukasz/echopad.git\ncd echopad\nscripts/install.sh";

/** The first step, already open in a Terminal window. */
export function InstallTerminal() {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(INSTALL);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div className="ep-term" data-ui>
      <div className="ep-term-bar">
        <span />
        <span />
        <span />
        <p>Terminal</p>
      </div>
      <pre>
        <code>
          <span className="ep-term-prompt">~ % </span>git clone
          https://github.com/pieralukasz/echopad.git
          {"\n"}
          <span className="ep-term-prompt">~ % </span>cd echopad
          {"\n"}
          <span className="ep-term-prompt">echopad % </span>scripts/install.sh
        </code>
      </pre>
      <button type="button" className="ep-term-copy" onClick={copy}>
        {copied ? "Copied" : "Copy the three lines"}
      </button>
    </div>
  );
}
