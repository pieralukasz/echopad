import {
  AudioLines,
  Bell,
  Cpu,
  FileText,
  FolderOpen,
  Heart,
  Lock,
  Package,
  Users,
} from "lucide-react";
import Link from "next/link";
import type { ReactNode } from "react";
import { LivePill } from "@/components/live-pill";
import { Screenshot } from "@/components/screenshot";
import { asset, authorUrl, repoUrl } from "@/lib/shared";

const steps = [
  {
    icon: Bell,
    title: "Join a call",
    text: "EchoPad notices Zoom, Meet, Teams and friends using the microphone and offers to record.",
  },
  {
    icon: AudioLines,
    title: "Talk as usual",
    text: "Your microphone and the other side are recorded as two tracks. A glass pill shows the timer.",
  },
  {
    icon: FileText,
    title: "Get a transcript",
    text: "Stop, and a transcript with speakers lands in your folder, in the formats you chose.",
  },
];

const features = [
  {
    icon: Cpu,
    title: "Parakeet v3, on-device",
    text: "NVIDIA’s TDT model runs on Apple’s Neural Engine through FluidAudio. 25 European languages, fully offline after one download.",
  },
  {
    icon: Users,
    title: "Knows who said what",
    text: "Your side comes from the microphone, so it is always you. The other side is split into speakers you can rename.",
  },
  {
    icon: FolderOpen,
    title: "Saves where you work",
    text: "An Obsidian vault, a client folder, iCloud Drive. Each save location has its own folder, file name and formats.",
  },
  {
    icon: FileText,
    title: "Markdown, text, subtitles",
    text: "Markdown with front matter, plain text, SRT, WebVTT and JSON. Audio as AAC or WAV, next to the note or on its own.",
  },
  {
    icon: Bell,
    title: "Never miss a meeting",
    text: "A notification with a Record button appears when a call starts. Or press ⇧⌘E, or click the menu bar icon.",
  },
  {
    icon: Heart,
    title: "Free, for real",
    text: "No account, no subscription, no minute limit. MIT licensed, like the two Swift packages it is built on.",
  },
];

const privacyFacts = [
  "Audio is recorded only while you record, into a folder on your Mac.",
  "Transcription and speaker detection run locally on the Neural Engine.",
  "The only network requests download the models from Hugging Face, once.",
  "No analytics, no crash reporting, no account. Check the source to be sure.",
];

const packages = [
  {
    name: "ScribeKit",
    url: "/docs/packages#scribekit",
    text: "Parakeet v3 transcription with speakers in a few lines of Swift, plus Markdown, SRT, WebVTT and JSON output.",
  },
  {
    name: "SystemAudioKit",
    url: "/docs/packages#systemaudiokit",
    text: "Record the microphone and what the Mac plays, as two aligned tracks, through Core Audio process taps.",
  },
];

const comparison = [
  ["Price", "Free forever", "Monthly subscription"],
  ["Where audio is processed", "On your Mac", "Remote servers"],
  ["Bot joins the call", "No", "Often"],
  ["Where transcripts go", "Any folder you pick", "Their web app"],
  ["Source code", "Open, MIT", "Closed"],
];

export default function HomePage() {
  return (
    <main className="flex flex-col">
      <Hero />
      <Section eyebrow="How it works" title="From call to notes without typing">
        <div className="grid gap-4 md:grid-cols-3">
          {steps.map((step, index) => (
            <div key={step.title} className="rounded-2xl border bg-fd-card p-6">
              <div className="mb-4 flex items-center gap-3">
                <span className="flex size-10 items-center justify-center rounded-xl bg-fd-primary/15 text-fd-primary">
                  <step.icon className="size-5" />
                </span>
                <span className="text-sm font-medium text-fd-muted-foreground">
                  Step {index + 1}
                </span>
              </div>
              <h3 className="text-lg font-semibold">{step.title}</h3>
              <p className="mt-1 text-fd-muted-foreground">{step.text}</p>
            </div>
          ))}
        </div>
      </Section>

      <Section
        eyebrow="Features"
        title="A meeting recorder that stays out of the way"
      >
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {features.map((feature) => (
            <div
              key={feature.title}
              className="rounded-2xl border bg-fd-card p-6"
            >
              <feature.icon className="mb-4 size-6 text-fd-primary" />
              <h3 className="font-semibold">{feature.title}</h3>
              <p className="mt-1 text-sm text-fd-muted-foreground">
                {feature.text}
              </p>
            </div>
          ))}
        </div>
      </Section>

      <Section
        eyebrow="A look inside"
        title="Conversations, save locations and settings in one window"
      >
        <div className="grid gap-6 lg:grid-cols-2">
          <Screenshot
            name="destinations"
            alt="Save location editor with folder, file name, formats and audio options"
            caption="Save locations with a live preview of the path"
          />
          <Screenshot
            name="settings-recording"
            alt="Recording settings: microphone, system audio, meeting detection"
            caption="What to record, and when to ask"
          />
        </div>
      </Section>

      <Section eyebrow="Privacy" title="What leaves your Mac? Nothing.">
        <div className="grid gap-6 lg:grid-cols-2">
          <ul className="flex flex-col justify-between gap-5 rounded-2xl border bg-fd-card p-6">
            {privacyFacts.map((line) => (
              <li key={line} className="flex gap-3">
                <Lock className="mt-0.5 size-5 shrink-0 text-fd-primary" />
                <span>{line}</span>
              </li>
            ))}
          </ul>
          <div className="overflow-hidden rounded-2xl border bg-fd-card">
            <table className="h-full w-full table-fixed text-sm">
              <thead className="bg-fd-muted">
                <tr>
                  <th className="w-[38%] px-5 py-3.5 text-left font-medium" />
                  <th className="px-5 py-3.5 text-left font-semibold text-fd-primary">
                    EchoPad
                  </th>
                  <th className="px-5 py-3.5 text-left font-medium text-fd-muted-foreground">
                    Typical meeting note-taker
                  </th>
                </tr>
              </thead>
              <tbody>
                {comparison.map(([label, ours, cloud]) => (
                  <tr key={label} className="border-t">
                    <td className="px-5 py-3.5 text-fd-muted-foreground">
                      {label}
                    </td>
                    <td className="px-5 py-3.5 font-medium">{ours}</td>
                    <td className="px-5 py-3.5 text-fd-muted-foreground">
                      {cloud}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </Section>

      <Section eyebrow="Open source" title="Two Swift packages you can use too">
        <div className="grid gap-4 md:grid-cols-2">
          {packages.map((item) => (
            <a
              key={item.name}
              href={item.url}
              className="group rounded-2xl border bg-fd-card p-6 transition hover:border-fd-primary/50"
            >
              <Package className="mb-4 size-6 text-fd-primary" />
              <h3 className="font-semibold group-hover:text-fd-primary">
                {item.name}
              </h3>
              <p className="mt-1 text-sm text-fd-muted-foreground">
                {item.text}
              </p>
            </a>
          ))}
        </div>
      </Section>

      <section className="mx-auto w-full max-w-5xl px-6 pb-24">
        <div className="echo-glow rounded-3xl border bg-fd-card px-8 py-14 text-center">
          <h2 className="text-3xl font-bold tracking-tight">
            Keep every conversation
          </h2>
          <p className="mx-auto mt-3 max-w-xl text-fd-muted-foreground">
            Build it from source in one command. Setup walks you through
            permissions, the model download and where to save.
          </p>
          <CallToAction className="mt-8 justify-center" />
        </div>
      </section>

      <footer className="border-t py-10 text-center text-sm text-fd-muted-foreground">
        <p>
          Made by{" "}
          <a
            className="font-medium text-fd-foreground underline underline-offset-4"
            href={authorUrl}
          >
            Lucas Piera
          </a>
          .
        </p>
        <p className="mt-2">
          MIT licensed. Built on{" "}
          <a
            className="underline"
            href="https://github.com/FluidInference/FluidAudio"
          >
            FluidAudio
          </a>{" "}
          and NVIDIA Parakeet, through{" "}
          <Link className="underline" href="/docs/packages">
            ScribeKit and SystemAudioKit
          </Link>
          .
        </p>
      </footer>
    </main>
  );
}

function Hero() {
  return (
    <section className="echo-glow relative overflow-hidden">
      <div className="mx-auto flex max-w-5xl flex-col items-center px-6 pt-20 pb-12 text-center">
        {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
        <img
          src={asset("/icon-256.png")}
          alt="EchoPad icon"
          width={96}
          height={96}
          className="mb-6 drop-shadow-xl"
        />
        <span className="mb-5 rounded-full border bg-fd-card px-3 py-1 text-xs font-medium text-fd-muted-foreground">
          Free · Open source · Runs on your Mac
        </span>
        <h1 className="text-5xl font-bold tracking-tight sm:text-6xl">
          Every call, <span className="text-fd-primary">on paper.</span>
        </h1>
        <p className="mt-5 max-w-2xl text-lg text-fd-muted-foreground">
          EchoPad records your calls and meetings, tells the speakers apart and
          saves the transcript where you keep your notes. No bot in the call, no
          cloud, no subscription.
        </p>
        <CallToAction className="mt-8 justify-center" />
      </div>
      <div className="relative mx-auto max-w-5xl px-6 pb-20">
        <Screenshot
          name="conversations"
          alt="EchoPad main window with a transcript split by speaker"
          className="my-0"
        />
        <div className="absolute inset-x-0 bottom-8 flex justify-center">
          <LivePill />
        </div>
      </div>
    </section>
  );
}

function CallToAction({ className }: { className?: string }) {
  return (
    <div className={`flex flex-wrap gap-3 ${className ?? ""}`}>
      <Link
        href="/docs/installation"
        className="rounded-full bg-fd-primary px-6 py-3 font-medium text-fd-primary-foreground transition hover:opacity-90"
      >
        Install EchoPad
      </Link>
      <a
        href={repoUrl}
        className="inline-flex items-center gap-2 rounded-full border bg-fd-card px-6 py-3 font-medium transition hover:bg-fd-accent"
      >
        <GitHubMark /> View on GitHub
      </a>
    </div>
  );
}

function Section({
  eyebrow,
  title,
  children,
}: {
  eyebrow: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="mx-auto w-full max-w-5xl px-6 py-16">
      <p className="text-sm font-semibold uppercase tracking-wider text-fd-primary">
        {eyebrow}
      </p>
      <h2 className="mt-2 mb-8 text-3xl font-bold tracking-tight">{title}</h2>
      {children}
    </section>
  );
}

function GitHubMark() {
  return (
    <svg
      viewBox="0 0 16 16"
      className="size-4"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}
