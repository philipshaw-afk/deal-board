// Reads an exported M&A Monitor database PDF (the admin site's "deals_pdf" export) into the same
// field names and formats the Bid Premia spreadsheet loader used, plus the commentary sections.
// Pure: takes the PDF's text pieces (one array per page) and returns plain data, so it runs the
// same in the edge function and in a local test bench.

export type Item = { x: number; x2: number; y: number; t: string; fs: number };
type Line = { p: number; y: number; items: Item[] };

export type Parsed = {
  cols: Record<string, unknown>;      // top-level deals columns
  fields: Record<string, string | number>;
  key_dates: Record<string, string>;
  overview: string | null; profiles: string | null; background: string | null; financial_notes: string | null;
  target_details: string | null;
  warnings: string[];
};

const SECTIONS = ["Contents", "Summary", "Advisors", "Target Financials", "Deal Value", "Share Data", "Share Prices", "Offer History",
  "Disclosure Table (or Equivalent) /Indicative Offer Data", "PUSU Details", "Synergy Data & Industry Specific Multiples",
  "Comments", "Payment Details", "Target Details", "Further Information on M&A Monitor Ltd."];

const norm = (s: string) => s.replace(/\s+/g, " ").trim();
const isNum = (s: string) => /^-?[\d,]*\.?\d+$/.test(s.replace(/\s/g, ""));
const num = (s: string | undefined | null) => { if (s == null) return null; const v = Number(String(s).replace(/,/g, "").trim()); return Number.isFinite(v) ? v : null; };
const iso = (s: string | undefined | null) => { const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(String(s || "").trim()); return m ? `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}` : null; };
const f3 = (v: number) => (Math.round(v * 1000) / 1000).toFixed(3);
const f6 = (v: number) => v.toFixed(6);

function toLines(pages: Item[][]): Line[] {
  const out: Line[] = [];
  pages.forEach((items, i) => {
    const its = items.filter((it) => it.t.trim() !== "").sort((a, b) => b.y - a.y || a.x - b.x);
    let cur: Item[] = [], cy = 0;
    const flush = () => { if (cur.length) out.push({ p: i + 1, y: cy, items: cur.sort((a, b) => a.x - b.x) }); cur = []; };
    for (const it of its) { if (cur.length && Math.abs(it.y - cy) > 2.5) flush(); if (!cur.length) cy = it.y; cur.push(it); }
    flush();
  });
  return out;
}
const lineText = (l: Line) => norm(l.items.map((i) => i.t).join(" "));

// ---------------------------------------------------------------- label / value rows
// Items whose text is a known label (or starts with one, e.g. "Financial Wells Fargo") are labels;
// everything else is a value belonging to the nearest label to its left on the nearest label row.
type Row = { y: number; p: number; cells: { label: string; x: number; vals: { y: number; x: number; x2: number; t: string }[] }[] };

function rows(lines: Line[], labels: string[], maxDy = 7.5, leftOnly = false): Row[] {
  const sorted = [...labels].sort((a, b) => b.length - a.length);
  const out: Row[] = [];
  const loose: { line: Line; it: Item }[] = [];
  for (const l of lines) {
    let row: Row | null = null;
    for (const it of l.items) {
      const t = norm(it.t);
      const lab = leftOnly && it.x > 70 ? undefined : sorted.find((lb) => t === lb || t.startsWith(lb + " "));
      if (lab) {
        if (!row) { row = { y: l.y, p: l.p, cells: [] }; out.push(row); }
        row.cells.push({ label: lab, x: it.x, vals: [] });
        const rest = t.slice(lab.length).trim();
        if (rest) row.cells[row.cells.length - 1].vals.push({ y: l.y, x: it.x + (it.x2 - it.x) * (lab.length + 1) / t.length, x2: it.x2, t: rest });
      } else if (row && row.cells.length) {
        const c = [...row.cells].reverse().find((c) => c.x < it.x) || row.cells[0];
        c.vals.push({ y: l.y, x: it.x, x2: it.x2, t });
      } else loose.push({ line: l, it });
    }
  }
  // values on their own lines (wrapped text above / below a label) join the nearest label row
  for (const { line, it } of loose) {
    let best: Row | null = null;
    for (const r of out) if (r.p === line.p && Math.abs(r.y - line.y) <= maxDy && (!best || Math.abs(r.y - line.y) < Math.abs(best.y - line.y))) best = r;
    if (!best) continue;
    const c = [...best.cells].reverse().find((c) => c.x < it.x) || best.cells[0];
    c.vals.push({ y: line.y, x: it.x, x2: it.x2, t: norm(it.t) });
  }
  out.sort((a, b) => a.p - b.p || b.y - a.y);
  for (const r of out) for (const c of r.cells) c.vals.sort((a, b) => b.y - a.y || a.x - b.x);
  return out;
}
const joinVals = (v: { t: string }[]) => norm(v.map((x) => x.t).join(" "));

// ---------------------------------------------------------------- commentary
const PROFILE_HEADS = ["PROFILES OF PARTIES", "BIDDER PROFILE", "TARGET PROFILE", "BUSINESS PROFILE", "DIVESTOR PROFILE",
  "PROFILE OF BIDDER", "PROFILE OF TARGET", "PROFILE OF DIVESTOR", "SELLER PROFILE"];
const PROFILE_SUBHEADS = ["OPERATIONS", "SEGMENT INFORMATION", "FINANCIAL PERFORMANCE", "OVERVIEW", "DIVIDENDS"];
const NOTES_HEADS = ["NOTES TO TARGET FINANCIALS", "TARGET FINANCIALS", "BANKING RATIOS"];
const isHeading = (s: string) => s.length > 3 && s.length < 70 && s === s.toUpperCase() && /[A-Z]{3}/.test(s) && !/\d{3}/.test(s)
  && !/^[*\-(]/.test(s) && !/[.,;]$/.test(s);

// Rebuild the fixed-width commentary text line by line, keeping its spacing (the DataBase page spots tables by it).
function monoText(lines: Line[]): string {
  const its = lines.flatMap((l) => l.items);
  if (!its.length) return "";
  const ws = its.filter((i) => i.t.length >= 6).map((i) => (i.x2 - i.x) / i.t.length).sort((a, b) => a - b);
  const w = ws.length ? ws[Math.floor(ws.length / 2)] : 4.8;
  const x0 = Math.min(...its.map((i) => i.x));
  const gaps = lines.slice(1).map((l, i) => (l.p === lines[i].p ? lines[i].y - l.y : 0)).filter((g) => g > 0).sort((a, b) => a - b);
  const lead = gaps.length ? gaps[Math.floor(gaps.length / 2)] : 8.4;
  const out: string[] = [];
  lines.forEach((l, i) => {
    if (i && l.p === lines[i - 1].p && lines[i - 1].y - l.y > lead * 1.6) out.push("");
    let s = "";
    for (const it of l.items) {
      const col = Math.max(0, Math.round((it.x - x0) / w));
      if (col > s.length) s += " ".repeat(col - s.length); else if (s && !s.endsWith(" ")) s += " ";
      s += it.t;
    }
    out.push(s.replace(/\s+$/, ""));
  });
  return out.join("\n");
}

function splitCommentary(text: string) {
  const b: Record<string, string[]> = { overview: [], profiles: [], background: [], notes: [] };
  let cur = "overview", seenOverview = false, seenProfiles = false;
  const isProfileHead = (s: string) => PROFILE_HEADS.some((h) => s.startsWith(h)) || s.endsWith("PROFILE");
  // sections between the overview and the profiles (e.g. CONCURRENT TRANSACTION) stay with the overview, keeping the report's order
  const hasProfiles = text.split("\n").some((l) => isHeading(l.trim()) && isProfileHead(l.trim()));
  for (const line of text.split("\n")) {
    const s = line.trim();
    if (isHeading(s)) {
      if (s === "OVERVIEW" && !seenOverview) { seenOverview = true; cur = "overview"; }
      else if (isProfileHead(s)) { cur = "profiles"; seenProfiles = true; }
      else if (cur === "overview" && hasProfiles && !seenProfiles) { /* still before the profiles */ }
      else if (NOTES_HEADS.some((h) => s.startsWith(h))) cur = "notes";
      else if (cur === "profiles" && (PROFILE_SUBHEADS.includes(s) || /^\d+(\.\d+)*\)\s/.test(s))) { /* party sub-heading */ }
      else if (cur === "notes" && !s.startsWith("SOURCES")) { /* stays with the notes */ }
      else cur = "background";
    }
    b[cur].push(line);
  }
  const fin = (a: string[]) => a.join("\n").replace(/\n{3,}/g, "\n\n").trim() || null;
  return { overview: fin(b.overview), profiles: fin(b.profiles), background: fin(b.background), notes: fin(b.notes) };
}

// ---------------------------------------------------------------- main
const SUMMARY_LABELS = ["Target", "Industrial Sector", "SIC Codes", "Activities", "Country", "Stock Exchange Index", "Bidder",
  "Bidding Subsidiary", "Divestor", "Date Announced", "Date Completed", "Deal Status", "Deal Type", "Deal Attitude", "Cross Border",
  "% Capital Owned", "% Capital Bid For", "Competitive Status", "Regulatory Referral", "Consideration Type", "French Public", "US Public", "Type"];
const LEFT_VALUE = { "Ordinary Offer Value": "", "Other Equity Value": "", "Total Equity Value": "Implied Total Equity Value",
  "Net Debt": "Net debt", "Lease Liabilities": "", "Minorities": "", "Enterprise Value": "Enterprise Value", "Total Equity Value + Minorities": "" } as Record<string, string>;
const RIGHT_FIN = { "Sales": "Turnover (Sales)", "EBITDA": "EBITDA", "EBITA": "EBITA", "Operating Profit": "Operating profit",
  "Net Profit Before Tax": "Net profit before tax", "Net Profit After Tax": "", "Net Income (Earnings)": "Net Income (Earnings)",
  "Shareholders Funds": "Shareholders funds", "Bank Earnings": "", "Risk Weighted Assets": "", "Tier 1 Capital Ratio": "Tier 1 Ratio",
  "Total Capital Ratio": "Total Capital Ratio" } as Record<string, string>;
const RATIOS = { "Price / Sales": "Price/Sales", "Price / Earnings": "Price/Earnings", "Price / Book": "Price/Book",
  "Enterprise Value / Sales": "Enterprise Value/Sales", "Enterprise Value / EBITDA": "Enterprise Value/EBITDA",
  "Enterprise Value / EBITA": "Enterprise Value/EBITA", "Enterprise Value / EBIT": "Enterprise Value/EBIT",
  "Price/Bank Earnings": "Price/Bank Earnings", "Price/Book": "Price/Book", "Cost/Income Ratio": "Cost/Income Ratio",
  "Return on Equity": "Return on Equity", "Return on Avg. Equity": "Return on Avg. Equity", "Bad Debt Ratio": "Bad Debt Ratio",
  "Return on Assets": "Return on Assets", "Net Interest Margin": "Net Interest Margin", "Return on Avg. Assets": "Return on Avg. Assets",
  "Price / Net Profit before Tax": "", "Interest Income Ratio": "" } as Record<string, string>;
const PREMIA = { "1 Day": "1 day before announcement premium", "1 Week": "1 week before announcement premium",
  "2 Weeks": "2 weeks before announcement premium", "3 Weeks": "3 weeks before announcement premium",
  "4 Weeks": "4 weeks before announcement premium", "30 Day Average": "30 day average before announcement premium",
  "2 Months": "2 months before announcement premium", "3 Months": "3 months before announcement premium" } as Record<string, string>;

export function parseReport(pages: Item[][]): Parsed {
  const lines = toLines(pages);
  const warnings: string[] = [];
  // sections, in order
  const sec: Record<string, Line[]> = {};
  let cur = "_head", order = -1;
  for (const l of lines) {
    if (l.items.length === 1 && l.items[0].fs >= 8.6) {
      const t = norm(l.items[0].t), k = SECTIONS.indexOf(t);
      if (k > order || (k >= 0 && t === cur)) { cur = t; order = Math.max(order, k); sec[cur] = sec[cur] || []; continue; }
    }
    (sec[cur] = sec[cur] || []).push(l);
  }
  const S = (k: string) => sec[k] || [];
  const fields: Record<string, string | number> = {};
  const cols: Record<string, unknown> = {};
  const key_dates: Record<string, string> = {};

  // --- Summary: parties and classification
  const sumLines = S("Summary");
  const dv = sumLines.findIndex((l) => /^Deal Value\(m\)/.test(lineText(l)) || l.items.some((i) => /^Deal Value\(m\)$/.test(norm(i.t))));
  const top = dv >= 0 ? sumLines.slice(0, dv) : sumLines;
  let party = "target";
  const P: Record<string, Record<string, string>> = { target: {}, bidder: {}, sub: {}, divestor: {} };
  const D: Record<string, string> = {};
  for (const r of rows(top, SUMMARY_LABELS)) for (const c of r.cells) {
    const v = joinVals(c.vals);
    if (c.label === "Target") { party = "target"; P.target.name = v; continue; }
    if (c.label === "Bidder") { party = "bidder"; P.bidder.name = v; continue; }
    if (c.label === "Bidding Subsidiary") { party = "sub"; P.sub.name = v; continue; }
    if (c.label === "Divestor") { party = "divestor"; P.divestor.name = v; continue; }
    if (["Country", "Activities", "SIC Codes"].includes(c.label)) { if (v) P[party][c.label] = v; continue; }
    if (v) D[c.label] = v;
  }
  if (!P.target.name) warnings.push("no target name found");
  cols.target = P.target.name || null;
  cols.bidder = P.bidder.name || null;
  cols.seller = P.divestor.name || null;
  cols.target_country = P.target.Country || null;
  cols.bidder_country = P.bidder.Country || null;
  cols.seller_country = P.divestor.Country || null;
  cols.sector = D["Industrial Sector"] || null;
  const dealType = (D["Deal Type"] || "").replace(/\s+\/\s+/g, " / ");
  cols.deal_type = dealType || null;
  cols.is_public = /pub|squeeze-out|delisting/i.test(dealType);
  cols.deal_status = D["Deal Status"] || null;
  cols.is_pending = ["pending", "proposed"].includes((D["Deal Status"] || "pending").toLowerCase());
  cols.date_announced = iso(D["Date Announced"]);
  if (iso(D["Date Completed"])) key_dates.completed = iso(D["Date Completed"])!;
  const putF = (k: string, v: string | number | null | undefined) => { if (v !== null && v !== undefined && v !== "") fields[k] = v; };
  putF("Target Name", P.target.name);
  putF("Industrial Sector", D["Industrial Sector"]);
  putF("Target Activities", P.target.Activities);
  putF("Country", P.target.Country);
  putF("Ultimate Bidder", P.bidder.name);
  putF("Ultimate Divestor name", P.divestor.name);
  putF("Date announced", iso(D["Date Announced"]));
  putF("Status of deal", D["Deal Status"]);
  putF("Type of deal", dealType);
  putF("Deal Attitude", D["Deal Attitude"]);
  putF("Consideration type", D["Consideration Type"]);
  putF("pdf_activities", P.target.Activities);
  putF("pdf_bidding_subsidiary", P.sub.name);
  putF("pdf_consideration", D["Consideration Type"]);
  putF("pdf_stock_index", D["Stock Exchange Index"]);
  for (const [k, lab] of [["pdf_pct_owned", "% Capital Owned"], ["pdf_pct_bid_for", "% Capital Bid For"], ["pdf_cross_border", "Cross Border"],
    ["pdf_competitive_status", "Competitive Status"], ["pdf_regulatory_referral", "Regulatory Referral"]]) putF(k, D[lab]);

  // --- Summary: deal value and target financials (native and sterling columns)
  const valLines = dv >= 0 ? sumLines.slice(dv) : [];
  const ratioAt = valLines.findIndex((l) => /(Equity|Deal) Value Ratios/.test(lineText(l)));
  const valBlock = ratioAt >= 0 ? valLines.slice(0, ratioAt) : valLines;
  // the right-hand (target financials) block starts at its labels; older reports sit further right
  const rxs = valBlock.flatMap((l) => l.items).filter((i) => norm(i.t) in RIGHT_FIN).map((i) => i.x);
  const rx = (rxs.length ? Math.min(...rxs) : 310) - 2;
  const stgHead = valBlock.flatMap((l) => l.items).filter((i) => /^2\) STG$/.test(norm(i.t)));
  const leftStg = stgHead.find((i) => i.x < rx)?.x ?? null, rightStg = stgHead.find((i) => i.x >= rx)?.x ?? null;
  // each block's exchange rate to sterling ("... ("STG") = 1.330", sometimes on a line of its own)
  const rates: { x: number; v: number }[] = [];
  for (const l of valBlock) {
    if (l.items.some((i) => norm(i.t) in LEFT_VALUE || norm(i.t) in RIGHT_FIN)) break;
    for (const i of l.items) { const m = /(?:=\s*|^)(\d+\.\d{2,4})$/.exec(norm(i.t)); if (m) rates.push({ x: i.x, v: num(m[1])! }); }
  }
  const leftRate = rates.find((r) => r.x < rx)?.v ?? null, rightRate = rates.find((r) => r.x >= rx)?.v ?? null;
  const rate = leftRate;
  const fin: Record<string, number> = {};
  for (const l of valBlock) {
    const left = l.items.filter((i) => i.x < rx), right = l.items.filter((i) => i.x >= rx);
    for (const [part, map, stgX, bRate] of [[left, LEFT_VALUE, leftStg, leftRate], [right, RIGHT_FIN, rightStg, rightRate]] as const) {
      if (!part.length) continue;
      const lab = norm(part.filter((i) => !isNum(i.t)).map((i) => i.t).join(" "));
      if (!(lab in map)) continue;
      const nums = part.filter((i) => isNum(i.t));
      // two figures: native then sterling. One figure: placed by its column; where the block has a single column,
      // that column is in the block's own currency, converted with the block's rate (1.000 when it is sterling)
      let stgV: number | null = null, nat: Item | undefined;
      if (nums.length >= 2) { nat = nums[0]; stgV = num(nums[nums.length - 1].t); }
      else if (nums.length === 1) {
        if (stgX != null) { if (nums[0].x2 > stgX + 32) stgV = num(nums[0].t); else nat = nums[0]; }
        else { nat = nums[0]; const v = num(nums[0].t)!; stgV = /Ratio$/.test(lab) || !bRate ? v : v / bRate; }
      }
      if (map[lab] && stgV != null) {
        const v = stgV;
        if (/Ratio$/.test(lab)) putF(map[lab], f6(v));
        else if (map === RIGHT_FIN) fin[map[lab]] = v;
        else putF(map[lab], f3(v));
      }
      if (lab === "Total Equity Value" && nat) cols._equity_native = num(nat.t);
      if (lab === "Enterprise Value" && nat) cols._ev_native = num(nat.t);
      if (lab === "Total Equity Value + Minorities" && nat && cols._equity_native == null) cols._equity_native = num(nat.t);
    }
  }
  // target financials: kept only when the report has any (the spreadsheet left them out when all were zero)
  if (Object.values(fin).some((v) => v !== 0)) for (const [k, v] of Object.entries(fin)) putF(k, f3(v));
  // ratios: label followed by its number, wherever they sit on the line
  const ratioLines = ratioAt >= 0 ? valLines.slice(ratioAt + 1) : [];
  const bank = !!fields["Tier 1 Ratio"] || ratioLines.some((l) => /Price\/Bank Earnings/.test(lineText(l)));
  for (const l of ratioLines) {
    if (/^(Accounts Source|Deal Value Source)/.test(lineText(l))) break;
    let lab = "";
    for (const it of l.items) {
      const t = norm(it.t);
      if (isNum(t)) { const k = RATIOS[lab]; if (k) putF(k, f6(num(t)!)); lab = ""; }
      else lab = lab ? lab + " " + t : t;
    }
  }
  if (bank) { delete fields["Net debt"]; delete fields["Enterprise Value"]; }

  // --- Advisers
  const adv = S("Advisors");
  const head = adv.flatMap((l) => l.items).find((i) => /To Target\/Divestor/.test(i.t));
  const tcol = head ? head.x + (head.x2 - head.x) * Math.max(0, head.t.indexOf("To Target")) / head.t.length : 300;
  // a piece of text that runs from the bidder column into the target column is cut at the word break nearest the boundary
  const cut = (v: { y: number; x: number; x2: number; t: string }) => {
    if (!(v.x < tcol - 3 && v.x2 > tcol + 12)) return [v];
    const per = (v.x2 - v.x) / v.t.length, at = Math.round((tcol - v.x) / per);
    const sp = [...v.t.matchAll(/ /g)].map((m) => m.index!).filter((i) => !/ and$/.test(v.t.slice(0, i)) && !/^ and /.test(v.t.slice(i)));
    if (!sp.length) return [v];
    const i = sp.reduce((a, b) => (Math.abs(b - at) < Math.abs(a - at) ? b : a));
    return [{ ...v, t: v.t.slice(0, i).trim(), x2: v.x + i * per }, { ...v, t: v.t.slice(i).trim(), x: tcol }];
  };
  for (const r of rows(adv, ["Advisors", "Financial", "Legal"], 7.5, true)) for (const c of r.cells) {
    if (c.label === "Advisors") continue;
    const vals = c.vals.flatMap(cut);
    const bid = joinVals(vals.filter((v) => v.x < tcol - 3)), tgt = joinVals(vals.filter((v) => v.x >= tcol - 3));
    putF(`Bidder's ${c.label} Advisor`, bid);
    putF(`Target/Divestor's ${c.label} Advisor`, tgt);
  }

  // --- Target Financials page (banks: operating profit and pre-tax profit in sterling, as the spreadsheet had them)
  const tf = S("Target Financials");
  const tfv = (lab: RegExp) => { for (const l of tf) { const f = l.items[0]; if (f && lab.test(norm(f.t))) { const n = l.items.slice(1).find((i) => isNum(i.t) && i.x < 305); if (n) return num(n.t); } } return null; };
  const fx = (() => { for (const l of tf) { const t = lineText(l); const m = /Exchange Rate to £ STG\s+(-?[\d.]+)/.exec(t); if (m) return num(m[1]); } return rate; })();
  if (bank && fx) {
    const op = tfv(/^OPERATING PROFIT$/), pbt = tfv(/^NET PROFIT BEFORE TAX$/);
    if (op != null) putF("Operating profit", f3(op / fx));
    if (pbt != null) putF("Net profit before tax", f3(pbt / fx));
  }

  // --- Deal Value section: currency
  for (const r of rows(S("Deal Value"), ["Deal Value Source", "Deal Value Reliability", "Deal Value Currency", "Cash Consideration",
    "Cost of Equity Acquired", "Implied Total Equity Value"])) for (const c of r.cells) {
    if (c.label === "Deal Value Currency") { const m = /\b([A-Z]{3})\b/.exec(joinVals(c.vals)); if (m) cols.currency = m[1]; }
  }
  if (!cols.currency) {
    // older layouts: the deal value column heading on page 1 ("1) EUR", or a single "UK Sterling" column)
    const hd = valBlock.flatMap((l) => l.items).filter((i) => i.x < rx);
    const one = hd.map((i) => /^1\) ([A-Z]{3})$/.exec(norm(i.t))).find(Boolean);
    if (one) cols.currency = one[1];
    else if (hd.some((i) => /^UK Sterling$/.test(norm(i.t)))) cols.currency = "STG";
    else warnings.push("no deal value currency");
  }

  // --- Share Data: shares, offer prices
  const sd = [...S("Share Data"), ...S("Deal Value")];
  let cashI: number | null = null, cashF: number | null = null, shareF: number | null = null;
  for (const l of sd) {
    const t = lineText(l);
    let m = /^No\. of Ordinary Shares\s+([\d,.]+)/.exec(t); if (m) cols.shares_in_issue = num(m[1]);
    m = /^Cash Offer Value\s+(-?[\d,.]+)\s+(-?[\d,.]+)/.exec(t); if (m) { cashI = num(m[1]); cashF = num(m[2]); }
    m = /^Share Offer Value\s+(-?[\d,.]+)\s+(-?[\d,.]+)/.exec(t); if (m) shareF = num(m[2]);
  }
  if (cashI != null) fields["pdf_offer_initial"] = cashI;
  const price = cashF && cashF > 0 ? cashF : shareF && shareF > 0 ? shareF : null;
  if (price) { cols.offer_price = price; cols.offer_currency = cols.currency || null; }

  // --- Share Prices: bid premia before the announcement, and pre-bid speculation
  const sp = S("Share Prices");
  const hdr = sp.find((l) => /^Time\b/.test(lineText(l)) && /Bid Premia/.test(lineText(l)));
  if (hdr) {
    const hs = hdr.items.filter((i) => /Bid Premia|Target/.test(i.t));
    const bp = hs.find((i) => /Bid Premia/.test(i.t)), after = hs.filter((i) => /Target/.test(i.t))[1];
    for (const l of sp) {
      const lab = norm(l.items[0]?.t || ""); const key = PREMIA[lab];
      if (!key || !bp) continue;
      const v = l.items.slice(1).find((i) => i.x2 > bp.x && (!after || i.x2 <= after.x + 3) && isNum(i.t));
      if (v) fields[key] = Math.round(num(v.t)! * 100) / 100;
    }
  }
  const pbi = sp.findIndex((l) => /^Pre-Bid Speculation Date/.test(lineText(l)));
  if (pbi >= 0 && sp[pbi + 1]) {
    const it = sp[pbi + 1].items.map((i) => norm(i.t));
    const d = iso(it[0]); const prem = num(it[it.length - 1]);
    if (d) { fields["Pre-bid speculation date"] = d; key_dates.pre_bid_speculation = d; }
    if (d && prem != null && it.length >= 2) fields["Pre-bid speculation premium"] = Math.round(prem * 100) / 100;
  }

  // --- Disclosure table (UK / Irish publics)
  for (const l of S("Disclosure Table (or Equivalent) /Indicative Offer Data")) {
    const t = lineText(l);
    let m = /^Date Added\s+(\d{1,2}\/\d{1,2}\/\d{4})/.exec(t); if (m) { fields["Disclosure Date Added"] = iso(m[1])!; key_dates.disclosure_added = iso(m[1])!; }
    m = /Date Removed\s+(\d{1,2}\/\d{1,2}\/\d{4})/.exec(t); if (m) { fields["Disclosure Date Removed"] = iso(m[1])!; key_dates.disclosure_removed = iso(m[1])!; }
    m = /^Offeror Named\s+(\d{1,2}\/\d{1,2}\/\d{4})/.exec(t); if (m) fields["Offeror Named"] = iso(m[1])!;
  }

  // --- value (native): equity value, else enterprise value (as the loader did)
  const eq = cols._equity_native as number | null, ev = cols._ev_native as number | null;
  delete cols._equity_native; delete cols._ev_native;
  cols.value = eq ? eq : ev ? ev : (eq ?? ev ?? null);

  // --- commentary
  const comments = monoText(S("Comments"));
  const payment = monoText(S("Payment Details")).trim();
  const c = splitCommentary(comments);
  if (!comments.trim()) warnings.push("no Comments text");
  return {
    cols, fields, key_dates,
    overview: c.overview, profiles: c.profiles, background: c.background,
    financial_notes: [c.notes, payment].filter(Boolean).join("\n\n") || null,
    target_details: monoText(S("Target Details")).trim() || null,
    warnings,
  };
}
