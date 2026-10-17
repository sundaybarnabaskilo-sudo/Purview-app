-- =============================================================================
-- 0004_member_onboarding.sql
--
-- Creates the member's profile, savings account and share-capital row at
-- sign-up, inside the database, so the client can never choose its own role
-- or cooperative. The cooperative comes ONLY from a valid join code.
--
-- BEFORE RUNNING: list any sign-up trigger you already have and drop it,
-- otherwise two triggers will both try to create the profile and sign-up fails:
--
--   select tgname from pg_trigger
--    where tgrelid = 'auth.users'::regclass and not tgisinternal;
--
--   drop trigger "<your_existing_trigger_name>" on auth.users;
--
-- App change: pass the extra fields when signing up:
--   supabase.auth.signUp({
--     email, password,
--     options: { data: { full_name, phone_number, join_code } },
--   });
-- =============================================================================

create sequence if not exists public.member_number_seq start 1;
create sequence if not exists public.savings_account_seq start 1000000001;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_coop public.cooperatives;
  v_name text := trim(coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  v_code text := upper(trim(coalesce(new.raw_user_meta_data ->> 'join_code', '')));
begin
  -- Only name, phone and join code are read from client-supplied metadata.
  -- Role, cooperative and status are decided here, never by the client.
  select * into v_coop from public.cooperatives where join_code = v_code and status = 'ACTIVE';
  if not found then raise exception 'Invalid or inactive cooperative code'; end if;
  if length(v_name) < 2 then raise exception 'Full name is required'; end if;

  insert into public.profiles
    (id, email, full_name, phone_number, member_number, role, is_active, cooperative_id, date_joined)
  values
    (new.id, new.email, left(v_name, 120),
     left(trim(coalesce(new.raw_user_meta_data ->> 'phone_number', '')), 32),
     'PV' || lpad(nextval('public.member_number_seq')::text, 6, '0'),
     'MEMBER',
     false,                      -- stays inactive until a cooperative admin approves
     v_coop.id, now());

  insert into public.savings_ledger (member_id, account_number, account_type)
  values (new.id, 'SV' || nextval('public.savings_account_seq')::text, 'REGULAR');

  insert into public.share_capital (member_id, share_value)
  values (new.id, v_coop.share_value_minor);

  return new;
end $$;

revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
