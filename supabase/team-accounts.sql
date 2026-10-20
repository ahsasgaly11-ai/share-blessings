-- =====================================================================
-- أثر: إنشاء حسابات الفريق من داخل الموقع
-- يتيح للمدير إنشاء حساب مشرف أو متطوع (بريد + كلمة مرور) وإعادة تعيين
-- كلمة مرور أي عضو، دون الدخول إلى لوحة Supabase.
-- آمن للتشغيل أكثر من مرة. (مضمَّن أيضًا في setup.sql)
-- =====================================================================
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

notify pgrst, 'reload schema';
