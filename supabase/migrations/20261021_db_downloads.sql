-- ============ DataBase site: Excel downloads (transaction multiples, bid premia) ============
-- db_export_rows() gives a signed-in DataBase reader the full figures behind each deal report (target financials,
-- multiples, bid premia, key dates) for the deals they have selected on the Search Results page. Read-only.

create or replace function public.db_export_rows(p_numbers text[])
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
begin
  if not public.db_can_read() then raise exception 'This login does not have access to the M&A DataBase' using errcode = '42501'; end if;
  if coalesce(array_length(p_numbers, 1), 0) > 5000 then raise exception 'Too many deals in one download (5,000 at most)'; end if;
  return coalesce((
    select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'n', d.deal_number, 't', d.target, 'b', d.bidder, 's', d.seller,
        'tc', d.target_country, 'bc', d.bidder_country, 'sc', d.seller_country,
        'sec', d.sector, 'ty', d.deal_type, 'st', d.deal_status, 'da', d.date_announced,
        'kd', d.key_dates,
        'f', coalesce(d.fields, '{}'::jsonb) - 'added_by' - 'admin_id' - 'value_note')))
      from public.deals d
     where d.deal_number = any(p_numbers)
       and d.coverage_status = 'reported' and d.admin_state = 'LIVE' and d.export_path is not null), '[]'::jsonb);
end $function$;

revoke all on function public.db_export_rows(text[]) from public, anon;
grant execute on function public.db_export_rows(text[]) to authenticated;
