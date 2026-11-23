const cardsElement = document.querySelector<HTMLElement>("#cards")!;

let snapshot: unknown;
let providerIDs: string[] = [];
let message = "Loading usage…";

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderCard(card: ProviderCard, now: number): HTMLElement {
  const panel = element("section", "card");
  panel.style.setProperty("--accent", card.accent);
  const heading = element("h2", "provider", card.name);
  if (card.family) heading.append(" ", element("span", "provider-family", card.family));
  panel.append(heading);

  if (card.rows.length === 0) {
    panel.append(element("p", "empty", card.status));
    return panel;
  }

  for (const row of card.rows) {
    const quota = element("div", "quota");
    const caption = element("div", "caption");
    const percent = row.displayPercent === null ? "—" : `${Math.round(row.displayPercent)}%`;
    const percentage = element("span", "percentage", percent);
    if (row.displayPercent !== null)
      percentage.append(element("span", "quota-mode", card.showUsed ? " used" : " left"));
    const name = element("span", "label", row.label);
    name.title = row.label;
    caption.append(percentage, name);

    const track = element("div", "track");
    const fill = element("div", "fill");
    fill.style.width = `${row.displayPercent ?? 0}%`;
    if (row.usedPercent !== null && row.usedPercent >= 90) fill.classList.add("limit");
    const reset = resetCountdown(row.resetAt, now);
    const countdown = element("span", "countdown", reset);
    countdown.setAttribute("aria-label", row.resetAt === null ? "Reset time unavailable" : `Reset: ${reset}`);
    track.append(fill, countdown);

    quota.append(caption, track);
    panel.append(quota);
  }

  const footer = [card.stale ? "Last known" : "", card.extraRows ? `+${card.extraRows} more` : ""]
    .filter(Boolean)
    .join(" · ");
  if (footer) panel.append(element("p", "footer", footer));
  return panel;
}

function renderWidget(): number {
  const now = Date.now();
  const cards = message ? null : makeCards(snapshot, providerIDs, now);
  if (cards) {
    cardsElement.style.setProperty("--columns", String(cards.length));
    cardsElement.replaceChildren(...cards.map((card) => renderCard(card, now)));
    return cards.length;
  }
  cardsElement.style.setProperty("--columns", "1");
  cardsElement.replaceChildren(element("p", "empty notice", message || "Usage feed is incompatible"));
  return 0;
}

function updateWidget(raw: string, ids: string[], status: string): number {
  providerIDs = ids;
  message = status;
  try {
    snapshot = raw ? JSON.parse(raw) : null;
  } catch {
    snapshot = null;
  }
  return renderWidget();
}

renderWidget();
window.setInterval(renderWidget, 15_000);
