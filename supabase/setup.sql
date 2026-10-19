-- =====================================================================
-- شارك النعم: إعداد قاعدة البيانات في Supabase
-- الصق هذا الملف كاملًا في SQL Editor داخل مشروعك ثم اضغط Run.
-- يمكن تشغيله أكثر من مرة بأمان (لا يحذف بيانات موجودة).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- أرقام الطلبات: تولّدها قاعدة البيانات فلا تتكرر ----------
create sequence if not exists public.donation_seq start 1001;
create sequence if not exists public.request_seq start 2001;

-- ---------- الجداول ----------
-- كل سجل يُحفظ كاملًا في العمود data، وتُنسخ منه الحقول التي نحتاجها للفرز والصلاحيات.
create table if not exists public.donations (
  id          text primary key,
  phone       text not null,
  status      text not null,
  kind        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  data        jsonb not null
);
create table if not exists public.requests (
  id          text primary key,
  phone       text not null,
  status      text not null,
  kind        text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  data        jsonb not null
);
create index if not exists donations_phone_idx  on public.donations (phone);
create index if not exists donations_status_idx on public.donations (status);
create index if not exists requests_phone_idx   on public.requests (phone);
create index if not exists requests_status_idx  on public.requests (status);

-- فريق العمل: كل عضو حساب في Supabase Auth مع دور واحد
create table if not exists public.staff (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  name       text not null,
  role       text not null check (role in ('admin', 'reviewer', 'volunteer')),
  email      text,
  created_at timestamptz not null default now()
);

create table if not exists public.activity_log (
  id    bigint generated always as identity primary key,
  at    timestamptz not null default now(),
  text  text not null,
  by    text
);

-- ---------- دوال مساعدة للصلاحيات ----------
create or replace function public.sb_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.staff where user_id = auth.uid()
$$;

-- يرى المتطوع التبرع إذا كان مسندًا إليه استلامه، أو توصيل جزء منه لم يُسلَّم بعد
create or replace function public.sb_vol_assigned(d jsonb)
returns boolean language sql stable as $$
  select auth.uid() is not null and (
    (d->>'status' = 'scheduled' and d->'pickup'->>'volId' = auth.uid()::text)
    or exists (
      select 1 from jsonb_array_elements(coalesce(d->'allocations', '[]'::jsonb)) a
      where a->>'volId' = auth.uid()::text and coalesce((a->>'delivered')::boolean, false) = false))
$$;

-- ويبقى يرى التبرعات التي تولّاها سابقًا (سجل مهامه)، لكنه لا يعدّل إلا المسندة إليه حاليًا
create or replace function public.sb_vol_related(d jsonb)
returns boolean language sql stable as $$
  select auth.uid() is not null and (
    d->'pickup'->>'volId' = auth.uid()::text
    or exists (select 1 from jsonb_array_elements(coalesce(d->'allocations', '[]'::jsonb)) a where a->>'volId' = auth.uid()::text))
$$;

-- ويرى طلب المستفيد الذي يوصل إليه جزءًا لم يُسلَّم بعد
create or replace function public.sb_vol_request(rid text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.donations d, jsonb_array_elements(coalesce(d.data->'allocations', '[]'::jsonb)) a
    where a->>'to' = rid and a->>'volId' = auth.uid()::text and coalesce((a->>'delivered')::boolean, false) = false)
$$;

-- ---------- مسار الحالات: لا يمكن تخطي أي خطوة اعتماد ----------
create or replace function public.sb_transition_ok(t text, a text, b text)
returns boolean language sql immutable as $$
  select b = any (case t || ':' || a
    when 'D:new'       then array['approved', 'rejected', 'cancelled']
    when 'D:approved'  then array['scheduled', 'rejected', 'cancelled']
    when 'D:scheduled' then array['received', 'rejected']
    when 'D:received'  then array['allocated', 'closed', 'delivered']
    when 'D:allocated' then array['delivered']
    when 'R:new'       then array['verified', 'rejected', 'cancelled']
    when 'R:verified'  then array['matched', 'rejected', 'cancelled']
    when 'R:matched'   then array['delivered']
    else array[]::text[] end)
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
       and not public.sb_transition_ok(left(new.id, 1), old.status, new.status) then
      raise exception 'invalid status transition: % -> %', old.status, new.status;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists donations_sync on public.donations;
create trigger donations_sync before insert or update on public.donations for each row execute function public.sb_sync_columns();
drop trigger if exists requests_sync on public.requests;
create trigger requests_sync before insert or update on public.requests for each row execute function public.sb_sync_columns();

-- ---------- أمان الصفوف (RLS) ----------
alter table public.donations    enable row level security;
alter table public.requests     enable row level security;
alter table public.staff        enable row level security;
alter table public.activity_log enable row level security;

drop policy if exists don_select on public.donations;
drop policy if exists don_update on public.donations;
drop policy if exists don_insert on public.donations;
drop policy if exists don_delete on public.donations;
create policy don_select on public.donations for select to authenticated
  using (public.sb_role() in ('admin', 'reviewer') or (public.sb_role() = 'volunteer' and public.sb_vol_related(data)));
create policy don_update on public.donations for update to authenticated
  using (public.sb_role() in ('admin', 'reviewer') or (public.sb_role() = 'volunteer' and public.sb_vol_assigned(data)))
  with check (public.sb_role() in ('admin', 'reviewer', 'volunteer'));
create policy don_insert on public.donations for insert to authenticated with check (public.sb_role() = 'admin');
create policy don_delete on public.donations for delete to authenticated using (public.sb_role() = 'admin');

drop policy if exists req_select on public.requests;
drop policy if exists req_update on public.requests;
drop policy if exists req_insert on public.requests;
drop policy if exists req_delete on public.requests;
create policy req_select on public.requests for select to authenticated
  using (public.sb_role() in ('admin', 'reviewer') or (public.sb_role() = 'volunteer' and public.sb_vol_request(id)));
create policy req_update on public.requests for update to authenticated
  using (public.sb_role() in ('admin', 'reviewer')) with check (public.sb_role() in ('admin', 'reviewer'));
create policy req_insert on public.requests for insert to authenticated with check (public.sb_role() = 'admin');
create policy req_delete on public.requests for delete to authenticated using (public.sb_role() = 'admin');

drop policy if exists staff_select on public.staff;
create policy staff_select on public.staff for select to authenticated using (public.sb_role() is not null);

drop policy if exists log_select on public.activity_log;
drop policy if exists log_insert on public.activity_log;
create policy log_select on public.activity_log for select to authenticated using (public.sb_role() in ('admin', 'reviewer'));
create policy log_insert on public.activity_log for insert to authenticated with check (public.sb_role() is not null);

revoke all on public.donations, public.requests, public.staff, public.activity_log from anon;
grant select, insert, update, delete on public.donations, public.requests to authenticated;
grant select on public.staff to authenticated;
grant select, insert on public.activity_log to authenticated;

-- ---------- ما يراه صاحب الطلب: بياناته فقط، دون الصور أو أسماء المستفيدين ----------
create or replace function public.sb_public_view(r jsonb)
returns jsonb language sql immutable as $$
  select (r - 'photos' - 'geo' - 'mapUrl' - 'writeoffs' - 'person' - 'pickup' - 'matchedWith' - 'allocatedTo')
    || jsonb_build_object(
      'phone', '****' || right(r->>'phone', 4),
      'allocations', coalesce((select jsonb_agg(jsonb_build_object('delivered', coalesce((a->>'delivered')::boolean, false)))
                               from jsonb_array_elements(coalesce(r->'allocations', '[]'::jsonb)) a), '[]'::jsonb),
      'pickup', case when r ? 'pickup' then jsonb_build_object('date', r->'pickup'->'date') else null end)
$$;

-- ---------- دوال عامة (للزوار) ----------
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

create or replace function public.track(p_code text, p_last4 text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code));
begin
  if coalesce(p_last4, '') !~ '^[0-9]{4}$' then return null; end if;
  if t like 'D-%' then select data into r from public.donations where id = t and right(phone, 4) = p_last4;
  elsif t like 'R-%' then select data into r from public.requests where id = t and right(phone, 4) = p_last4;
  end if;
  return case when r is null then null else public.sb_public_view(r) end;
end $$;

create or replace function public.owner_cancel(p_code text, p_phone text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code)); allowed text[];
begin
  if t like 'D-%' then select data into r from public.donations where id = t and phone = p_phone for update; allowed := array['new', 'approved'];
  elsif t like 'R-%' then select data into r from public.requests where id = t and phone = p_phone for update; allowed := array['new', 'verified'];
  end if;
  if r is null then raise exception 'not_found'; end if;
  if not (r->>'status' = any (allowed)) then raise exception 'not_allowed'; end if;
  r := jsonb_set(r, '{status}', '"cancelled"');
  r := jsonb_set(r, '{history}', coalesce(r->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('status', 'cancelled', 'at', now(), 'note', left(coalesce(p_reason, ''), 120))));
  r := jsonb_set(r, '{_v}', to_jsonb(coalesce((r->>'_v')::int, 0) + 1));
  if t like 'D-%' then update public.donations set data = r where id = t; else update public.requests set data = r where id = t; end if;
  insert into public.activity_log (text, by) values ('ألغى صاحب الطلب ' || t || ': ' || left(coalesce(p_reason, ''), 120), 'صاحب الطلب');
  return public.sb_public_view(r);
end $$;

create or replace function public.owner_edit(p_code text, p_phone text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code)); changed text[] := '{}'; k text; i int; q numeric;
begin
  if octet_length(p::text) > 5000 then raise exception 'payload_too_large'; end if;
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
  else
    if p ? 'size' and (p->>'size') ~ '^[0-9]{1,4}$' and (p->>'size')::int >= 1 and (p->>'size')::int is distinct from (r->>'size')::int then r := jsonb_set(r, '{size}', to_jsonb((p->>'size')::int)); changed := array_append(changed, 'size'); end if;
    if p ? 'urg' and p->>'urg' in ('normal', 'high') and p->>'urg' is distinct from r->>'urg' then r := jsonb_set(r, '{urg}', p->'urg'); changed := array_append(changed, 'urg'); end if;
    foreach k in array array['details', 'notes', 'goodsDesc', 'sizes'] loop
      if p ? k and left(p->>k, 500) is distinct from coalesce(r->>k, '') then r := jsonb_set(r, array[k], to_jsonb(left(p->>k, 500))); changed := array_append(changed, k); end if;
    end loop;
  end if;
  if cardinality(changed) = 0 then return jsonb_build_object('unchanged', true); end if;
  r := jsonb_set(r, '{edits}', coalesce(r->'edits', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('at', now(), 'fields', to_jsonb(changed))));
  r := jsonb_set(r, '{_v}', to_jsonb(coalesce((r->>'_v')::int, 0) + 1));
  if t like 'D-%' then update public.donations set data = r where id = t; else update public.requests set data = r where id = t; end if;
  insert into public.activity_log (text, by) values ('عدّل صاحب الطلب ' || t, 'صاحب الطلب');
  return public.sb_public_view(r);
end $$;

-- سجل المتبرع: يتطلب الهاتف ورقم أحد تبرعاته
create or replace function public.donor_history(p_phone text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ok boolean;
begin
  select exists (select 1 from public.donations where id = upper(trim(p_code)) and phone = p_phone) into ok;
  if not ok then return null; end if;
  return jsonb_build_object(
    'name', (select data->>'name' from public.donations where phone = p_phone order by created_at desc limit 1),
    'families', (select count(distinct case when a->>'to' = '__target' then d.id else a->>'to' end)
                   from public.donations d, jsonb_array_elements(coalesce(d.data->'allocations', '[]'::jsonb)) a
                  where d.phone = p_phone and coalesce((a->>'delivered')::boolean, false)),
    'donations', coalesce((select jsonb_agg(public.sb_public_view(data) order by created_at desc) from public.donations where phone = p_phone), '[]'::jsonb));
end $$;

-- أرقام الأثر والحملات في الصفحة الرئيسية
create or replace function public.public_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  with it as (
    select d.status, d.kind, d.phone, i
      from public.donations d, jsonb_array_elements(d.data->'items') i)
  select jsonb_build_object(
    'kg',  coalesce((select sum((i->>'qty')::numeric) from it where kind = 'food' and i->>'unit' = 'kg' and status in ('received', 'allocated', 'delivered')), 0),
    'pcs', coalesce((select sum((i->>'qty')::numeric) from it where kind = 'clothes' and status in ('received', 'allocated', 'delivered')), 0),
    'fam', coalesce((select sum((data->>'size')::int) from public.requests where status = 'delivered'), 0),
    'donors', (select count(distinct phone) from public.donations where status <> 'rejected'),
    'winter', coalesce((select sum((i->>'qty')::numeric) from it where kind = 'clothes' and i->>'type' = 'winter' and status not in ('rejected', 'cancelled')), 0),
    'ramadan', coalesce((select sum((i->>'qty')::numeric) from it where kind = 'food' and i->>'unit' = 'kg' and i->>'type' in ('rice', 'flour', 'legumes', 'sugar') and status not in ('rejected', 'cancelled')), 0),
    'dates', coalesce((select sum((i->>'qty')::numeric) from it where kind = 'food' and i->>'unit' = 'kg' and i->>'type' = 'dates' and status not in ('rejected', 'cancelled')), 0))
$$;

-- رابط إبقاء المشروع نشطًا (تستدعيه خدمة جدولة يوميًا حتى لا يتوقف المشروع المجاني)
create or replace function public.ping(apikey text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true, 'donations', (select count(*) from public.donations), 'at', now())
$$;
revoke all on function public.ping(text) from public;
grant execute on function public.ping(text) to anon, authenticated;

-- ---------- دوال الفريق ----------
-- أول من يسجّل دخوله بعد الإعداد يصبح المدير، ثم تتوقف هذه الدالة عن العمل
create or replace function public.claim_first_admin(p_name text)
returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if exists (select 1 from public.staff) then return 'exists'; end if;
  insert into public.staff (user_id, name, role, email) values (auth.uid(), left(p_name, 80), 'admin', (select email from auth.users where id = auth.uid()));
  return 'ok';
end $$;

create or replace function public.add_staff(p_email text, p_name text, p_role text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid;
begin
  if public.sb_role() is distinct from 'admin' then raise exception 'not_allowed'; end if;
  if p_role not in ('admin', 'reviewer', 'volunteer') then raise exception 'bad_role'; end if;
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then return 'no_user'; end if;
  insert into public.staff (user_id, name, role, email) values (v_uid, left(p_name, 80), p_role, lower(trim(p_email)))
    on conflict (user_id) do update set name = excluded.name, role = excluded.role, email = excluded.email;
  return 'ok';
end $$;

create or replace function public.remove_staff(p_uid uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if public.sb_role() is distinct from 'admin' then raise exception 'not_allowed'; end if;
  if p_uid = auth.uid() then raise exception 'cannot_remove_self'; end if;
  delete from public.staff where user_id = p_uid;
  return 'ok';
end $$;

-- ---------- صلاحيات تشغيل الدوال ----------
revoke all on function public.submit_donation(jsonb), public.submit_request(jsonb), public.track(text, text),
  public.owner_cancel(text, text, text), public.owner_edit(text, text, jsonb), public.donor_history(text, text),
  public.public_stats(), public.claim_first_admin(text), public.add_staff(text, text, text), public.remove_staff(uuid),
  public.sb_role(), public.sb_vol_request(text) from public;
grant execute on function public.submit_donation(jsonb), public.submit_request(jsonb), public.track(text, text),
  public.owner_cancel(text, text, text), public.owner_edit(text, text, jsonb), public.donor_history(text, text),
  public.public_stats() to anon, authenticated;
revoke execute on function public.claim_first_admin(text), public.add_staff(text, text, text), public.remove_staff(uuid),
  public.sb_role(), public.sb_vol_request(text) from anon;
grant execute on function public.claim_first_admin(text), public.add_staff(text, text, text), public.remove_staff(uuid),
  public.sb_role(), public.sb_vol_request(text) to authenticated;

-- ---------- تخزين الصور: خاص، لا يقرؤه إلا الفريق ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('donation-photos', 'donation-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists sb_photos_upload on storage.objects;
drop policy if exists sb_photos_read   on storage.objects;
drop policy if exists sb_photos_delete on storage.objects;
create policy sb_photos_upload on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'donation-photos' and (storage.foldername(name))[1] = 'incoming');
create policy sb_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'donation-photos' and public.sb_role() is not null);
create policy sb_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'donation-photos' and public.sb_role() = 'admin');

-- تحديث ذاكرة واجهة البرمجة لتظهر الدوال الجديدة فورًا
-- ---------- إنشاء حسابات الفريق من داخل الموقع ----------
create extension if not exists pgcrypto with schema extensions;

create or replace function public.admin_create_member(p_email text, p_name text, p_role text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_uid uuid; v_email text := lower(trim(p_email)); v_new boolean := false;
begin
  if public.sb_role() is distinct from 'admin' then raise exception 'not_allowed'; end if;
  if p_role not in ('admin', 'reviewer', 'volunteer') then raise exception 'bad_role'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'bad_email'; end if;
  if length(coalesce(trim(p_name), '')) < 3 then raise exception 'bad_name'; end if;
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null then
    if length(coalesce(p_password, '')) < 8 then raise exception 'weak_password'; end if;
    v_uid := gen_random_uuid(); v_new := true;
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email,
      crypt(p_password, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', jsonb_build_object('name', left(trim(p_name), 80)), now(), now(),
      '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text,
      jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), 'email', now(), now(), now());
  end if;
  if exists (select 1 from public.staff where user_id = v_uid) then return 'already_staff'; end if;
  insert into public.staff (user_id, name, role, email) values (v_uid, left(trim(p_name), 80), p_role, v_email);
  return case when v_new then 'created' else 'existing' end;
end $$;

create or replace function public.admin_set_password(p_uid uuid, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  if public.sb_role() is distinct from 'admin' then raise exception 'not_allowed'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'weak_password'; end if;
  if not exists (select 1 from public.staff where user_id = p_uid) then raise exception 'not_found'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = p_uid;
  return 'ok';
end $$;

revoke all on function public.admin_create_member(text, text, text, text), public.admin_set_password(uuid, text) from public, anon;
grant execute on function public.admin_create_member(text, text, text, text), public.admin_set_password(uuid, text) to authenticated;


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

notify pgrst, 'reload schema';
