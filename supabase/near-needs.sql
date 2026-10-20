-- =====================================================================
-- أثر: «نعمة الجيران» و«أمنيات مجهولة»
-- تحديث لمشروع قائم: الصق هذا الملف في SQL Editor ثم Run مرة واحدة. (مضمَّن أيضًا في setup.sql)
-- - دالة public_needs: الاحتياجات المتحقَّق منها حسب رقم المنطقة، والأمنيات التي نشرها المشرفون.
-- - submit_donation: يقبل رقم الأمنية التي يلبّيها المتبرع.
-- آمن للتشغيل أكثر من مرة.
-- =====================================================================
create or replace function public.submit_donation(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text; v jsonb; v_photos jsonb := coalesce(p->'photos', '[]'::jsonb);
begin
  if coalesce((select data->'intake'->>'donations' from public.site_config where id = 1), 'true') = 'false' then raise exception 'intake_closed'; end if;
  if coalesce((select data->'kinds'->>(p->>'kind') from public.site_config where id = 1), 'true') = 'false' then raise exception 'kind_closed'; end if;
  if octet_length(p::text) > 30000 then raise exception 'payload_too_large'; end if;
  if coalesce(p->>'phone', '') !~ '^[34567][0-9]{7}$' then raise exception 'bad_phone'; end if;
  if char_length(coalesce(p->>'name', '')) not between 3 and 80 then raise exception 'bad_name'; end if;
  if coalesce(p->>'kind', '') not in ('food', 'clothes', 'elec', 'furn', 'other') then raise exception 'bad_kind'; end if;
  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') not between 1 and 30 then raise exception 'bad_items'; end if;
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 4
     or exists (select 1 from jsonb_array_elements_text(v_photos) x where x !~ '^incoming/[0-9a-f-]{36}\.jpg$') then
    raise exception 'bad_photos';
  end if;
  -- تبرع يلبّي أمنية مجهولة: رقم الطلب فقط، وأي قيمة أخرى تُهمل
  if p ? 'wish' and (coalesce(p->>'wish', '') !~ '^R-[0-9]{1,9}$'
     or not exists (select 1 from public.requests where id = p->>'wish' and status = 'verified')) then p := p - 'wish'; end if;
  v_id := 'D-' || nextval('public.donation_seq');
  v := (p - 'id' - 'status' - 'history' - 'allocations' - 'edits' - 'pickup' - 'writeoffs' - '_v' - 'createdAt')
       || jsonb_build_object('id', v_id, 'status', 'new', 'photos', v_photos,
            'history', jsonb_build_array(jsonb_build_object('status', 'new', 'at', now(), 'note', '')),
            'createdAt', now(), 'allocations', '[]'::jsonb, '_v', 1);
  insert into public.donations (id, phone, status, kind, data) values (v_id, p->>'phone', 'new', p->>'kind', v);
  insert into public.activity_log (text, by) values ('تبرع جديد ' || v_id || ' من ' || left(p->>'name', 80), left(p->>'name', 80));
  return jsonb_build_object('id', v_id, 'createdAt', now());
end $$;

-- ---------- نعمة الجيران والأمنيات المجهولة ----------
-- ما يراه الزائر: عدد الاحتياجات المتحقَّق منها في كل منطقة (رقم المنطقة من اللوحة فقط)،
-- والأمنيات التي نشرها مشرف بنص كتبه بنفسه. لا أسماء ولا هواتف ولا شوارع ولا مبانٍ.
create or replace function public.public_needs()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'zones', coalesce((select jsonb_agg(jsonb_build_object('z', z, 'k', kind, 'n', n)) from (
        select (data->'addr'->>'zone')::int as z, kind, count(*) as n from public.requests
         where status = 'verified' and coalesce(data->'addr'->>'zone', '') ~ '^[0-9]{1,2}$'
         group by 1, 2) s), '[]'::jsonb),
    'wishes', coalesce((select jsonb_agg(w order by w->>'urg' = 'high' desc, w->>'at') from (
        select jsonb_build_object(
          'id', r.id, 'z', (r.data->'addr'->>'zone')::int, 'k', r.kind, 't', r.data->>'type',
          'text', left(r.data->'wish'->>'text', 160), 'tr', coalesce(r.data->'wish'->'tr', '{}'::jsonb),
          'lang', r.data->'wish'->>'lang', 'preset', r.data->'wish'->>'preset', 'size', (r.data->>'size')::int, 'urg', r.data->>'urg', 'at', r.data->'wish'->>'at',
          'taken', exists (select 1 from public.donations d where d.data->>'wish' = r.id and d.status not in ('rejected', 'cancelled'))) as w
          from public.requests r
         where r.status = 'verified' and r.data->'wish'->>'on' = 'true' and coalesce(r.data->'wish'->>'text', '') <> ''
           and coalesce(r.data->'addr'->>'zone', '') ~ '^[0-9]{1,2}$'
         order by r.created_at limit 60) x), '[]'::jsonb))
$$;
revoke all on function public.public_needs() from public;
grant execute on function public.public_needs() to anon, authenticated;

notify pgrst, 'reload schema';
