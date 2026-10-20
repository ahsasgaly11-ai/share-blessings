-- =====================================================================
-- أثر: التسليم المباشر من المتبرع إلى المستفيد دون متطوع
-- تحديث لمشروع قائم: الصق هذا الملف في SQL Editor ثم Run مرة واحدة. (مضمَّن أيضًا في setup.sql)
-- آمن للتشغيل أكثر من مرة.
-- =====================================================================
-- التسليم المباشر: يستلم المستفيد التبرع من المتبرع دون متطوع ودون المرور بالمستودع.
create or replace function public.sb_handover_ok(rid text, a text, b text, d jsonb)
returns boolean language sql immutable as $$
  select case left(rid, 1)
    when 'D' then a = 'scheduled' and ((b = 'delivered' and d->'handover'->>'state' = 'done') or (b = 'approved' and d->'handover'->>'state' = 'noshow'))
    when 'R' then a = 'matched' and b = 'verified' and d->'offer'->>'state' in ('noshow', 'withdrawn')
    else false end
$$;

create or replace function public.sb_sync_columns()
returns trigger language plpgsql as $$
begin
  new.data       := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  new.phone      := coalesce(new.data->>'phone', '');
  new.status     := coalesce(new.data->>'status', 'new');
  new.kind       := coalesce(new.data->>'kind', '');
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    if new.id <> old.id then raise exception 'id is immutable'; end if;
    -- المدير وحده يمكنه تجاوز المسار، وذلك لاستعادة نسخة احتياطية
    if new.status <> old.status and coalesce(public.sb_role(), '') <> 'admin'
       and not public.sb_transition_ok(left(new.id, 1), old.status, new.status)
       and not public.sb_handover_ok(new.id, old.status, new.status, new.data) then
      raise exception 'invalid status transition: % -> %', old.status, new.status;
    end if;
  end if;
  return new;
end $$;

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
      'pickup', case when r ? 'pickup' then jsonb_build_object('date', r->'pickup'->'date') else null end)
$$;

create or replace function public.owner_respond(p_code text, p_phone text, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; d jsonb; t text := upper(trim(p_code)); did text; st text;
begin
  select data into r from public.requests where id = t and phone = p_phone for update;
  if r is null then raise exception 'not_found'; end if;
  if r->'offer'->>'state' is distinct from 'offered' or r->>'status' <> 'verified' then raise exception 'not_allowed'; end if;
  did := r->'offer'->>'from';
  select data into d from public.donations where id = did for update;
  if d is null or d->>'status' <> 'approved' or d->'handover'->>'to' is distinct from t or d->'handover'->>'state' is distinct from 'offered' then
    raise exception 'offer_gone';
  end if;
  st := case when p_accept then 'accepted' else 'declined' end;
  r := jsonb_set(jsonb_set(r, '{offer,state}', to_jsonb(st)), '{offer,answeredAt}', to_jsonb(now()));
  d := jsonb_set(jsonb_set(d, '{handover,state}', to_jsonb(st)), '{handover,answeredAt}', to_jsonb(now()));
  if p_accept then
    r := jsonb_set(r, '{status}', '"matched"');
    r := jsonb_set(r, '{history}', coalesce(r->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('status', 'matched', 'at', now(), 'note', 'أكّد حضوره لاستلام التبرع')));
    d := jsonb_set(d, '{status}', '"scheduled"');
    d := jsonb_set(d, '{pickup}', jsonb_build_object('date', d->'handover'->'date', 'vol', 'المستفيد', 'volId', null, 'direct', true));
    d := jsonb_set(d, '{history}', coalesce(d->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('status', 'scheduled', 'at', now(), 'note', 'أكّد المستفيد حضوره')));
  end if;
  r := jsonb_set(r, '{_v}', to_jsonb(coalesce((r->>'_v')::int, 0) + 1));
  d := jsonb_set(d, '{_v}', to_jsonb(coalesce((d->>'_v')::int, 0) + 1));
  update public.requests set data = r where id = t;
  update public.donations set data = d where id = did;
  insert into public.activity_log (text, by) values (case when p_accept then 'وافق المستفيد ' || t || ' على موعد استلام ' || did else 'اعتذر المستفيد ' || t || ' عن موعد استلام ' || did end, 'صاحب الطلب');
  return public.sb_public_view(r);
end $$;
revoke all on function public.owner_respond(text, text, boolean) from public;
grant execute on function public.owner_respond(text, text, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
