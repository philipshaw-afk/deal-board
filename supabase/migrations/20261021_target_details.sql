-- ============ Target Details, and fixes to the export reader ============
-- 1. Deals get a Target Details field (the report's "Target Details" section), included in the DataBase word search.
-- 2. The DataBase deal page gets it from db_deal().
-- 3. apply_export_details(): fixes the "malformed array literal" note error; stores Target Details; a 'target' job
--    re-reads only Target Details from a deal's current PDF.
-- 4. The reader can ask the database to start the next reader (no more chains of readers waiting on each other).
-- 5. Re-queues the PDFs that failed on the note error and restarts the queue.
-- 6. A lapsed possible offer keeps the status "Proposed" (it is not reopened as pending).

alter table public.deals add column if not exists target_details text;

drop index if exists public.deals_fts_idx;
alter table public.deals drop column if exists fts;
alter table public.deals add column fts tsvector generated always as (
  to_tsvector('english', coalesce(target, '') || ' ' || coalesce(bidder, '') || ' ' || coalesce(seller, '') || ' ' ||
    coalesce(deal_number, '') || ' ' || coalesce(sector, '') || ' ' || coalesce(overview, '') || ' ' || coalesce(profiles, '') || ' ' ||
    coalesce(background, '') || ' ' || coalesce(financial_notes, '') || ' ' || coalesce(target_details, ''))) stored;
create index deals_fts_idx on public.deals using gin (fts);

alter table public.export_parse_jobs drop constraint if exists export_parse_jobs_mode_check;
alter table public.export_parse_jobs add constraint export_parse_jobs_mode_check check (mode in ('apply', 'debug', 'target'));

create or replace function public.db_deal(p_deal_number text)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare r jsonb;
begin
  if not public.db_can_read() then raise exception 'This login does not have access to the M&A DataBase' using errcode = '42501'; end if;
  select jsonb_build_object(
      'deal_number', d.deal_number, 'target', d.target, 'bidder', d.bidder, 'seller', d.seller,
      'target_country', d.target_country, 'bidder_country', d.bidder_country, 'seller_country', d.seller_country,
      'region', d.region, 'is_public', d.is_public, 'sector', d.sector, 'deal_type', d.deal_type, 'deal_status', d.deal_status,
      'value', d.value, 'currency', d.currency, 'value_eur', d.value_eur, 'date_announced', d.date_announced,
      'offer_price', d.offer_price, 'offer_currency', d.offer_currency, 'shares_in_issue', d.shares_in_issue,
      'key_dates', d.key_dates, 'overview', d.overview, 'profiles', d.profiles, 'background', d.background,
      'financial_notes', d.financial_notes, 'target_details', d.target_details,
      'fields', d.fields, 'pdf', d.export_path, 'updated', coalesce(d.exported_at, d.updated_at))
    into r
    from public.deals d
   where d.deal_number = p_deal_number and d.coverage_status = 'reported' and d.admin_state = 'LIVE' and d.export_path is not null;
  return jsonb_build_object('deal', r,
    'status', (select jsonb_build_object('as_of', s.as_of, 'data', s.data) from public.db_offer_status s where s.deal_no = p_deal_number),
    'events', coalesce((select jsonb_agg(jsonb_build_object('d', e.event_date, 'ty', e.kind, 'l', e.label, 'x', e.detail) order by e.event_date)
                          from public.db_offer_events e where e.deal_no = p_deal_number), '[]'::jsonb));
end $function$;

create or replace function public.apply_export_details(p_job bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  j public.export_parse_jobs; d public.deals; v_id uuid;
  c jsonb := coalesce(p_data -> 'cols', '{}'); pf jsonb := coalesce(p_data -> 'fields', '{}'); f jsonb;
  notes text[] := '{}'; v_status text; v_pending boolean; v_value numeric; v_cur text; v_eur numeric;
begin
  select * into j from public.export_parse_jobs where id = p_job;
  if j.id is null then return null; end if;

  -- a 'target' job only refreshes Target Details from the deal's current PDF
  if j.mode = 'target' then
    update public.deals set target_details = coalesce(p_data ->> 'target_details', target_details) where id = j.deal_id;
    update public.export_parse_jobs set status = 'done', finished_at = now(), error = null,
      result = jsonb_build_object('deal_id', j.deal_id, 'target_details', length(p_data ->> 'target_details')) where id = p_job;
    return jsonb_build_object('ok', true, 'deal_id', j.deal_id);
  end if;

  v_id := j.deal_id;
  if v_id is null and j.deal_number is not null then
    select id into v_id from public.deals where deal_number = j.deal_number;
    if v_id is null then
      v_id := public.link_deal_number(j.deal_number, c ->> 'target', c ->> 'bidder');
      if v_id is not null then notes := notes || 'numbered the deal DIANA had found'::text; end if;
    end if;
    if v_id is null then
      insert into public.deals (deal_number, target, coverage_status, admin_state, deal_status, is_pending, date_found)
      values (j.deal_number, coalesce(c ->> 'target', j.file_name), 'reported', 'LIVE', coalesce(c ->> 'deal_status', 'Pending'),
              coalesce((c ->> 'is_pending')::boolean, true), current_date)
      returning id into v_id;
      notes := notes || 'new deal added'::text;
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

  -- status. A possible offer that lapses keeps the status "Proposed" (M&A Monitor's convention), so an export saying
  -- Proposed is taken as it is; but a deal DIANA has closed stays off the pending list. A deal DIANA knows has completed
  -- or failed is not reopened by an export that still says Pending (the report is waiting to be updated).
  v_status := coalesce(c ->> 'deal_status', d.deal_status);
  v_pending := lower(coalesce(v_status, 'pending')) in ('pending', 'proposed');
  if not coalesce(d.is_pending, true) and lower(coalesce(c ->> 'deal_status', '')) = 'proposed' and d.deal_number is not null then
    v_pending := false;
  elsif lower(coalesce(d.deal_status, '')) in ('completed', 'failed') and lower(coalesce(c ->> 'deal_status', '')) = 'pending' then
    notes := notes || ('kept ' || d.deal_status || ': the report still says ' || (c ->> 'deal_status'))::text;
    v_status := d.deal_status; v_pending := false;
  end if;

  -- fields: the PDF's values win; a fuller consideration wording already held is kept
  f := coalesce(d.fields, '{}') || pf;
  if d.fields ? 'Consideration type' and pf ? 'Consideration type'
     and lower(d.fields ->> 'Consideration type') like lower(pf ->> 'Consideration type') || ' plus %' then
    f := jsonb_set(f, '{Consideration type}', d.fields -> 'Consideration type');
  end if;
  if coalesce(d.deal_number, j.deal_number) is not null then f := f || jsonb_build_object('Deal Number', coalesce(d.deal_number, j.deal_number)); end if;

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
    is_pending = v_pending,
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
    target_details = coalesce(p_data ->> 'target_details', target_details),
    fields = f,
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

-- the reader starts the next one through the database
grant execute on function public.kick_export_jobs() to service_role;

-- re-run the three PDFs that hit the note error, free the stuck ones, and restart the queue
update public.export_parse_jobs set status = 'queued', attempts = 0, error = null, started_at = null, finished_at = null
 where status = 'failed' and error like 'malformed array literal%';
update public.export_parse_jobs set status = 'queued', started_at = null
 where status = 'running' and started_at < now() - interval '1 minute';
select public.kick_export_jobs();
