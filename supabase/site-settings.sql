-- =====================================================================
-- أثر: إعدادات الموقع من لوحة المشرفين
-- ينشئ جدول الإعدادات (التواصل، الإعلان، الحملات، المناطق، النصوص...)،
-- ودالة تقدّم الحملات، ويجعل الخادم يرفض التبرعات والطلبات عند إيقاف الاستقبال.
-- آمن للتشغيل أكثر من مرة. (مضمَّن أيضًا في setup.sql)
-- =====================================================================
-- ---------- إعدادات الموقع (يعدّلها المدير من تبويب «إعدادات الموقع») ----------
create table if not exists public.site_config (
  id smallint primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
insert into public.site_config (id) values (1) on conflict (id) do nothing;
alter table public.site_config enable row level security;
drop policy if exists cfg_read on public.site_config;
create policy cfg_read on public.site_config for select to anon, authenticated using (true);
drop policy if exists cfg_write on public.site_config;
create policy cfg_write on public.site_config for update to authenticated
  using (public.sb_role() = 'admin') with check (public.sb_role() = 'admin');
revoke all on public.site_config from anon, authenticated;
grant select on public.site_config to anon, authenticated;
grant update (data, updated_at) on public.site_config to authenticated;

-- تقدّم كل حملة: مجموع كميات التبرعات غير المرفوضة لنوعها وأصنافها (الغذاء بالكيلوغرام فقط)
create or replace function public.campaign_progress()
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (
    select x from public.site_config s, jsonb_array_elements(coalesce(s.data->'campaigns', '[]'::jsonb)) x where s.id = 1),
  it as (
    select d.kind, i from public.donations d, jsonb_array_elements(d.data->'items') i where d.status not in ('rejected', 'cancelled'))
  select coalesce(jsonb_object_agg(c.x->>'id', (
    select coalesce(sum((it.i->>'qty')::numeric), 0) from it
     where it.kind = c.x->>'kind'
       and (jsonb_array_length(coalesce(c.x->'types', '[]'::jsonb)) = 0 or (c.x->'types') ? (it.i->>'type'))
       and (it.kind <> 'food' or it.i->>'unit' = 'kg'))), '{}'::jsonb)
  from c
$$;
revoke all on function public.campaign_progress() from public;
grant execute on function public.campaign_progress() to anon, authenticated;

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
  v_id := 'D-' || nextval('public.donation_seq');
  v := (p - 'id' - 'status' - 'history' - 'allocations' - 'edits' - 'pickup' - 'writeoffs' - '_v' - 'createdAt')
       || jsonb_build_object('id', v_id, 'status', 'new', 'photos', v_photos,
            'history', jsonb_build_array(jsonb_build_object('status', 'new', 'at', now(), 'note', '')),
            'createdAt', now(), 'allocations', '[]'::jsonb, '_v', 1);
  insert into public.donations (id, phone, status, kind, data) values (v_id, p->>'phone', 'new', p->>'kind', v);
  insert into public.activity_log (text, by) values ('تبرع جديد ' || v_id || ' من ' || left(p->>'name', 80), left(p->>'name', 80));
  return jsonb_build_object('id', v_id, 'createdAt', now());
end $$;

create or replace function public.submit_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text; v jsonb; d record;
begin
  if coalesce((select data->'intake'->>'requests' from public.site_config where id = 1), 'true') = 'false' then raise exception 'intake_closed'; end if;
  if octet_length(p::text) > 20000 then raise exception 'payload_too_large'; end if;
  if coalesce(p->>'phone', '') !~ '^[34567][0-9]{7}$' then raise exception 'bad_phone'; end if;
  if char_length(coalesce(p->>'name', '')) not between 3 and 80 then raise exception 'bad_name'; end if;
  if coalesce(p->>'kind', '') not in ('food', 'clothes', 'elec', 'furn', 'other') then raise exception 'bad_kind'; end if;
  if coalesce(p->>'size', '') !~ '^[0-9]{1,4}$' or (p->>'size')::int < 1 then raise exception 'bad_size'; end if;
  -- طلب مفتوح من نفس الهاتف ونفس النوع: لا نسجّل طلبًا جديدًا
  select id, status into d from public.requests
   where phone = p->>'phone' and kind = p->>'kind' and status not in ('delivered', 'rejected', 'cancelled') limit 1;
  if found then return jsonb_build_object('duplicate', true, 'id', d.id, 'status', d.status); end if;
  v_id := 'R-' || nextval('public.request_seq');
  v := (p - 'id' - 'status' - 'history' - 'edits' - 'matchedWith' - '_v' - 'createdAt')
       || jsonb_build_object('id', v_id, 'status', 'new', 'size', (p->>'size')::int,
            'history', jsonb_build_array(jsonb_build_object('status', 'new', 'at', now(), 'note', '')),
            'createdAt', now(), '_v', 1);
  insert into public.requests (id, phone, status, kind, data) values (v_id, p->>'phone', 'new', p->>'kind', v);
  insert into public.activity_log (text, by) values ('طلب احتياج جديد ' || v_id, left(p->>'name', 80));
  return jsonb_build_object('id', v_id, 'createdAt', now());
end $$;

notify pgrst, 'reload schema';
