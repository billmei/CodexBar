import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const path = (relative) => fileURLToPath(new URL(relative, import.meta.url));
const source = execFileSync(
  process.execPath,
  [
    path("../../Scripts/transpile-plugin-ts.mjs"),
    path("usage.ts"),
    path("../../Sources/CodexBarCore/Resources/Plugins/sucrase-3.35.1.min.js"),
  ],
  { encoding: "utf8" },
);
const { makeCards, resetCountdown } = vm.runInNewContext(source + "\n({ makeCards, resetCountdown })");

const now = Date.parse("2026-07-16T12:00:00Z");
const snapshot = {
  schemaVersion: 1,
  generatedAt: "2026-07-16T12:00:00Z",
  staleAfterSeconds: 180,
  providers: [
    {
      id: "codex",
      name: "Codex",
      enabled: true,
      windows: [{ label: "Weekly", usedPercent: 0 }],
      updatedAt: "2026-07-16T11:56:00Z",
    },
    {
      id: "antigravity",
      name: "Antigravity",
      enabled: true,
      windows: [
        { label: "Idle model", usedPercent: 0, idle: true },
        { label: "Claude / GPT", usedPercent: 24, resetAt: "2026-07-16T14:14:00Z" },
        { label: "Gemini", usedPercent: 41, resetAt: "2026-07-20T15:00:00Z" },
        { label: "Another window", usedPercent: 90 },
      ],
    },
    {
      id: "private-provider",
      name: "Private",
      enabled: false,
      windows: [{ label: "Weekly", usedPercent: 88 }],
    },
  ],
};

test("uses selected order and the first two visible quota windows", () => {
  const cards = makeCards(snapshot, ["antigravity", "codex"], now);
  assert.equal(cards.length, 2);
  const [anti, codex] = cards;
  assert.equal(anti.name, "Antigravity");
  assert.equal(anti.rows.length, 2);
  assert.equal(anti.rows[0].label, "Claude / GPT");
  assert.equal(anti.rows[0].usedPercent, 24);
  assert.equal(anti.rows[1].label, "Gemini");
  assert.equal(anti.extraRows, 1);
  assert.equal(anti.stale, false);

  assert.equal(codex.name, "Codex");
  assert.equal(codex.rows[0].label, "Week");
  assert.equal(codex.rows[0].usedPercent, 0);
  assert.equal(codex.stale, true);
});

test("shows separate Antigravity cards, keeping the Claude/GPT pair visible at zero usage", () => {
  const window = (bucket, label, usedPercent, resetAt, idle = false) => ({
    kind: `antigravity-quota-summary-${bucket}`,
    label,
    usedPercent,
    resetAt,
    idle,
  });
  const sessionReset = "2026-07-16T15:30:00Z";
  const weeklyReset = "2026-07-20T08:00:00Z";
  const antigravity = {
    id: "antigravity",
    name: "Antigravity",
    enabled: true,
    windows: [
      window("3p-weekly", "Claude/GPT weekly", 0, weeklyReset, true),
      window("gemini-5h", "Gemini 5-hour", 10, "2026-07-16T16:26:00Z"),
      window("gemini-weekly", "Gemini weekly", 25, "2026-07-21T15:00:00Z"),
      window("3p-5h", "Claude/GPT 5-hour", 0, sessionReset, true),
    ],
  };
  const cards = makeCards({ ...snapshot, providers: [antigravity] }, ["claude", "codex", "antigravity"], now);
  assert.equal(cards.length, 4);
  const [, , gemini, claude] = cards;
  assert.equal(gemini.name, "Antigravity");
  assert.equal(gemini.family, "Gemini");
  assert.equal(gemini.rows[0].label, "5-hour");
  assert.equal(gemini.rows[0].usedPercent, 10);
  assert.equal(gemini.rows[1].usedPercent, 25);
  assert.equal(gemini.extraRows, 0);
  assert.equal(claude.family, "Claude / GPT");
  assert.equal(claude.rows[0].label, "5-hour");
  assert.equal(claude.rows[0].displayPercent, 100);
  assert.equal(claude.rows[0].resetAt, Date.parse(sessionReset));
  assert.equal(claude.rows[1].label, "Week");
  assert.equal(claude.rows[1].resetAt, Date.parse(weeklyReset));
});

test("uses the Antigravity bucket ID to keep a lone Claude window off the Gemini card", () => {
  const provider = {
    id: "antigravity",
    enabled: true,
    windows: [{ kind: "antigravity-quota-summary-third-party-session", label: "Gemini 5-hour", usedPercent: 48 }],
  };
  const cards = makeCards({ ...snapshot, providers: [provider] }, ["antigravity"], now);
  assert.equal(cards.length, 1);
  assert.equal(cards[0].family, "Claude / GPT");
  assert.equal(cards[0].rows[0].label, "5-hour");
  assert.equal(cards[0].rows[0].usedPercent, 48);
});

test("uses the server bar-fill preference for the percentage and defaults to remaining", () => {
  const rows = (host) => makeCards({ ...snapshot, host }, ["antigravity"], now)[0];
  const used = rows({ usageBarsShowUsed: true });
  const left = rows({ usageBarsShowUsed: false });
  assert.equal(used.showUsed, true);
  assert.equal(used.rows[0].displayPercent, 24);
  assert.equal(left.showUsed, false);
  assert.equal(left.rows[0].displayPercent, 76);
  assert.equal(left.rows[0].usedPercent, 24);
  assert.equal(rows(undefined).rows[0].displayPercent, 76);
  assert.equal(makeCards(snapshot, ["codex"], now)[0].rows[0].displayPercent, 100);
});

test("uses remaining quota from the payload and derives consumption when needed", () => {
  const [card] = makeCards(
    {
      ...snapshot,
      providers: [
        { id: "codex", enabled: true, windows: [{ usedPercent: 91, remainingPercent: 7 }, { remainingPercent: 8 }] },
      ],
    },
    ["codex"],
    now,
  );
  assert.equal(card.rows[0].displayPercent, 7);
  assert.equal(card.rows[0].usedPercent, 91);
  assert.equal(card.rows[1].displayPercent, 8);
  assert.equal(card.rows[1].usedPercent, 92);
});

test("withdraws disabled providers and handles bad or incompatible snapshots", () => {
  const [disabled, missing] = makeCards(snapshot, ["private-provider", "claude"], now);
  assert.equal(disabled.rows.length, 0);
  assert.equal(missing.status, "Provider unavailable");
  assert.equal(makeCards({ ...snapshot, schemaVersion: 2 }, ["claude"], now), null);
  assert.equal(makeCards({ schemaVersion: 1, providers: null }, ["claude"], now), null);
});

test("keeps reset-only and unavailable readings distinct from zero usage", () => {
  const [card] = makeCards(
    {
      ...snapshot,
      providers: [
        {
          id: "codex",
          enabled: true,
          error: { code: "timeout" },
          windows: [{ resetAt: "2026-07-16T12:00:00Z" }, { usedPercent: 109, resetAt: "invalid" }],
        },
      ],
    },
    ["codex"],
    now,
  );
  assert.equal(card.rows[0].usedPercent, null);
  assert.equal(card.rows[0].displayPercent, null);
  assert.equal(resetCountdown(card.rows[0].resetAt, now), "Reset due");
  assert.equal(card.rows[1].usedPercent, 100);
  assert.equal(card.rows[1].displayPercent, 0);
  assert.equal(resetCountdown(card.rows[1].resetAt, now), "—");
  assert.equal(card.stale, true);
});

test("formats live countdowns across minutes, hours, and days", () => {
  assert.equal(resetCountdown(now + 1, now), "1m");
  assert.equal(resetCountdown(Date.parse("2026-07-16T14:14:00Z"), now), "2h 14m");
  assert.equal(resetCountdown(Date.parse("2026-07-20T15:00:00Z"), now), "4d 3h");
});
