interface WindowReading {
  label: string;
  usedPercent: number | null;
  displayPercent: number | null;
  resetAt: number | null;
}

interface ProviderCard {
  name: string;
  family?: string;
  accent: string;
  showUsed: boolean;
  rows: WindowReading[];
  extraRows: number;
  stale: boolean;
  status: string;
}

interface CardWindows {
  family?: string;
  windows: Record<string, unknown>[];
}

const providerColors: Readonly<Record<string, string>> = {
  claude: "#e58360",
  codex: "#29d898",
  antigravity: "#2f71e4",
};

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function label(value: unknown, fallback: string): string {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : fallback;
}

function timestamp(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function resetCountdown(resetAt: number | null, now: number): string {
  if (resetAt === null) return "—";
  if (resetAt <= now) return "Reset due";

  const remaining = Math.ceil((resetAt - now) / 60_000);
  const days = Math.floor(remaining / (24 * 60));
  const hours = Math.floor(remaining / 60) % 24;
  const minutes = remaining % 60;
  if (days) return hours ? `${days}d ${hours}h` : `${days}d`;
  if (hours) return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
  return `${minutes}m`;
}

function finitePercent(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : null;
}

function quotaRow(row: Record<string, unknown>, showUsed: boolean, providerID: string): WindowReading {
  const reportedUsed = finitePercent(row.usedPercent);
  const reportedRemaining = finitePercent(row.remainingPercent);
  const usedPercent = reportedUsed ?? (reportedRemaining === null ? null : 100 - reportedRemaining);
  const remainingPercent = reportedRemaining ?? (usedPercent === null ? null : 100 - usedPercent);
  const name = label(row.label, "Usage");
  const fiveHourSession = name === "Session" && (providerID === "claude" || providerID === "codex");
  return {
    label: fiveHourSession ? "5-Hour" : name === "Weekly" ? "Week" : name,
    usedPercent,
    displayPercent: showUsed ? usedPercent : remainingPercent,
    resetAt: timestamp(row.resetAt),
  };
}

function visibleWindows(windows: Record<string, unknown>[]): CardWindows {
  return { windows: windows.filter((window) => window.idle !== true) };
}

function antigravityCardWindows(windows: Record<string, unknown>[]): CardWindows[] {
  const gemini: { window: Record<string, unknown>; label: string }[] = [];
  const claude: Record<string, unknown>[] = [];
  const other: Record<string, unknown>[] = [];
  const prefix = "antigravity-quota-summary-";

  for (const window of windows) {
    const kind = label(window.kind, "").toLowerCase();
    const bucket = kind.startsWith(prefix) ? kind.slice(prefix.length) : "";
    const title = label(window.label, "").toLowerCase();
    const cadence =
      / (5-hour|weekly)$/.exec(title)?.[1] ?? /-(weekly|5h|5-hour|session|five-hour|five hour)$/.exec(bucket)?.[1];
    const geminiBucket = /^gemini-(weekly|5h|5-hour|session|five-hour|five hour)$/.test(bucket);
    const claudeBucket = /(?:^|-)(3p|third-party)(?:-|$)/.test(bucket);
    const cadenceLabel = cadence === "weekly" ? "Weekly" : "5-Hour";
    if (bucket && cadence && !claudeBucket && (geminiBucket || /^gemini (5-hour|weekly)$/.test(title))) {
      gemini.push({ window, label: cadenceLabel });
    } else if (bucket && cadence && !bucket.includes("gemini") && (claudeBucket || /\b(claude|gpt)\b/.test(title))) {
      claude.push({ ...window, label: cadenceLabel });
    } else if (window.idle !== true) {
      other.push(window);
    }
  }

  if (claude.length === 0) return [visibleWindows(windows)];

  // Both tracked families are useful at zero usage, including their reset times.
  claude.sort((a, b) => Number(a.label === "Weekly") - Number(b.label === "Weekly"));
  const geminiFillsCard = gemini.length >= 2 || (gemini.length === 1 && other.length === 0);
  const standard: CardWindows = {
    family: geminiFillsCard ? "Gemini" : undefined,
    windows: [...gemini.map(({ window, label }) => (geminiFillsCard ? { ...window, label } : window)), ...other],
  };
  const thirdParty = { family: "Claude / GPT", windows: claude };
  return standard.windows.length ? [standard, thirdParty] : [thirdParty];
}

function makeCards(snapshot: unknown, providerIDs: string[], now: number): ProviderCard[] | null {
  const root = object(snapshot);
  if (!root || root.schemaVersion !== 1 || !Array.isArray(root.providers)) return null;
  const showUsed = object(root.host)?.usageBarsShowUsed === true;

  const timeout = root.staleAfterSeconds;
  const maxAge = (typeof timeout === "number" && timeout > 0 ? timeout : 180) * 1_000;
  const generated = timestamp(root.generatedAt);
  const providers = new Map(
    root.providers.flatMap((raw: unknown) => {
      const provider = object(raw);
      return typeof provider?.id === "string" ? [[provider.id, provider] as const] : [];
    }),
  );

  return providerIDs.flatMap((id) => {
    const provider = providers.get(id);
    const windows =
      provider?.enabled === true && Array.isArray(provider.windows)
        ? provider.windows.flatMap((raw: unknown) => {
            const window = object(raw);
            return window ? [window] : [];
          })
        : [];
    const measured = timestamp(provider?.updatedAt) ?? generated;
    const providedAccent = object(provider?.display)?.accentColor;
    const accent = Object.hasOwn(providerColors, id)
      ? providerColors[id]
      : typeof providedAccent === "string" && /^#[0-9a-f]{6}$/i.test(providedAccent)
        ? providedAccent
        : "#8da4ee";
    const groups = id === "antigravity" ? antigravityCardWindows(windows) : [visibleWindows(windows)];
    return groups.map(({ family, windows }) => ({
      name: label(provider?.name, id),
      family,
      showUsed,
      accent,
      rows: windows.slice(0, 2).map((window) => quotaRow(window, showUsed, id)),
      extraRows: Math.max(0, windows.length - 2),
      stale: windows.length > 0 && (measured === null || now - measured > maxAge || !!provider?.error),
      status: provider?.enabled === true ? "Usage unavailable" : "Provider unavailable",
    }));
  });
}
