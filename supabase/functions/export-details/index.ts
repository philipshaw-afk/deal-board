// export-details: reads exported database PDFs queued in public.export_parse_jobs and fills in each deal.
// Called by the database (pg_net) when an export is attached to a card or dropped in bulk on Pending deals.
// It only works on jobs already in the queue, so a stray call does nothing. Each call handles one PDF
// (an edge function gets 2s of CPU per request) and then calls itself for the next one until the queue is empty.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { getDocumentProxy } from "npm:unpdf@1.9.1";
import { parseReport, type Item } from "./parse.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const sb = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

async function readPdf(path: string) {
  const dl = await sb.storage.from("deal-files").download(path);
  if (dl.error) throw new Error("could not open " + path + ": " + dl.error.message);
  const pdf = await getDocumentProxy(new Uint8Array(await dl.data.arrayBuffer()));
  const pages: Item[][] = [];
  for (let p = 1; p <= pdf.numPages; p++) {
    const tc = await (await pdf.getPage(p)).getTextContent();
    // deno-lint-ignore no-explicit-any
    pages.push((tc.items as any[]).filter((i) => typeof i.str === "string")
      .map((i) => ({ x: i.transform[4], x2: i.transform[4] + i.width, y: i.transform[5], t: i.str, fs: Math.abs(i.transform[0]) })));
  }
  return parseReport(pages);
}

async function next() {
  const { count } = await sb.from("export_parse_jobs").select("id", { count: "exact", head: true }).eq("status", "queued");
  if (count) await fetch(`${URL_}/functions/v1/export-details`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
}

Deno.serve(async (req) => {
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body: take the next job */ }
  const { data: job, error } = await sb.rpc("claim_export_job", { p_job: body.job ? Number(body.job) : null });
  if (error) return json({ ok: false, error: error.message }, 500);
  if (!job || !job.id) return json({ ok: true, note: "nothing queued" });
  let out: unknown;
  try {
    const parsed = await readPdf(job.path);
    if (job.mode === "debug") {
      await sb.from("export_parse_jobs").update({ status: "done", finished_at: new Date().toISOString(), result: parsed }).eq("id", job.id);
      out = { ok: true, debug: true };
    } else {
      const { data, error: e2 } = await sb.rpc("apply_export_details", { p_job: job.id, p_data: parsed });
      if (e2) throw new Error(e2.message);
      out = data;
    }
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await sb.rpc("fail_export_job", { p_job: job.id, p_error: msg });
    out = { ok: false, error: msg };
  }
  EdgeRuntime.waitUntil(next());
  return json(out);
});
