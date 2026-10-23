-- =====================================================================
-- أثر: إعداد قاعدة البيانات في Supabase
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

-- ويبقى يرى التبرعات التي تولّاها سابقًا (سجل مهامه) أسبوعًا واحدًا، لكنه لا يعدّل إلا المسندة إليه حاليًا
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
    when 'D:approved'  then array['scheduled', 'rejected', 'cancelled', 'new']
    when 'D:scheduled' then array['received', 'rejected']
    when 'D:received'  then array['allocated', 'closed', 'delivered']
    when 'D:allocated' then array['delivered']
    when 'R:new'       then array['verified', 'rejected', 'cancelled']
    when 'R:verified'  then array['matched', 'rejected', 'cancelled']
    when 'R:matched'   then array['delivered']
    else array[]::text[] end)
$$;

-- التسليم المباشر: يستلم المستفيد التبرع من المتبرع دون متطوع ودون المرور بالمستودع.
-- يسمح بثلاث خطوات إضافية فقط حين تدل البيانات عليها: سُلّم مباشرة، لم يحضر المستفيد (يعود التبرع مقبولًا والطلب متحققًا منه).
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
  using (public.sb_role() in ('admin', 'reviewer') or (public.sb_role() = 'volunteer'
         and (public.sb_vol_assigned(data) or (public.sb_vol_related(data) and updated_at > now() - interval '7 days'))));
create policy don_update on public.donations for update to authenticated
  using (public.sb_role() in ('admin', 'reviewer') or (public.sb_role() = 'volunteer' and public.sb_vol_assigned(data)))
  with check (public.sb_role() in ('admin', 'reviewer', 'volunteer'));
create policy don_insert on public.donations for insert to authenticated with check (public.sb_role() = 'admin');
create policy don_delete on public.donations for delete to authenticated using (public.sb_role() in ('admin', 'reviewer'));

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
-- اسم كاتب السجل يأتي من حسابه، لا مما يرسله المتصفح
create or replace function public.sb_log_by()
returns trigger language plpgsql security definer set search_path = public as $$
declare n text;
begin
  if auth.uid() is not null then select name into n from public.staff where user_id = auth.uid(); if n is not null then new.by := n; end if; end if;
  return new;
end $$;
drop trigger if exists activity_log_by on public.activity_log;
create trigger activity_log_by before insert on public.activity_log for each row execute function public.sb_log_by();

revoke all on public.donations, public.requests, public.staff, public.activity_log from anon;
grant select, insert, update, delete on public.donations, public.requests to authenticated;
grant select on public.staff to authenticated;
grant select, insert on public.activity_log to authenticated;

-- ---------- ما يراه صاحب الطلب: بياناته فقط، دون الصور أو أسماء المستفيدين ----------
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

-- ---------- حماية: تنظيف البيانات، ومنع التخمين والإغراق ----------
-- محاولات فاشلة ومرات إرسال، تُحذف بعد يوم
create table if not exists public.sb_attempts (k text not null, at timestamptz not null default now());
create index if not exists sb_attempts_k on public.sb_attempts (k, at);
alter table public.sb_attempts enable row level security;
revoke all on public.sb_attempts from anon, authenticated;

create or replace function public.sb_limited(p_key text, p_max int, p_window interval)
returns boolean language sql stable security definer set search_path = public as $$
  select count(*) >= p_max from public.sb_attempts where k = p_key and at > now() - p_window
$$;
create or replace function public.sb_note(p_key text)
returns void language sql security definer set search_path = public as $$
  delete from public.sb_attempts where at < now() - interval '1 day';
  insert into public.sb_attempts (k) values (p_key);
$$;
revoke all on function public.sb_limited(text, int, interval), public.sb_note(text) from public, anon, authenticated;

-- رقم صالح أو صفر: حتى لا تتعطل الإحصاءات بقيمة غريبة
create or replace function public.sb_num(x text)
returns numeric language sql immutable as $$
  select case when x ~ '^[0-9]{1,9}(\.[0-9]{1,4})?$' then x::numeric else 0 end
$$;

-- كل ما يُكتب في التبرعات والطلبات يمر من هنا، أيًا كان كاتبه:
-- لوحة العنوان أرقام فقط، والكميات أرقام موجبة، والإحداثيات أرقام، والروابط http(s) فقط، والصور المصغّرة JPEG فقط
create or replace function public.sb_clean()
returns trigger language plpgsql as $$
declare d jsonb := new.data; o jsonb := case when tg_op = 'UPDATE' then old.data else '{}'::jsonb end; th jsonb := '[]'::jsonb; x text;
begin
  if jsonb_typeof(d->'addr') = 'object' and (d->'addr') is distinct from (o->'addr')
     and (coalesce(d->'addr'->>'zone', '') !~ '^[0-9]{1,2}$' or coalesce(d->'addr'->>'street', '') !~ '^[0-9]{1,4}$' or coalesce(d->'addr'->>'bldg', '') !~ '^[0-9]{1,4}$') then
    raise exception 'bad_addr';
  end if;
  if tg_table_name = 'donations' and (d->'items') is distinct from (o->'items') and (jsonb_typeof(d->'items') is distinct from 'array'
     or exists (select 1 from jsonb_array_elements(d->'items') i where coalesce(i->>'qty', '') !~ '^[0-9]{1,6}(\.[0-9]{1,4})?$' or (i->>'qty')::numeric <= 0)) then
    raise exception 'bad_items';
  end if;
  if d ? 'geo' and d->'geo' <> 'null'::jsonb then
    if jsonb_typeof(d->'geo'->'lat') = 'number' and jsonb_typeof(d->'geo'->'lng') = 'number' and abs((d->'geo'->>'lat')::numeric) <= 90 and abs((d->'geo'->>'lng')::numeric) <= 180
      then d := jsonb_set(d, '{geo}', jsonb_build_object('lat', d->'geo'->'lat', 'lng', d->'geo'->'lng'));
      else d := d - 'geo'; end if;
  end if;
  if coalesce(d->>'mapUrl', '') <> '' and (d->>'mapUrl' !~* '^https?://[^\s"<>]+$' or length(d->>'mapUrl') > 500) then d := jsonb_set(d, '{mapUrl}', '""'); end if;
  if jsonb_typeof(d->'place') = 'object' and coalesce(d->'place'->>'mapUrl', '') <> '' and (d->'place'->>'mapUrl' !~* '^https?://[^\s"<>]+$' or length(d->'place'->>'mapUrl') > 500) then
    d := jsonb_set(d, '{place,mapUrl}', '""');
  end if;
  if jsonb_typeof(d->'thumbs') = 'array' then
    for x in select * from jsonb_array_elements_text(d->'thumbs') loop
      th := th || to_jsonb(case when x ~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' and length(x) < 12000 then x else '' end);
    end loop;
    d := jsonb_set(d, '{thumbs}', th);
  elsif d ? 'thumbs' then d := d - 'thumbs';
  end if;
  new.data := d;
  return new;
end $$;
drop trigger if exists donations_clean on public.donations;
create trigger donations_clean before insert or update on public.donations for each row execute function public.sb_clean();
drop trigger if exists requests_clean on public.requests;
create trigger requests_clean before insert or update on public.requests for each row execute function public.sb_clean();

-- المتطوع لا يغيّر في التبرع إلا ما يخص مهمته: الاستلام (الحالة والمتبقي)، وتسليم الأجزاء المسندة إليه، والموقع على الخريطة
create or replace function public.sb_vol_guard()
returns trigger language plpgsql as $$
declare keep text[] := array['status', 'history', '_v', 'items', 'allocations', 'geo'];
begin
  if coalesce(public.sb_role(), '') <> 'volunteer' then return new; end if;
  if (new.data - keep) is distinct from (old.data - keep)
     or (select jsonb_agg(i - 'left') from jsonb_array_elements(coalesce(new.data->'items', '[]'::jsonb)) i)
        is distinct from (select jsonb_agg(i - 'left') from jsonb_array_elements(coalesce(old.data->'items', '[]'::jsonb)) i)
     or (select jsonb_agg(a - 'delivered' - 'deliveredAt' - 'deliveredBy') from jsonb_array_elements(coalesce(new.data->'allocations', '[]'::jsonb)) a)
        is distinct from (select jsonb_agg(a - 'delivered' - 'deliveredAt' - 'deliveredBy') from jsonb_array_elements(coalesce(old.data->'allocations', '[]'::jsonb)) a)
     or exists (select 1 from jsonb_array_elements(coalesce(old.data->'allocations', '[]'::jsonb)) oa, jsonb_array_elements(coalesce(new.data->'allocations', '[]'::jsonb)) na
                 where na->>'id' = oa->>'id' and (na->'delivered') is distinct from (oa->'delivered') and oa->>'volId' is distinct from auth.uid()::text)
     or left(coalesce(new.data->>'history', ''), length(coalesce(old.data->>'history', '')) - 1) is distinct from left(coalesce(old.data->>'history', ''), length(coalesce(old.data->>'history', '')) - 1)
     or (new.status <> old.status and new.status not in ('received', 'allocated', 'delivered')) then
    raise exception 'not_allowed';
  end if;
  return new;
end $$;
drop trigger if exists donations_vol_guard on public.donations;
create trigger donations_vol_guard before update on public.donations for each row execute function public.sb_vol_guard();

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
  if public.sb_limited('sub:' || (p->>'phone'), 12, interval '1 day') or public.sb_limited('sub:*', 400, interval '1 hour') then raise exception 'too_many'; end if;
  if jsonb_typeof(v_photos) <> 'array' or jsonb_array_length(v_photos) > 4
     or exists (select 1 from jsonb_array_elements_text(v_photos) x where x !~ '^incoming/[0-9a-f-]{36}\.jpg$') then
    raise exception 'bad_photos';
  end if;
  -- تبرع يلبّي أمنية مجهولة: رقم الطلب فقط، وأي قيمة أخرى تُهمل
  if p ? 'wish' and (coalesce(p->>'wish', '') !~ '^R-[0-9]{1,9}$'
     or not exists (select 1 from public.requests where id = p->>'wish' and status = 'verified')) then p := p - 'wish'; end if;
  v_id := 'D-' || nextval('public.donation_seq');
  v := (p - 'id' - 'status' - 'history' - 'allocations' - 'edits' - 'pickup' - 'writeoffs' - '_v' - 'createdAt'
          - 'handover' - 'offer' - 'returned' - 'matchedWith' - 'allocatedTo' - 'person')
       || case when p->>'target' = 'person' and jsonb_typeof(p->'person') = 'object'
               then jsonb_build_object('person', jsonb_build_object('name', left(p->'person'->>'name', 80), 'addr', left(p->'person'->>'addr', 200))) else '{}'::jsonb end
       || jsonb_build_object('id', v_id, 'status', 'new', 'photos', v_photos,
            'history', jsonb_build_array(jsonb_build_object('status', 'new', 'at', now(), 'note', '')),
            'createdAt', now(), 'allocations', '[]'::jsonb, '_v', 1);
  insert into public.donations (id, phone, status, kind, data) values (v_id, p->>'phone', 'new', p->>'kind', v);
  perform public.sb_note('sub:' || (p->>'phone')); perform public.sb_note('sub:*');
  insert into public.activity_log (text, by) values ('تبرع جديد ' || v_id || ' من ' || left(p->>'name', 80), left(p->>'name', 80));
  return jsonb_build_object('id', v_id, 'createdAt', now());
end $$;

create or replace function public.submit_request(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id text; v jsonb;
begin
  if coalesce((select data->'intake'->>'requests' from public.site_config where id = 1), 'true') = 'false' then raise exception 'intake_closed'; end if;
  if octet_length(p::text) > 20000 then raise exception 'payload_too_large'; end if;
  if coalesce(p->>'phone', '') !~ '^[34567][0-9]{7}$' then raise exception 'bad_phone'; end if;
  if char_length(coalesce(p->>'name', '')) not between 3 and 80 then raise exception 'bad_name'; end if;
  if coalesce(p->>'kind', '') not in ('food', 'clothes', 'elec', 'furn', 'other') then raise exception 'bad_kind'; end if;
  if coalesce(p->>'size', '') !~ '^[0-9]{1,4}$' or (p->>'size')::int < 1 then raise exception 'bad_size'; end if;
  if public.sb_limited('sub:' || (p->>'phone'), 12, interval '1 day') or public.sb_limited('sub:*', 400, interval '1 hour') then raise exception 'too_many'; end if;
  -- لا نخبر السائل بوجود طلب سابق لهذا الهاتف (قد لا يكون صاحبه)؛ الطلب المكرر يظهر للمشرف بعلامة «مكرر محتمل»
  v_id := 'R-' || nextval('public.request_seq');
  v := (p - 'id' - 'status' - 'history' - 'edits' - 'matchedWith' - '_v' - 'createdAt' - 'offer' - 'wish' - 'verify' - 'photos' - 'thumbs')
       || jsonb_build_object('id', v_id, 'status', 'new', 'size', (p->>'size')::int,
            'history', jsonb_build_array(jsonb_build_object('status', 'new', 'at', now(), 'note', '')),
            'createdAt', now(), '_v', 1);
  insert into public.requests (id, phone, status, kind, data) values (v_id, p->>'phone', 'new', p->>'kind', v);
  perform public.sb_note('sub:' || (p->>'phone')); perform public.sb_note('sub:*');
  insert into public.activity_log (text, by) values ('طلب احتياج جديد ' || v_id, left(p->>'name', 80));
  return jsonb_build_object('id', v_id, 'createdAt', now());
end $$;

create or replace function public.track(p_code text, p_last4 text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code));
begin
  if coalesce(p_last4, '') !~ '^[0-9]{4}$' then return null; end if;
  -- عشر محاولات خاطئة لنفس الرقم في الساعة، ثم يتوقف البحث عنه مؤقتًا
  if public.sb_limited('trk:' || t, 10, interval '1 hour') then raise exception 'rate_limited'; end if;
  if t like 'D-%' then select data into r from public.donations where id = t and right(phone, 4) = p_last4;
  elsif t like 'R-%' then select data into r from public.requests where id = t and right(phone, 4) = p_last4;
  end if;
  if r is null then perform public.sb_note('trk:' || t); return null; end if;
  return public.sb_public_view(r);
end $$;

create or replace function public.owner_cancel(p_code text, p_phone text, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code)); allowed text[]; o jsonb;
begin
  if public.sb_limited('own:' || t, 10, interval '1 hour') or public.sb_limited('own:' || coalesce(p_phone, ''), 10, interval '1 hour') then raise exception 'rate_limited'; end if;
  if t like 'D-%' then select data into r from public.donations where id = t and phone = p_phone for update; allowed := array['new', 'approved'];
  elsif t like 'R-%' then select data into r from public.requests where id = t and phone = p_phone for update; allowed := array['new', 'verified'];
  end if;
  if r is null then perform public.sb_note('own:' || t); perform public.sb_note('own:' || coalesce(p_phone, '')); return jsonb_build_object('error', 'not_found'); end if;
  if not (r->>'status' = any (allowed)) then raise exception 'not_allowed'; end if;
  -- موعد تسليم مباشر لم يُرد عليه بعد: يُسحب من الطرف الآخر حتى لا يبقى معلّقًا
  if t like 'D-%' and r->'handover'->>'state' = 'offered' then
    r := jsonb_set(r, '{handover,state}', '"withdrawn"');
    select data into o from public.requests where id = r->'handover'->>'to' for update;
    if o is not null and o->'offer'->>'from' = t and o->'offer'->>'state' = 'offered' then
      update public.requests set data = jsonb_set(jsonb_set(o, '{offer,state}', '"withdrawn"'), '{_v}', to_jsonb(coalesce((o->>'_v')::int, 0) + 1)) where id = o->>'id';
    end if;
  elsif t like 'R-%' and r->'offer'->>'state' = 'offered' then
    r := jsonb_set(r, '{offer,state}', '"withdrawn"');
    select data into o from public.donations where id = r->'offer'->>'from' for update;
    if o is not null and o->'handover'->>'to' = t and o->'handover'->>'state' = 'offered' then
      update public.donations set data = jsonb_set(jsonb_set(o, '{handover,state}', '"withdrawn"'), '{_v}', to_jsonb(coalesce((o->>'_v')::int, 0) + 1)) where id = o->>'id';
    end if;
  end if;
  r := jsonb_set(r, '{status}', '"cancelled"');
  r := jsonb_set(r, '{history}', coalesce(r->'history', '[]'::jsonb) || jsonb_build_array(jsonb_build_object('status', 'cancelled', 'at', now(), 'note', left(coalesce(p_reason, ''), 120))));
  r := jsonb_set(r, '{_v}', to_jsonb(coalesce((r->>'_v')::int, 0) + 1));
  if t like 'D-%' then update public.donations set data = r where id = t; else update public.requests set data = r where id = t; end if;
  insert into public.activity_log (text, by) values ('ألغى صاحب الطلب ' || t || ': ' || left(coalesce(p_reason, ''), 120), 'صاحب الطلب');
  return public.sb_public_view(r);
end $$;

create or replace function public.owner_edit(p_code text, p_phone text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; t text := upper(trim(p_code)); changed text[] := '{}'; k text; i int; q numeric; items jsonb; ph jsonb; th jsonb; pl jsonb; ret boolean;
begin
  if public.sb_limited('own:' || t, 10, interval '1 hour') or public.sb_limited('own:' || coalesce(p_phone, ''), 10, interval '1 hour') then raise exception 'rate_limited'; end if;
  if octet_length(p::text) > 40000 then raise exception 'payload_too_large'; end if;
  if t like 'D-%' then select data into r from public.donations where id = t and phone = p_phone for update;
  elsif t like 'R-%' then select data into r from public.requests where id = t and phone = p_phone for update;
  end if;
  if r is null then perform public.sb_note('own:' || t); perform public.sb_note('own:' || coalesce(p_phone, '')); return jsonb_build_object('error', 'not_found'); end if;
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

-- رد المستفيد على موعد التسليم المباشر (من صفحة «تتبّع طلبي»، بالهاتف كاملًا)
create or replace function public.owner_respond(p_code text, p_phone text, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; d jsonb; t text := upper(trim(p_code)); did text; st text;
begin
  if public.sb_limited('own:' || t, 10, interval '1 hour') or public.sb_limited('own:' || coalesce(p_phone, ''), 10, interval '1 hour') then raise exception 'rate_limited'; end if;
  select data into r from public.requests where id = t and phone = p_phone for update;
  if r is null then perform public.sb_note('own:' || t); perform public.sb_note('own:' || coalesce(p_phone, '')); return jsonb_build_object('error', 'not_found'); end if;
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

-- سجل المتبرع: يتطلب الهاتف ورقم أحد تبرعاته
create or replace function public.donor_history(p_phone text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ok boolean;
begin
  if public.sb_limited('own:' || coalesce(p_phone, ''), 10, interval '1 hour') then raise exception 'rate_limited'; end if;
  select exists (select 1 from public.donations where id = upper(trim(p_code)) and phone = p_phone) into ok;
  if not ok then perform public.sb_note('own:' || coalesce(p_phone, '')); return null; end if;
  return jsonb_build_object(
    'name', (select data->>'name' from public.donations where phone = p_phone order by created_at desc limit 1),
    'families', (select count(distinct case when a->>'to' = '__target' then d.id else a->>'to' end)
                   from public.donations d, jsonb_array_elements(coalesce(d.data->'allocations', '[]'::jsonb)) a
                  where d.phone = p_phone and coalesce((a->>'delivered')::boolean, false) and a->>'to' <> '__open'),
    'donations', coalesce((select jsonb_agg(public.sb_public_view(data) order by created_at desc) from public.donations where phone = p_phone), '[]'::jsonb));
end $$;

-- أرقام الأثر والحملات في الصفحة الرئيسية
create or replace function public.public_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  with it as (
    select d.status, d.kind, d.phone, i, public.sb_num(i->>'qty') as q
      from public.donations d, jsonb_array_elements(d.data->'items') i)
  select jsonb_build_object(
    'kg',  coalesce((select sum(q) from it where kind = 'food' and i->>'unit' = 'kg' and status in ('received', 'allocated', 'delivered')), 0),
    'pcs', coalesce((select sum(q) from it where kind = 'clothes' and status in ('received', 'allocated', 'delivered')), 0),
    'fam', coalesce((select sum(public.sb_num(data->>'size')) from public.requests where status = 'delivered'), 0),
    'donors', (select count(distinct phone) from public.donations where status not in ('new', 'rejected', 'cancelled')),
    -- الحملات: ما راجعه المشرفون فقط
    'winter', coalesce((select sum(q) from it where kind = 'clothes' and i->>'type' = 'winter' and status in ('approved', 'scheduled', 'received', 'allocated', 'delivered')), 0),
    'ramadan', coalesce((select sum(q) from it where kind = 'food' and i->>'unit' = 'kg' and i->>'type' in ('rice', 'flour', 'legumes', 'sugar') and status in ('approved', 'scheduled', 'received', 'allocated', 'delivered')), 0),
    'dates', coalesce((select sum(q) from it where kind = 'food' and i->>'unit' = 'kg' and i->>'type' = 'dates' and status in ('approved', 'scheduled', 'received', 'allocated', 'delivered')), 0))
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
  if v_uid = auth.uid() and p_role <> 'admin' then raise exception 'not_allowed'; end if;
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
-- حد أعلى للرفع: 300 صورة في الساعة من الجميع، حتى لا تمتلئ المساحة المجانية
create or replace function public.sb_upload_ok()
returns boolean language sql stable security definer set search_path = public, storage as $$
  select count(*) < 300 from storage.objects where bucket_id = 'donation-photos' and created_at > now() - interval '1 hour'
$$;
revoke all on function public.sb_upload_ok() from public;
grant execute on function public.sb_upload_ok() to anon, authenticated;
create policy sb_photos_upload on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'donation-photos' and (storage.foldername(name))[1] = 'incoming' and public.sb_upload_ok());
-- المتطوع يرى صور مهامه الحالية فقط
create policy sb_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'donation-photos' and (public.sb_role() in ('admin', 'reviewer')
         or (public.sb_role() = 'volunteer' and exists (select 1 from public.donations d where d.data->'photos' ? name and public.sb_vol_assigned(d.data)))));
create policy sb_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'donation-photos' and public.sb_role() in ('admin', 'reviewer'));

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
  -- حساب سجّله شخص آخر بنفس البريد ولم يؤكده: لا يُربط بالفريق
  if v_uid is not null and (select email_confirmed_at from auth.users where id = v_uid) is null then raise exception 'unconfirmed_user'; end if;
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
  -- كلمة مرور جديدة تُخرج الحساب من كل الأجهزة (إلا إن غيّر المدير كلمته بنفسه)
  if p_uid <> auth.uid() then delete from auth.sessions where user_id = p_uid; end if;
  insert into public.activity_log (text, by) values ('تغيير كلمة مرور ' || coalesce((select name from public.staff where user_id = p_uid), ''), (select name from public.staff where user_id = auth.uid()));
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

-- تقدّم كل حملة: مجموع كميات التبرعات التي راجعها المشرفون لنوعها وأصنافها (الغذاء بالكيلوغرام فقط)
create or replace function public.campaign_progress()
returns jsonb language sql stable security definer set search_path = public as $$
  with c as (
    select x from public.site_config s, jsonb_array_elements(coalesce(s.data->'campaigns', '[]'::jsonb)) x where s.id = 1),
  it as (
    select d.kind, i from public.donations d, jsonb_array_elements(d.data->'items') i where d.status in ('approved', 'scheduled', 'received', 'allocated', 'delivered'))
  select coalesce(jsonb_object_agg(c.x->>'id', (
    select coalesce(sum(public.sb_num(it.i->>'qty')), 0) from it
     where it.kind = c.x->>'kind'
       and (jsonb_array_length(coalesce(c.x->'types', '[]'::jsonb)) = 0 or (c.x->'types') ? (it.i->>'type'))
       and (it.kind <> 'food' or it.i->>'unit' = 'kg'))), '{}'::jsonb)
  from c
$$;
revoke all on function public.campaign_progress() from public;
grant execute on function public.campaign_progress() to anon, authenticated;

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
