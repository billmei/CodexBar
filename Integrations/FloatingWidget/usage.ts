interface WindowReading {
  label: string;
  usedPercent: number | null;
  displayPercent: number | null;
  resetAt: number | null;
}

interface ProviderCard {
  name: string;
  accent: string;
  showUsed: boolean;
  rows: WindowReading[];
  extraRows: number;
  stale: boolean;
  status: string;
}

const providerColors: Readonly<Record<string, string>> = {
  claude: "#e58360",
  codex: "#29d898",
  antigravity: "#a782ff",
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

function quotaRow(raw: unknown, showUsed: boolean): WindowReading | null {
  const row = object(raw);
  if (!row || row.idle === true) return null;
  const reportedUsed = finitePercent(row.usedPercent);
  const reportedRemaining = finitePercent(row.remainingPercent);
  const usedPercent = reportedUsed ?? (reportedRemaining === null ? null : 100 - reportedRemaining);
  const remainingPercent = reportedRemaining ?? (usedPercent === null ? null : 100 - usedPercent);
  const name = label(row.label, "Usage");
  return {
    label: name === "Weekly" ? "Week" : name,
    usedPercent,
    displayPercent: showUsed ? usedPercent : remainingPercent,
    resetAt: timestamp(row.resetAt),
  };
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

  return providerIDs.map((id) => {
    const provider = providers.get(id);
    const rows =
      provider?.enabled === true && Array.isArray(provider.windows)
        ? provider.windows.flatMap((raw: unknown) => {
            const row = quotaRow(raw, showUsed);
            return row ? [row] : [];
          })
        : [];
    const measured = timestamp(provider?.updatedAt) ?? generated;
    const accent = object(provider?.display)?.accentColor;
    return {
      name: label(provider?.name, id),
      showUsed,
      accent: Object.hasOwn(providerColors, id)
        ? providerColors[id]
        : typeof accent === "string" && /^#[0-9a-f]{6}$/i.test(accent)
          ? accent
          : "#8da4ee",
      rows: rows.slice(0, 2),
      extraRows: Math.max(0, rows.length - 2),
      stale: rows.length > 0 && (measured === null || now - measured > maxAge || !!provider?.error),
      status: provider?.enabled === true ? "Usage unavailable" : "Provider unavailable",
    };
  });
}
