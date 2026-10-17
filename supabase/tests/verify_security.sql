-- =============================================================================
-- verify_security.sql       STAGING ONLY
--
-- Run seed_test_data.sql ONCE first. Then paste this whole file into the
-- SQL Editor and press Run. The last table shows PASS or FAIL for every rule.
-- Every line should say PASS. Anything that says FAIL is a real security gap:
-- send me that row.
-- =============================================================================

-- Helper: run a statement, report OK or the error message
create or replace function pg_temp.try_sql(p_sql text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return sqlerrm;
end $$;

-- Helper: run a query returning one value, report it (or the error)
create or replace function pg_temp.scalar(p_sql text) returns text
language plpgsql as $$
declare v text;
begin
  execute p_sql into v;
  return coalesce(v, 'NULL');
exception when others then
  return 'ERR: ' || sqlerrm;
end $$;

create or replace function pg_temp.run_tests()
returns table(test_no int, test text, outcome text)
language plpgsql as $$
declare
  c1   constant uuid := '00000000-0000-0000-0000-000000000001';
  c2   constant uuid := '00000000-0000-0000-0000-000000000002';
  a    uuid := 'a1a1a1a1-0000-0000-0000-000000000001';   -- member, cooperative 1
  b    uuid := 'b2b2b2b2-0000-0000-0000-000000000002';   -- member, cooperative 2
  adm  uuid := 'ad000000-0000-0000-0000-000000000001';   -- admin, cooperative 1
  plat uuid := 'ff000000-0000-0000-0000-000000000001';   -- platform admin
  loan_a uuid;
  loan_b uuid;
  r text;
begin
  select id into loan_a from public.loan_applications where purpose = 'Seed loan' limit 1;
  if loan_a is null then raise exception 'Run seed_test_data.sql first'; end if;

  -- ======================= MEMBER A (cooperative 1) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  set local role authenticated;

  r := pg_temp.try_sql(format('update public.profiles set role = %L where id = %L', 'COOP_ADMIN', a));
  return query select 1, 'Member cannot make themselves an admin',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql(format('update public.profiles set cooperative_id = %L where id = %L', c2, a));
  return query select 2, 'Member cannot move themselves into another cooperative',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql(format('update public.savings_ledger set balance = balance + 100000 where member_id = %L', a));
  return query select 3, 'Member cannot change their own savings balance',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql(format($q$insert into public.loan_applications
        (applicant_id, loan_type, amount_requested, repayment_period_months, purpose)
        values (%L, 'EMERGENCY', 100, 3, 'x')$q$, a));
  return query select 4, 'Member cannot insert a loan row directly',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql(format('select public.approve_loan(%L, 100)', loan_a));
  return query select 5, 'Member cannot approve a loan',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.scalar(format('select count(*) from public.profiles where id = %L', b));
  return query select 6, 'Member cannot see a member of another cooperative',
    case when r = '0' then 'PASS' else 'FAIL: saw ' || r end;

  r := pg_temp.scalar(format('select count(*) from public.savings_ledger where member_id = %L', b));
  return query select 7, 'Member cannot see another cooperative''s savings',
    case when r = '0' then 'PASS' else 'FAIL: saw ' || r end;

  r := pg_temp.try_sql(format('select public.apply_deposit(%L, 100000, %L, %L)', a, 'forged-1', 'forged'));
  return query select 8, 'Signed-in user cannot forge a deposit',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.scalar(format('select count(*) from public.profiles where id = %L', a));
  return query select 9, 'Member can read their own profile',
    case when r = '1' then 'PASS' else 'FAIL: ' || r end;

  r := pg_temp.try_sql('select public.apply_loan(300000, 3)');
  return query select 10, 'Member with a loan in progress cannot apply for a second',
    case when position('already' in lower(r)) > 0 then 'PASS' else 'FAIL: ' || r end;

  -- ======================= MEMBER B (cooperative 2) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', b, 'role', 'authenticated')::text, true);

  r := pg_temp.scalar('select public.apply_loan(300000, 3)::text');
  return query select 11, 'Member can apply for a loan through apply_loan',
    case when length(r) = 36 then 'PASS' else 'FAIL: ' || r end;
  if length(r) = 36 then loan_b := r::uuid; end if;

  r := pg_temp.scalar(format('select count(*) from public.loan_applications where id = %L', loan_a));
  return query select 12, 'Member cannot see another cooperative''s loan',
    case when r = '0' then 'PASS' else 'FAIL: saw ' || r end;

  -- ======================= ADMIN 1 (cooperative 1) =======================
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated')::text, true);

  r := pg_temp.scalar(format('select count(*) from public.profiles where cooperative_id = %L', c1));
  return query select 13, 'Admin can see members of their own cooperative',
    case when r ~ '^[0-9]+$' and r::int >= 2 then 'PASS' else 'FAIL: saw ' || r end;

  r := pg_temp.scalar(format('select count(*) from public.profiles where cooperative_id = %L', c2));
  return query select 14, 'Admin cannot see members of another cooperative',
    case when r = '0' then 'PASS' else 'FAIL: saw ' || r end;

  r := pg_temp.try_sql(format('select public.approve_loan(%L, 100000)', loan_b));
  return query select 15, 'Admin cannot approve another cooperative''s loan',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql(format('select public.approve_loan(%L, 100000)', loan_a));
  return query select 16, 'Admin can approve their own cooperative''s loan',
    case when r = 'OK' then 'PASS' else 'FAIL: ' || r end;

  r := pg_temp.try_sql(format('update public.savings_ledger set balance = balance + 1 where member_id = %L', a));
  return query select 17, 'Admin cannot edit balances directly',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql($q$select public.create_cooperative('Sneaky Coop')$q$);
  return query select 18, 'Cooperative admin cannot create cooperatives',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  -- ======================= PLATFORM ADMIN =======================
  perform set_config('request.jwt.claims', json_build_object('sub', plat, 'role', 'authenticated')::text, true);

  r := pg_temp.try_sql($q$select public.create_cooperative('Test Cooperative 3')$q$);
  return query select 19, 'Platform admin can create a cooperative',
    case when r = 'OK' then 'PASS' else 'FAIL: ' || r end;

  r := pg_temp.scalar(format('select count(*) from public.profiles where id <> %L', plat));
  return query select 20, 'Platform admin cannot browse member profiles',
    case when r = '0' then 'PASS' else 'FAIL: saw ' || r end;

  r := pg_temp.scalar('select count(*) from public.cooperatives');
  return query select 21, 'Platform admin can see all cooperatives',
    case when r ~ '^[0-9]+$' and r::int >= 3 then 'PASS' else 'FAIL: saw ' || r end;

  -- ======================= SIGNED OUT (anon) =======================
  reset role;
  perform set_config('request.jwt.claims', '', true);
  set local role anon;

  r := pg_temp.try_sql('select count(*) from public.profiles');
  return query select 22, 'Signed-out visitors cannot read profiles',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  r := pg_temp.try_sql('select public.apply_loan(100, 3)');
  return query select 23, 'Signed-out visitors cannot apply for loans',
    case when r <> 'OK' then 'PASS' else 'FAIL: it was allowed' end;

  -- ======================= SIGN-UP RULES =======================
  reset role;

  r := pg_temp.try_sql($q$
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new)
    values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
      'bad_code@test.local', 'x', now(), '{}'::jsonb,
      '{"full_name":"Bad Code","join_code":"WRONG"}'::jsonb, now(), now(), '', '', '', '') $q$);
  return query select 24, 'Sign-up with a wrong cooperative code is rejected',
    case when position('invalid' in lower(r)) > 0 then 'PASS' else 'FAIL: ' || r end;
end $$;

select * from pg_temp.run_tests() order by test_no;