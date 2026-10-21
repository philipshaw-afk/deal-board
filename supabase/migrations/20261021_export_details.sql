-- ============ Reading exported database PDFs into deal details ============
-- Every export PDF that reaches DIANA (attached to a card, or dropped in bulk on Pending deals) is queued here;
-- the export-details edge function reads it and apply_export_details() fills in the deal.

alter table public.export_parse_jobs alter column deal_id drop not null;
alter table public.export_parse_jobs
  add column if not exists deal_number text,
  add column if not exists file_name text,
  add column if not exists source text not null default 'card' check (source in ('card', 'bulk', 'test')),
  add column if not exists card_id uuid,
  add column if not exists uploaded_by text,
  add column if not exists attempts int not null default 0;
create index if not exists export_parse_jobs_status on public.export_parse_jobs (status, id);

-- words of a party name, for checking that a PDF belongs to the deal it is filed against
create or replace function public.party_words(p text) returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array_agg(w order by n), '{}')
    from unnest(string_to_array(btrim(regexp_replace(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9 ]', '', 'g'), '\s+', ' ', 'g')), ' ')) with ordinality as t(w, n)
   where w <> '' $$;

create or replace function public.same_party(a text, b text) returns boolean language sql immutable set search_path = '' as $$
  with x as (select public.party_words(a) wa, public.party_words(b) wb)
  select cardinality(wa) > 0 and cardinality(wb) > 0 and (wa[1] = wb[1] or exists (
    select 1 from unnest(wa) w where w = any (wb) and w <> all (array['sa','ag','plc','ltd','limited','inc','the','of','and','group','holding',
      'holdings','spa','ab','nv','bv','se','as','asa','co','company','corp','corporation','sas','gmbh','llc','lp','de','la','sarl','srl'])))
  from x $$;

-- the next job to work on (or the one asked for); jobs stuck for 3 minutes go back in the queue
create or replace function public.claim_export_job(p_job bigint default null)
returns public.export_parse_jobs language plpgsql security definer set search_path = '' as $$
declare j public.export_parse_jobs;
begin
  update public.export_parse_jobs set status = 'queued', started_at = null
   where status = 'running' and started_at < now() - interval '3 minutes' and attempts < 3;
  update public.export_parse_jobs set status = 'failed', finished_at = now(), error = coalesce(error, 'gave up after 3 attempts')
   where status = 'running' and started_at < now() - interval '3 minutes' and attempts >= 3;
  update public.export_parse_jobs set status = 'running', started_at = now(), attempts = attempts + 1
   where id = (select id from public.export_parse_jobs where status = 'queued' and (p_job is null or id = p_job)
                order by id limit 1 for update skip locked)
  returning * into j;
  return j;
end $$;

create or replace function public.fail_export_job(p_job bigint, p_error text) returns void
language sql security definer set search_path = '' as $$
  update public.export_parse_jobs set status = 'failed', finished_at = now(), error = left(p_error, 1000) where id = p_job $$;

-- one worker call: a given job, or the next in the queue (each worker carries on until the queue is empty)
drop function if exists public.run_export_parse(bigint);
create function public.run_export_parse(p_job bigint default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://awpbhcyhfgsznmrqiddv.supabase.co/functions/v1/export-details',
    body := case when p_job is null then '{}'::jsonb else jsonb_build_object('job', p_job) end,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 120000);
end $$;

create or replace function public.kick_export_jobs() returns int
language plpgsql security definer set search_path = '' as $$
declare q int; r int; n int;
begin
  select count(*) filter (where status = 'queued'), count(*) filter (where status = 'running' and started_at > now() - interval '3 minutes')
    into q, r from public.export_parse_jobs;
  n := least(q, greatest(0, 4 - r));
  for i in 1..n loop perform public.run_export_parse(null); end loop;
  return n;
end $$;

-- write what the edge function read from the PDF into the deal
create or replace function public.apply_export_details(p_job bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  j public.export_parse_jobs; d public.deals; v_id uuid;
  c jsonb := coalesce(p_data -> 'cols', '{}'); pf jsonb := coalesce(p_data -> 'fields', '{}'); f jsonb;
  notes text[] := '{}'; v_status text; v_value numeric; v_cur text; v_eur numeric; v_linked boolean := false;
begin
  select * into j from public.export_parse_jobs where id = p_job;
  if j.id is null then return null; end if;
  v_id := j.deal_id;
  if v_id is null and j.deal_number is not null then
    select id into v_id from public.deals where deal_number = j.deal_number;
    if v_id is null then
      v_id := public.link_deal_number(j.deal_number, c ->> 'target', c ->> 'bidder');
      if v_id is not null then v_linked := true; notes := notes || 'numbered the deal DIANA had found'; end if;
    end if;
    if v_id is null then
      insert into public.deals (deal_number, target, coverage_status, admin_state, deal_status, is_pending, date_found)
      values (j.deal_number, coalesce(c ->> 'target', j.file_name), 'reported', 'LIVE', coalesce(c ->> 'deal_status', 'Pending'),
              coalesce((c ->> 'is_pending')::boolean, true), current_date)
      returning id into v_id;
      notes := notes || 'new deal added';
    end if;
    update public.export_parse_jobs set deal_id = v_id where id = p_job;
  end if;
  select * into d from public.deals where id = v_id;

  -- the PDF must be for this deal: its target or bidder has to match the one DIANA holds
  if d.target is not null and c ->> 'target' is not null
     and not (public.same_party(d.target, c ->> 'target') or public.same_party(d.bidder, c ->> 'bidder')) then
    update public.export_parse_jobs set status = 'failed', finished_at = now(),
      error = 'This PDF is for ' || (c ->> 'target') || coalesce(' / ' || (c ->> 'bidder'), '') || ', not ' || d.target || coalesce(' / ' || d.bidder, '')
     where id = p_job;
    if j.card_id is not null then
      update public.cards set check_failed = true where id = j.card_id;
      insert into public.card_history (card_id, actor, action) values (j.card_id, 'DIANA',
        'Possible error: ' || coalesce(j.file_name, 'this PDF') || ' is for ' || (c ->> 'target') || ', not ' || d.target || '. Check the deal number before going on.');
    end if;
    return jsonb_build_object('mismatch', true);
  end if;

  -- a deal DIANA has already closed is not reopened by an export that still says pending
  v_status := coalesce(c ->> 'deal_status', d.deal_status);
  if lower(coalesce(d.deal_status, '')) in ('completed', 'failed') and lower(coalesce(c ->> 'deal_status', '')) in ('pending', 'proposed') then
    notes := notes || ('kept ' || d.deal_status || ': the report still says ' || (c ->> 'deal_status'));
    v_status := d.deal_status;
  end if;

  -- fields: the PDF's values win; a fuller consideration wording already held is kept
  f := coalesce(d.fields, '{}') || pf;
  if d.fields ? 'Consideration type' and pf ? 'Consideration type'
     and lower(d.fields ->> 'Consideration type') like lower(pf ->> 'Consideration type') || ' plus %' then
    f := jsonb_set(f, '{Consideration type}', d.fields -> 'Consideration type');
  end if;
  if d.deal_number is not null then f := f || jsonb_build_object('Deal Number', d.deal_number); end if;

  v_value := coalesce((c ->> 'value')::numeric, d.value);
  v_cur := coalesce(c ->> 'currency', d.currency);
  v_eur := case when v_cur = 'EUR' then v_value
                when v_cur is not distinct from d.currency and d.value > 0 and d.value_eur is not null then round(v_value * d.value_eur / d.value, 3)
                else d.value_eur end;

  update public.deals set
    target = coalesce(c ->> 'target', target),
    bidder = coalesce(c ->> 'bidder', bidder),
    seller = coalesce(c ->> 'seller', seller),
    target_country = c ->> 'target_country', bidder_country = c ->> 'bidder_country', seller_country = c ->> 'seller_country',
    sector = c ->> 'sector',
    deal_type = coalesce(c ->> 'deal_type', deal_type),
    is_public = case when c ->> 'deal_type' is not null then (c ->> 'is_public')::boolean else is_public end,
    deal_status = v_status,
    is_pending = lower(coalesce(v_status, 'pending')) in ('pending', 'proposed'),
    value = v_value, currency = v_cur, value_eur = v_eur,
    date_announced = coalesce((c ->> 'date_announced')::date, date_announced),
    offer_price = coalesce((c ->> 'offer_price')::numeric, offer_price),
    offer_currency = coalesce(c ->> 'offer_currency', offer_currency),
    shares_in_issue = coalesce((c ->> 'shares_in_issue')::numeric, shares_in_issue),
    key_dates = coalesce(key_dates, '{}') || coalesce(p_data -> 'key_dates', '{}'),
    overview = coalesce(p_data ->> 'overview', overview),
    profiles = coalesce(p_data ->> 'profiles', profiles),
    background = coalesce(p_data ->> 'background', background),
    financial_notes = coalesce(p_data ->> 'financial_notes', financial_notes),
    fields = f,
    -- a bulk export is the live report: it becomes the deal's PDF
    export_path = case when j.source = 'bulk' then j.path else export_path end,
    exported_at = case when j.source = 'bulk' then now() else exported_at end,
    coverage_status = case when j.source = 'bulk' and coverage_status <> 'excluded' then 'reported' else coverage_status end,
    admin_state = case when j.source = 'bulk' then 'LIVE' else admin_state end,
    writing_note = case when j.source = 'bulk' then null else writing_note end
  where id = v_id;
  if j.source = 'bulk' then
    insert into public.deal_versions (deal_id, file_path, uploaded_by) values (v_id, j.path, coalesce(j.uploaded_by, 'bulk upload'));
  end if;

  update public.export_parse_jobs set status = 'done', finished_at = now(), error = null,
    result = jsonb_build_object('deal_id', v_id, 'deal_number', coalesce(d.deal_number, j.deal_number), 'fields', (select count(*) from jsonb_object_keys(pf)),
                                'notes', to_jsonb(notes), 'warnings', p_data -> 'warnings')
   where id = p_job;
  return jsonb_build_object('ok', true, 'deal_id', v_id, 'notes', to_jsonb(notes));
end $$;

-- bulk: the browser has put the PDFs in storage (exports/...); queue them and start the workers
create or replace function public.register_exports(p_items jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare me uuid := public.require_team(); n int := 0; it jsonb; v_deal uuid;
begin
  if not exists (select 1 from public.team_members where id = me and role in ('lead', 'deputy')) then
    raise exception 'Only Phil or Graham can load exports in bulk' using errcode = '42501';
  end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]')) loop
    if coalesce(it ->> 'number', '') !~ '^\d{7}$' or coalesce(it ->> 'path', '') !~ '^exports/' then continue; end if;
    select id into v_deal from public.deals where deal_number = it ->> 'number';
    insert into public.export_parse_jobs (deal_id, deal_number, path, file_name, source, uploaded_by)
    values (v_deal, it ->> 'number', it ->> 'path', it ->> 'name', 'bulk', public.actor_name());
    n := n + 1;
  end loop;
  perform public.kick_export_jobs();
  return n;
end $$;

create or replace function public.export_jobs_status(p_since timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_team();
  return (select jsonb_build_object(
    'queued', count(*) filter (where status = 'queued'), 'running', count(*) filter (where status = 'running'),
    'done', count(*) filter (where status = 'done'), 'failed', count(*) filter (where status = 'failed'),
    'problems', coalesce(jsonb_agg(jsonb_build_object('file', file_name, 'error', error)) filter (where status = 'failed'), '[]'),
    'notes', coalesce(jsonb_agg(jsonb_build_object('file', file_name, 'notes', result -> 'notes'))
                      filter (where status = 'done' and jsonb_array_length(coalesce(result -> 'notes', '[]')) > 0), '[]'))
    from public.export_parse_jobs where created_at >= p_since and source <> 'test');
end $$;

create or replace function public.kick_export_jobs_ui() returns int
language plpgsql security definer set search_path = '' as $$
begin perform public.require_team(); return public.kick_export_jobs(); end $$;

-- card uploads: an export PDF attached to a card is read too
create or replace function public.attach_file(p_card uuid, p_path text, p_name text, p_kind text DEFAULT 'other'::text)
returns void language plpgsql security definer set search_path to '' as $function$
declare me uuid := public.require_team(); v_deal uuid; v_actor text := public.actor_name(); v_job bigint;
begin
  select deal_id into v_deal from public.cards where id = p_card;
  insert into public.card_files (card_id, deal_id, path, name, kind, uploaded_by)
  values (p_card, v_deal, p_path, p_name, p_kind, v_actor);
  insert into public.card_history (card_id, actor, action) values (p_card, v_actor, 'Attached ' || p_name);
  if p_kind = 'export' and v_deal is not null then
    insert into public.deal_versions (deal_id, file_path, uploaded_by) values (v_deal, p_path, v_actor);
    update public.deals set export_path = p_path, exported_at = now() where id = v_deal;
    perform public.export_attached(v_deal, p_name);
    update public.cards set check_failed = false where id = p_card;
    if p_name ~* '\.pdf$' then
      insert into public.export_parse_jobs (deal_id, deal_number, path, file_name, source, card_id, uploaded_by)
      values (v_deal, substring(p_name from '^(\d{7})'), p_path, p_name, 'card', p_card, v_actor) returning id into v_job;
      perform public.run_export_parse(v_job);
    end if;
  end if;
end $function$;

create or replace function public.attach_file(p_card uuid, p_path text, p_name text, p_kind text, p_text text)
returns void language plpgsql security definer set search_path to '' as $function$
declare me uuid := public.require_team(); v_deal uuid; v_actor text := public.actor_name(); v_job bigint;
begin
  select deal_id into v_deal from public.cards where id = p_card;
  insert into public.card_files (card_id, deal_id, path, name, kind, uploaded_by, text_content)
  values (p_card, v_deal, p_path, p_name, p_kind, v_actor, nullif(btrim(coalesce(p_text, '')), ''));
  insert into public.card_history (card_id, actor, action) values (p_card, v_actor, 'Attached ' || p_name);
  if p_kind = 'export' and v_deal is not null then
    insert into public.deal_versions (deal_id, file_path, uploaded_by) values (v_deal, p_path, v_actor);
    update public.deals set export_path = p_path, exported_at = now() where id = v_deal;
    perform public.export_attached(v_deal, p_name);
    update public.cards set check_failed = false where id = p_card;
    if p_name ~* '\.pdf$' then
      insert into public.export_parse_jobs (deal_id, deal_number, path, file_name, source, card_id, uploaded_by)
      values (v_deal, substring(p_name from '^(\d{7})'), p_path, p_name, 'card', p_card, v_actor) returning id into v_job;
      perform public.run_export_parse(v_job);
    end if;
  end if;
end $function$;

-- who may call what
revoke all on function public.claim_export_job(bigint), public.fail_export_job(bigint, text), public.apply_export_details(bigint, jsonb),
  public.run_export_parse(bigint), public.kick_export_jobs() from public, anon, authenticated;
grant execute on function public.claim_export_job(bigint), public.fail_export_job(bigint, text), public.apply_export_details(bigint, jsonb)
  to service_role;
revoke all on function public.register_exports(jsonb), public.export_jobs_status(timestamptz), public.kick_export_jobs_ui() from public, anon;
grant execute on function public.register_exports(jsonb), public.export_jobs_status(timestamptz), public.kick_export_jobs_ui() to authenticated;
