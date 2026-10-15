import Link from "next/link";
import {
  FormatSheet,
  InstallTerminal,
  Reveal,
  StageSlider,
  StickyStage,
} from "@/components/home/interactive";
import { asset, authorUrl, repoUrl } from "@/lib/shared";

/** Parakeet TDT 0.6B v3, as listed on /docs/languages, with the code saved in the front matter. */
const languages: [string, string][] = [
  ["Bulgarian", "bg"],
  ["Croatian", "hr"],
  ["Czech", "cs"],
  ["Danish", "da"],
  ["Dutch", "nl"],
  ["English", "en"],
  ["Estonian", "et"],
  ["Finnish", "fi"],
  ["French", "fr"],
  ["German", "de"],
  ["Greek", "el"],
  ["Hungarian", "hu"],
  ["Italian", "it"],
  ["Latvian", "lv"],
  ["Lithuanian", "lt"],
  ["Maltese", "mt"],
  ["Polish", "pl"],
  ["Portuguese", "pt"],
  ["Romanian", "ro"],
  ["Russian", "ru"],
  ["Slovak", "sk"],
  ["Slovenian", "sl"],
  ["Spanish", "es"],
  ["Swedish", "sv"],
  ["Ukrainian", "uk"],
];

const parts = [
  {
    name: "ScribeKit",
    url: "https://scribekit.lucaspiera.com",
    host: "scribekit.lucaspiera.com",
    text: "Parakeet v3 transcription with speakers, plus Markdown, SRT, WebVTT and JSON output.",
  },
  {
    name: "SystemAudioKit",
    url: "https://systemaudiokit.lucaspiera.com",
    host: "systemaudiokit.lucaspiera.com",
    text: "The microphone and what the Mac plays, as two aligned tracks, through Core Audio process taps.",
  },
  {
    name: "FluidAudio",
    url: "https://github.com/FluidInference/FluidAudio",
    host: "github.com",
    text: "Runs speech recognition and speaker detection on the Neural Engine.",
  },
  {
    name: "Parakeet TDT v3",
    url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
    host: "huggingface.co",
    text: "NVIDIA's speech model. About 480 MB, downloaded once during setup.",
  },
];

const callApps = [
  "Zoom",
  "Teams",
  "Google Meet",
  "Slack",
  "FaceTime",
  "Webex",
  "Discord",
];

const comparison = [
  ["Price", "Free", "Monthly subscription"],
  ["Audio is processed", "On your Mac", "On remote servers"],
  ["A bot joins the call", "No", "Often"],
  ["Transcripts go to", "Any folder you pick", "Their web app"],
  ["Source code", "Open, MIT", "Closed"],
];

const tiles = [
  {
    shot: "conversations",
    alt: "Conversations: today's Weekly product sync, 47 minutes on Zoom with three speakers",
    position: "62% 30%",
    values: ["47 min", "3 speakers", "Zoom", "162 words"],
    when: ["25 Sep 2026", "10:30"],
    name: "Conversations, searchable",
  },
  {
    shot: "destinations",
    alt: "Save location editor: folder ~/Notes/Meetings, file name {date} {time} - {title}, subfolder {year}/{month}",
    position: "50% 30%",
    values: ["Markdown", "Text", "SRT", "JSON"],
    when: ["~/Notes/Meetings", "{year}/{month}"],
    name: "Save locations, one per place",
  },
  {
    shot: "settings-recording",
    alt: "Recording settings: your microphone, the other side as system audio, permissions",
    position: "60% 30%",
    values: ["You", "Other side", "Core Audio", "2 tracks"],
    when: ["Microphone", "Everything on this Mac"],
    name: "Recording settings",
  },
  {
    shot: "settings-transcription",
    alt: "Transcription settings: language detected automatically, speakers identified, Parakeet TDT 0.6B v3 ready",
    position: "62% 30%",
    values: ["Parakeet", "v3", "25 lang.", "Offline"],
    when: ["Detect automatically", "Neural Engine"],
    name: "Transcription settings",
  },
];

export default function HomePage() {
  return (
    <main className="ep-page">
      <Reveal />
      <div className="ep-split">
        <div className="ep-reading">
          <Hero />

          <section
            className="ep-block"
            data-stage="1"
            aria-labelledby="ep-private"
          >
            <div data-reveal>
              <h2 id="ep-private" className="ep-head">
                Nothing leaves your Mac
              </h2>
              <ul className="ep-facts">
                <li>
                  Audio is recorded only between start and stop, into a folder
                  on your Mac.
                </li>
                <li>
                  Transcription and speaker detection run on the Neural Engine.
                </li>
                <li>
                  The only network requests download the models from Hugging
                  Face, once. After that EchoPad works offline.
                </li>
                <li>
                  No analytics, no crash reporting, no account. The source is
                  open, so you can check.
                </li>
              </ul>
              <figure className="ep-inline-shot">
                {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
                <img
                  src={asset("/screenshots/settings-transcription.png")}
                  alt="Transcription settings: Parakeet TDT 0.6B v3, runs on the Apple Neural Engine, fully offline"
                  width={2154}
                  height={1280}
                  loading="lazy"
                />
              </figure>
              <table className="ep-table">
                <caption>EchoPad next to a typical meeting note-taker</caption>
                <thead>
                  <tr>
                    <td />
                    <th scope="col">EchoPad</th>
                    <th scope="col">Typical note-taker</th>
                  </tr>
                </thead>
                <tbody>
                  {comparison.map(([label, ours, theirs]) => (
                    <tr key={label}>
                      <th scope="row">{label}</th>
                      <td className="is-ours">{ours}</td>
                      <td>{theirs}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          <section
            className="ep-block"
            data-stage="2"
            aria-labelledby="ep-nobot"
          >
            <div data-reveal>
              <h2 id="ep-nobot" className="ep-head">
                No bot joins the call
              </h2>
              <p>
                EchoPad hears what your Mac plays, not a meeting API. Your
                microphone and the call go on two tracks with one timeline, so
                your words are always yours and the other side is split into
                speakers you rename once.
              </p>
              <p>
                Because nothing joins the call, nobody is told you are
                recording. Laws on recording differ by country and many require
                consent, so tell people yourself.
              </p>
              <figure className="ep-inline-shot">
                {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
                <img
                  src={asset("/screenshots/settings-recording.png")}
                  alt="Recording settings: your microphone on one track, everything this Mac plays on the other"
                  width={2154}
                  height={1280}
                  loading="lazy"
                />
              </figure>
              <p>
                <Link href="/docs/privacy" className="ep-link">
                  Read the privacy page
                </Link>
              </p>
            </div>
          </section>
        </div>
        <div className="ep-fixed">
          <StickyStage />
        </div>
      </div>

      <StageSlider />

      <FormatSheet />

      <section className="ep-proof" aria-label="Call apps EchoPad notices">
        <p className="ep-proof-lead">It offers to record calls in</p>
        <ul>
          {callApps.map((app) => (
            <li key={app}>{app}</li>
          ))}
        </ul>
      </section>

      <section className="ep-lists" aria-labelledby="ep-lang">
        <div className="ep-list">
          <h2 id="ep-lang" className="ep-list-title">
            Parakeet hears 25 languages
          </h2>
          <p className="ep-list-note">
            Detected automatically, or set in Settings. The code goes into the
            front matter.
          </p>
          <ul data-reveal>
            {languages.map(([name, code]) => (
              <li key={code}>
                <span className="ep-dot" aria-hidden="true" />
                <span className="ep-row-name">{name}</span>
                <span className="ep-row-value">{code}</span>
              </li>
            ))}
          </ul>
        </div>
        <div className="ep-list">
          <h2 className="ep-list-title">Built in the open</h2>
          <p className="ep-list-note">
            EchoPad is MIT licensed, and so are the two Swift packages it is
            made of. Use them in your own apps.
          </p>
          <ul className="ep-parts" data-reveal>
            {parts.map((part) => (
              <li key={part.name}>
                <a href={part.url}>
                  <span className="ep-dot is-accent" aria-hidden="true" />
                  <span className="ep-row-name">{part.name}</span>
                  <span className="ep-row-value">{part.host}</span>
                </a>
                <p>{part.text}</p>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section className="ep-gallery" aria-labelledby="ep-gallery-title">
        <h2 id="ep-gallery-title" className="ep-head">
          One window for all of it
        </h2>
        <ul data-reveal>
          {tiles.map((tile, index) => (
            <li key={tile.shot} className={`ep-tile ep-tile-${index}`}>
              <div className="ep-tile-shot">
                {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
                <img
                  src={asset(`/screenshots/${tile.shot}.png`)}
                  alt={tile.alt}
                  width={2154}
                  height={1280}
                  loading="lazy"
                  style={{
                    objectPosition: tile.position,
                    transformOrigin: tile.position,
                  }}
                />
              </div>
              <div className="ep-strip">
                <p className="ep-strip-values">
                  {tile.values.map((value) => (
                    <span key={value}>{value}</span>
                  ))}
                </p>
                <p className="ep-strip-when">
                  <span>{tile.when[0]}</span>
                  <span>{tile.when[1]}</span>
                </p>
                <p className="ep-strip-name">{tile.name}</p>
              </div>
            </li>
          ))}
        </ul>
      </section>

      <section className="ep-cta" aria-labelledby="ep-cta-title">
        <div className="ep-cta-words" data-reveal>
          <h2 id="ep-cta-title" className="ep-display">
            Keep every conversation
          </h2>
          <p>
            Build it from source with three lines in Terminal. It needs macOS 26
            and Xcode 26 or its Command Line Tools. Setup asks for two
            permissions, downloads the models and lets you pick where
            transcripts go.
          </p>
          <p>
            <Link href="/docs/installation" className="ep-link is-light">
              Read the install guide
            </Link>
          </p>
        </div>
        <div className="ep-cta-fragment">
          <InstallTerminal />
        </div>
      </section>

      <footer className="ep-footer">
        <p>EchoPad, call transcripts on your Mac</p>
        <nav aria-label="Footer">
          <Link href="/docs">Docs</Link>
          <a href={repoUrl}>GitHub</a>
          <Link href="/docs/packages">Packages</Link>
          <a href={authorUrl}>Lucas Piera</a>
        </nav>
        <p className="ep-footer-end">
          MIT licence · <Link href="/docs/privacy">Privacy</Link>
        </p>
      </footer>
    </main>
  );
}

const BARS = Array.from({ length: 34 }, (_, index) => {
  const envelope =
    0.3 + 0.7 * Math.abs(Math.sin(index * 0.55) * Math.sin(index * 0.21 + 0.6));
  return Math.round(envelope * 100);
});

function Hero() {
  return (
    <header className="ep-card" data-stage="0">
      <div className="ep-wave" aria-hidden="true">
        {BARS.map((height, index) => (
          <span
            // biome-ignore lint/suspicious/noArrayIndexKey: bars never reorder
            key={index}
            style={{
              height: `${height}%`,
              animationDelay: `${-((index * 97) % 900)}ms`,
            }}
          />
        ))}
      </div>
      <div className="ep-card-body" data-reveal>
        <p className="ep-wordmark">
          {/* biome-ignore lint/performance/noImgElement: static export serves plain files */}
          <img src={asset("/icon-256.png")} alt="" width={56} height={56} />
          EchoPad
        </p>
        <h1 className="ep-display">Every call, on paper.</h1>
        <p className="ep-lead">
          EchoPad records your calls and meetings on your Mac, tells the
          speakers apart and saves the transcript where you keep your notes.
          Free and open source.
        </p>
        <Link href="/docs/installation" className="ep-button">
          Install EchoPad
        </Link>
      </div>
      <nav className="ep-card-links" aria-label="Site">
        <Link href="/docs">Docs</Link>
        <a href={repoUrl}>GitHub</a>
        <Link href="/docs/packages">Packages</Link>
      </nav>
    </header>
  );
}
