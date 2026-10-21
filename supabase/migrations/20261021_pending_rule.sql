-- ============ Export reader: the "keep off the pending list" rules apply only to deals already published ============
-- A deal DIANA has found or drafted but not yet published is "not pending" by default. Its first exported report
-- (e.g. a new possible offer, status Proposed) now goes on the pending list as the report says. A published deal
-- that DIANA has closed (a lapsed possible offer, or a completed or failed deal) still stays off it.

create or replace function public.apply_export_details(p_job bigint, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  j public.export_parse_jobs; d public.deals; v_id uuid;
  c jsonb := coalesce(p_data -> 'cols', '{}'); pf jsonb := coalesce(p_data -> 'fields', '{}'); f jsonb;
  notes text[] := '{}'; v_status text; v_pending boolean; v_was_live boolean; v_value numeric; v_cur text; v_eur numeric;
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
  -- Both rules apply only to a deal that was already published (reported and LIVE): drafts and deals DIANA has only logged
  -- are "not pending" by default, so their first report decides.
  v_status := coalesce(c ->> 'deal_status', d.deal_status);
  v_pending := lower(coalesce(v_status, 'pending')) in ('pending', 'proposed');
  v_was_live := d.coverage_status = 'reported' and d.admin_state = 'LIVE';
  if v_was_live and not coalesce(d.is_pending, true) and lower(coalesce(c ->> 'deal_status', '')) = 'proposed' then
    v_pending := false;
  elsif v_was_live and lower(coalesce(d.deal_status, '')) in ('completed', 'failed') and lower(coalesce(c ->> 'deal_status', '')) = 'pending' then
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
