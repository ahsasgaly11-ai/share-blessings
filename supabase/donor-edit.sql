-- =====================================================================
-- أثر: تعديل التبرع من المتبرع بعد إرجاعه، وتعديله وحذفه من المشرفين
-- تحديث لمشروع قائم: الصق هذا الملف في SQL Editor ثم Run مرة واحدة. (مضمَّن أيضًا في setup.sql)
-- آمن للتشغيل أكثر من مرة.
-- =====================================================================
create or replace function public.sb_transition_ok(t text, a text, b text)
returns boolean language sql immutable as $$
  select b = any (case t || ':' || a
    when 'D:new'       then array['approved', 'rejected', 'cancelled']
    when 'D:approved'  then array['scheduled', 'rejected', 'cancelled', 'new']
    when 'D:scheduled' then array['received', 'rejected']
    when 'D:received'  then array['allocated', 'closed', 'delivered']
    when 'D:allocated' then array['delivered']
    when 'R:new'       then array['verified', 'rejected', 'cancelled']
    when 'R:verified'  then array['matched', 'rejected', 'cancelled']
    when 'R:matched'   then array['delivered']
    else array[]::text[] end)
$$;

create or replace function public.sb_public_view(r jsonb)
returns jsonb language sql immutable as $$
  select (r - 'photos' - 'geo' - 'mapUrl' - 'writeoffs' - 'person' - 'pickup' - 'matchedWith' - 'allocatedTo' - 'handover' - 'offer')
    || jsonb_build_object(
      'handover', case when r ? 'handover' then jsonb_build_object('date', r->'handover'->'date', 'slot', r->'handover'->'slot', 'state', r->'handover'->'state', 'place', r->'handover'->'place') else null end,
      'offer', case when r ? 'offer' then ((r->'offer') - 'from' - 'place')
        || case when r->'offer'->>'state' = 'accepted' then jsonb_build_object('place', r->'offer'->'place') else '{}'::jsonb end else null end,
      'phone', '****' || right(r->>'phone', 4),
      'allocations', coalesce((select jsonb_agg(jsonb_build_object('delivered', coalesce((a->>'delivered')::boolean, false)))
                               from jsonb_array_elements(coalesce(r->'allocations', '[]'::jsonb)) a), '[]'::jsonb),
      'pickup', case when r ? 'pickup' then jsonb_build_object('date', r->'pickup'->'date') else null end,
      'photoCount', coalesce(jsonb_array_length(r->'photos'), 0))
$$;

create or replace function public.owner_edit(p_code text, p_phone text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code)); changed text[] := '{}'; k text; i int; q numeric; items jsonb; ph jsonb; th jsonb; pl jsonb; ret boolean;
begin
  if octet_length(p::text) > 40000 then raise exception 'payload_too_large'; end if;
  if t like 'D-%' then select data into r from public.donations where id = t and phone = p_phone for update;
  elsif t like 'R-%' then select data into r from public.requests where id = t and phone = p_phone for update;
  end if;
  if r is null then raise exception 'not_found'; end if;
  if r->>'status' <> 'new' then raise exception 'not_allowed'; end if;
  if t like 'D-%' then
    if p ? 'slot' and p->>'slot' in ('morning', 'afternoon', 'evening') and p->>'slot' is distinct from r->>'slot' then r := jsonb_set(r, '{slot}', p->'slot'); changed := array_append(changed, 'slot'); end if;
    if p ? 'method' and p->>'method' in ('pickup', 'dropoff') and p->>'method' is distinct from r->>'method' then r := jsonb_set(r, '{method}', p->'method'); changed := array_append(changed, 'method'); end if;
    if jsonb_typeof(p->'qty') = 'array' then
      for i in 0 .. least(jsonb_array_length(p->'qty'), jsonb_array_length(r->'items')) - 1 loop
        q := (p->'qty'->>i)::numeric;
        if q is not null and q > 0 and q <= 100000 and q is distinct from (r->'items'->i->>'qty')::numeric then
          r := jsonb_set(r, array['items', i::text, 'qty'], to_jsonb(q)); changed := array_append(changed, 'qty');
        end if;
      end loop;
    end if;
    foreach k in array array['details', 'notes'] loop
      if p ? k and left(p->>k, 500) is distinct from coalesce(r->>k, '') then r := jsonb_set(r, array[k], to_jsonb(left(p->>k, 500))); changed := array_append(changed, k); end if;
    end loop;
    if p ? 'name' and char_length(trim(p->>'name')) between 3 and 80 and trim(p->>'name') is distinct from r->>'name' then
      r := jsonb_set(r, '{name}', to_jsonb(trim(p->>'name'))); changed := array_append(changed, 'name');
    end if;
    if jsonb_typeof(p->'addr') = 'object' then
      if coalesce(p->'addr'->>'zone', '') !~ '^[0-9]{1,2}$' or (p->'addr'->>'zone')::int not between 1 and 99
         or coalesce(p->'addr'->>'street', '') !~ '^[0-9]{1,4}$' or coalesce(p->'addr'->>'bldg', '') !~ '^[0-9]{1,4}$' then raise exception 'bad_addr'; end if;
      if jsonb_build_object('zone', p->'addr'->>'zone', 'street', p->'addr'->>'street', 'bldg', p->'addr'->>'bldg')
         is distinct from jsonb_build_object('zone', r->'addr'->>'zone', 'street', r->'addr'->>'street', 'bldg', r->'addr'->>'bldg') then
        r := jsonb_set(r - 'geo', '{addr}', jsonb_build_object('zone', p->'addr'->>'zone', 'street', p->'addr'->>'street', 'bldg', p->'addr'->>'bldg'));
        changed := array_append(changed, 'addr');
      end if;
    end if;
    -- the whole list of items, kept to the known fields
    if jsonb_typeof(p->'items') = 'array' then
      if jsonb_array_length(p->'items') not between 1 and 30
         or exists (select 1 from jsonb_array_elements(p->'items') x where coalesce(x->>'qty', '') !~ '^[0-9]{1,6}(\.[0-9]{1,2})?$' or (x->>'qty')::numeric <= 0) then raise exception 'bad_items'; end if;
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('type', left(x->>'type', 30), 'qty', (x->>'qty')::numeric, 'unit', left(x->>'unit', 10),
          'exp', left(x->>'exp', 10), 'cat', left(x->>'cat', 20), 'cond', left(x->>'cond', 20), 'size', left(x->>'size', 60), 'desc', left(x->>'desc', 200), 'age', left(x->>'age', 10))))
        into items from jsonb_array_elements(p->'items') x;
      if items is distinct from r->'items' then r := jsonb_set(r, '{items}', items); changed := array_append(changed, 'items'); end if;
    end if;
    -- photos: the ones to keep (by position) and new uploads with their small previews
    if jsonb_typeof(p->'keep') = 'array' then
      ph := '[]'::jsonb; th := '[]'::jsonb;
      for i in 0 .. coalesce(jsonb_array_length(r->'photos'), 0) - 1 loop
        if (p->'keep') @> to_jsonb(i) then ph := ph || jsonb_build_array(r->'photos'->i); th := th || jsonb_build_array(coalesce(r->'thumbs'->>i, '')); end if;
      end loop;
      if jsonb_typeof(coalesce(p->'add', '[]'::jsonb)) <> 'array'
         or exists (select 1 from jsonb_array_elements_text(coalesce(p->'add', '[]'::jsonb)) x where x !~ '^incoming/[0-9a-f-]{36}\.jpg$') then raise exception 'bad_photos'; end if;
      for i in 0 .. coalesce(jsonb_array_length(p->'add'), 0) - 1 loop
        ph := ph || jsonb_build_array(p->'add'->i);
        th := th || jsonb_build_array(case when coalesce(p->'addThumbs'->>i, '') ~ '^data:image/jpeg;base64,' and char_length(p->'addThumbs'->>i) < 8000 then p->'addThumbs'->>i else '' end);
      end loop;
      if jsonb_array_length(ph) > 4 then raise exception 'bad_photos'; end if;
      if ph is distinct from coalesce(r->'photos', '[]'::jsonb) then r := jsonb_set(jsonb_set(r, '{photos}', ph), '{thumbs}', th); changed := array_append(changed, 'photos'); end if;
    end if;
    -- where to collect, and whether the beneficiary may come in person
    if jsonb_typeof(p->'place') = 'object' and r->>'method' = 'pickup' then
      if p->'place'->>'type' = 'other' then
        if char_length(trim(coalesce(p->'place'->>'text', ''))) not between 4 and 200 then raise exception 'bad_place'; end if;
        pl := jsonb_build_object('type', 'other', 'text', trim(p->'place'->>'text'),
          'mapUrl', case when coalesce(p->'place'->>'mapUrl', '') ~* '^https?://' then left(p->'place'->>'mapUrl', 500) else '' end);
      else pl := '{"type":"home"}'::jsonb; end if;
      if pl is distinct from r->'place' then r := jsonb_set(r, '{place}', pl); changed := array_append(changed, 'place'); end if;
    end if;
    if jsonb_typeof(p->'direct') = 'boolean' and p->'direct' is distinct from r->'direct' then r := jsonb_set(r, '{direct}', p->'direct'); changed := array_append(changed, 'direct'); end if;
  else
    if p ? 'size' and (p->>'size') ~ '^[0-9]{1,4}$' and (p->>'size')::int >= 1 and (p->>'size')::int is distinct from (r->>'size')::int then r := jsonb_set(r, '{size}', to_jsonb((p->>'size')::int)); changed := array_append(changed, 'size'); end if;
    if p ? 'urg' and p->>'urg' in ('normal', 'high') and p->>'urg' is distinct from r->>'urg' then r := jsonb_set(r, '{urg}', p->'urg'); changed := array_append(changed, 'urg'); end if;
    foreach k in array array['details', 'notes', 'goodsDesc', 'sizes'] loop
      if p ? k and left(p->>k, 500) is distinct from coalesce(r->>k, '') then r := jsonb_set(r, array[k], to_jsonb(left(p->>k, 500))); changed := array_append(changed, k); end if;
    end loop;
  end if;
  if cardinality(changed) = 0 then return jsonb_build_object('unchanged', true); end if;
  -- the donor answered a supervisor's request for changes
  ret := r->'returned'->>'open' = 'true';
  if ret then r := jsonb_set(jsonb_set(r, '{returned,open}', 'false'), '{returned,doneAt}', to_jsonb(now())); end if;
  r := jsonb_set(r, '{edits}', coalesce(r->'edits', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'fields', to_jsonb(changed))));
  r := jsonb_set(r, '{_v}', to_jsonb(coalesce((r->>'_v')::int, 0) + 1));
  if t like 'D-%' then update public.donations set data = r where id = t; else update public.requests set data = r where id = t; end if;
  insert into public.activity_log (text, by) values (case when ret then 'عدّل المتبرع الطلب ' || t || ' بعد إرجاعه' else 'عدّل صاحب الطلب ' || t end, 'صاحب الطلب');
  return public.sb_public_view(r);
end $$;

drop policy if exists don_delete on public.donations;
create policy don_delete on public.donations for delete to authenticated using (public.sb_role() in ('admin', 'reviewer'));
drop policy if exists sb_photos_delete on storage.objects;
create policy sb_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'donation-photos' and public.sb_role() in ('admin', 'reviewer'));

notify pgrst, 'reload schema';
