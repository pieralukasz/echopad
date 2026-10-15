/**
 * The sample call from the docs screenshots ("Weekly product sync"), rendered
 * the way ScribeKit's TranscriptRenderer and EchoPad's Exporter write it.
 * Word timings are spread evenly over each turn, since the sample has none.
 */

type Word = { text: string; start: number; end: number };
type Segment = {
  speakerID: string;
  start: number;
  end: number;
  text: string;
  words: Word[];
};

export const call = {
  title: "Weekly product sync",
  date: "2026-09-25",
  time: "10:30",
  duration: "00:47:12",
  app: "Zoom",
  language: "en",
  fileBase: "2026-09-25 10.30 - Weekly product sync",
  folder: "~/Notes/Meetings/2026/09",
  audio: "attachments/audio/2026-09-25 10.30 - Weekly product sync.m4a",
};

export const speakers = [
  { id: "local", name: "Lukasz", isLocal: true },
  { id: "s1", name: "Anna", isLocal: false },
  { id: "s2", name: "Marek", isLocal: false },
];

const turns: [string, number, number, string][] = [
  [
    "local",
    0,
    6.6,
    "Morning both. Quick agenda today: the export redesign, the beta date, and what we heard from the interviews.",
  ],
  [
    "s1",
    7,
    18.4,
    "I can start with interviews. Five of six people said they keep their notes in a folder they already sync, so they do not want another place for transcripts.",
  ],
  [
    "s2",
    19,
    25.5,
    "That matches the support tickets. The most common question is still whether files can go straight into Obsidian.",
  ],
  [
    "local",
    26,
    32.4,
    "Good, then save locations stay the main feature. Each one gets its own folder, file name and formats.",
  ],
  [
    "s1",
    33,
    39.2,
    "Can we add subtitles? Two people record talks and want an SRT next to the video.",
  ],
  [
    "local",
    40,
    46.1,
    "Already there. SRT and WebVTT are one toggle away, and they can live next to the Markdown.",
  ],
];

const round = (value: number) => Math.round(value * 100) / 100;

export const segments: Segment[] = turns.map(
  ([speakerID, start, end, text]) => {
    const tokens = text.split(" ");
    const step = (end - start) / tokens.length;
    return {
      speakerID,
      start,
      end,
      text,
      words: tokens.map((token, index) => ({
        text: token,
        start: round(start + index * step),
        end: round(start + (index + 1) * step - 0.04),
      })),
    };
  },
);

const nameOf = (id: string) => speakers.find((s) => s.id === id)?.name;
const pad = (value: number, size = 2) => String(value).padStart(size, "0");

/** `mm:ss`, as TranscriptRenderer.clock. */
function clock(seconds: number) {
  const total = Math.floor(seconds);
  return `${pad(Math.floor(total / 60))}:${pad(total % 60)}`;
}

function subtitleTime(seconds: number, vtt: boolean) {
  const millis = Math.round(Math.max(0, seconds) * 1000);
  const h = Math.floor(millis / 3_600_000);
  const m = Math.floor((millis % 3_600_000) / 60_000);
  const s = Math.floor((millis % 60_000) / 1000);
  return `${pad(h)}:${pad(m)}:${pad(s)}${vtt ? "." : ","}${pad(millis % 1000, 3)}`;
}

const join = (words: Word[]) => words.map((w) => w.text).join(" ");
const yaml = (value: string) => `"${value.replaceAll('"', '\\"')}"`;

export function markdown() {
  const meta: [string, string][] = [
    ["title", call.title],
    ["date", call.date],
    ["time", call.time],
    ["duration", call.duration],
    ["app", call.app],
    ["speakers", speakers.map((s) => s.name).join(", ")],
    ["language", call.language],
    ["audio", `[[${call.audio}]]`],
    ["source", "EchoPad"],
    ["tags", "meeting"],
  ];
  const lines = ["---", ...meta.map(([k, v]) => `${k}: ${yaml(v)}`), "---", ""];
  lines.push(`# ${call.title}`, "", `![[${call.audio}]]`, "");
  for (const segment of segments) {
    lines.push(
      `[${clock(segment.start)}] **${nameOf(segment.speakerID)}:** ${segment.text}`,
      "",
    );
  }
  return `${lines.join("\n").trim()}\n`;
}

export function text() {
  return `${segments.map((s) => `${nameOf(s.speakerID)}: ${s.text}`).join("\n\n")}\n`;
}

/** Cues of at most ~7 s / 84 characters, cut at clause boundaries when possible. */
export function subtitles(vtt: boolean) {
  const cues: { start: number; end: number; text: string }[] = [];
  for (const segment of segments) {
    const speaker = nameOf(segment.speakerID);
    let chunk: Word[] = [];
    const flush = () => {
      if (!chunk.length) return;
      const body = join(chunk);
      const first = chunk[0];
      const last = chunk[chunk.length - 1];
      cues.push({
        start: first.start,
        end: Math.max(last.end, first.start + 0.3),
        text: vtt ? `<v ${speaker}>${body}` : `${speaker}: ${body}`,
      });
      chunk = [];
    };
    for (const word of segment.words) {
      if (chunk.length) {
        const length = join([...chunk, word]).length;
        if (word.end - chunk[0].start > 7 || length > 84) {
          let cut = -1;
          chunk.forEach((w, i) => {
            if (/[.?!…,;:]$/.test(w.text)) cut = i;
          });
          if (
            cut >= 0 &&
            cut < chunk.length - 1 &&
            join(chunk.slice(0, cut + 1)).length >= 20
          ) {
            const rest = chunk.slice(cut + 1);
            chunk = chunk.slice(0, cut + 1);
            flush();
            chunk = rest;
          } else {
            flush();
          }
        }
      }
      chunk.push(word);
      if (/[.?!…]$/.test(word.text) && join(chunk).length >= 40) flush();
    }
    flush();
  }
  const out: string[] = vtt ? ["WEBVTT", ""] : [];
  cues.forEach((cue, index) => {
    if (!vtt) out.push(String(index + 1));
    out.push(
      `${subtitleTime(cue.start, vtt)} --> ${subtitleTime(cue.end, vtt)}`,
      cue.text,
      "",
    );
  });
  return out.join("\n");
}

/** Pretty-printed with sorted keys, like JSONEncoder in ScribeKit. */
export function json() {
  const sort = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(sort);
    if (value && typeof value === "object") {
      return Object.fromEntries(
        Object.keys(value)
          .sort()
          .map((key) => [key, sort((value as Record<string, unknown>)[key])]),
      );
    }
    return value;
  };
  // Apple's pretty printer puts a space on both sides of the colon.
  return JSON.stringify(
    sort({ duration: 2832, language: call.language, segments, speakers }),
    null,
    2,
  ).replace(/^(\s*"[^"]+"): /gm, "$1 : ");
}

export const formats = [
  { id: "md", name: "Markdown", render: markdown },
  { id: "txt", name: "Plain text", render: text },
  { id: "srt", name: "SRT", render: () => subtitles(false) },
  { id: "vtt", name: "WebVTT", render: () => subtitles(true) },
  { id: "json", name: "JSON", render: json },
] as const;
