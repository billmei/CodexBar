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
  const [anti, codex] = makeCards(snapshot, ["antigravity", "codex"], now);
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
  assert.equal(resetCountdown(card.rows[0].resetAt, now), "Reset due");
  assert.equal(card.rows[1].usedPercent, 100);
  assert.equal(resetCountdown(card.rows[1].resetAt, now), "—");
  assert.equal(card.stale, true);
});

test("formats live countdowns across minutes, hours, and days", () => {
  assert.equal(resetCountdown(now + 1, now), "1m");
  assert.equal(resetCountdown(Date.parse("2026-07-16T14:14:00Z"), now), "2h 14m");
  assert.equal(resetCountdown(Date.parse("2026-07-20T15:00:00Z"), now), "4d 3h");
});
