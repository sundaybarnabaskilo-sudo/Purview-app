-- =============================================================================
-- seed_test_data.sql        STAGING ONLY. Never run this on your real project.
--
-- Creates test data so verify_security.sql can run by itself:
--   Cooperative 1 (the Default one)  : Test Member A, Test Admin 1
--   Cooperative 2 (created here)     : Test Member B
--   Platform admin                   : Test Platform Admin
--   One pending loan for Member A
--
-- Run it ONCE. If it fails halfway nothing is saved (it is one transaction).
-- These users are created directly in the database for testing. They cannot
-- sign in through the app.
-- =============================================================================
do $$
declare
  c1 constant uuid := '00000000-0000-0000-0000-000000000001';
  c2 constant uuid := '00000000-0000-0000-0000-000000000002';
  code1 text;
  code2 text;
  r record;
begin
  insert into public.cooperatives (id, name) values (c2, 'Test Cooperative 2');
  insert into public.loan_policies (cooperative_id, term_months, rate_bps)
  values (c2, 3, 500), (c2, 6, 700), (c2, 12, 1000);

  select join_code into code1 from public.cooperatives where id = c1;
  select join_code into code2 from public.cooperatives where id = c2;

  -- The sign-up trigger from 0004 creates each profile, savings ledger and share row.
  for r in
    select * from (values
      ('a1a1a1a1-0000-0000-0000-000000000001'::uuid, 'member_a@test.local',        'Test Member A',        code1),
      ('b2b2b2b2-0000-0000-0000-000000000002'::uuid, 'member_b@test.local',        'Test Member B',        code2),
      ('ad000000-0000-0000-0000-000000000001'::uuid, 'admin_1@test.local',         'Test Admin 1',         code1),
      ('ff000000-0000-0000-0000-000000000001'::uuid, 'platform_admin@test.local',  'Test Platform Admin',  code1)
    ) as v(id, email, full_name, code)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) values (
      '00000000-0000-0000-0000-000000000000', r.id, 'authenticated', 'authenticated',
      r.email, extensions.crypt('TestPass123!', extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', r.full_name, 'phone_number', '08000000000', 'join_code', r.code),
      now(), now(), '', '', '', ''
    );
  end loop;

  -- New members start inactive; activate the test users.
  update public.profiles set is_active = true
   where id in ('a1a1a1a1-0000-0000-0000-000000000001',
                'b2b2b2b2-0000-0000-0000-000000000002',
                'ad000000-0000-0000-0000-000000000001',
                'ff000000-0000-0000-0000-000000000001');

  -- Admin of cooperative 1, with every permission
  update public.profiles
     set role = 'COOP_ADMIN',
         permissions = array['APPROVE_LOANS','MANAGE_MEMBERS','MANAGE_SHARE_CAPITAL',
                             'VIEW_FINANCIAL_REPORTS','POST_LEDGER_ENTRIES',
                             'MANAGE_FEES','MANAGE_LOAN_POLICY']
   where id = 'ad000000-0000-0000-0000-000000000001';

  -- Platform admin belongs to no cooperative
  update public.profiles
     set role = 'PLATFORM_ADMIN', cooperative_id = null
   where id = 'ff000000-0000-0000-0000-000000000001';

  -- One pending loan for Member A (cooperative is stamped by a trigger)
  insert into public.loan_applications
    (applicant_id, loan_type, status, amount_requested, repayment_period_months, purpose)
  values
    ('a1a1a1a1-0000-0000-0000-000000000001', 'EMERGENCY', 'PENDING', 500000, 3, 'Seed loan');
end $$;

-- Quick check: you should see 4 rows
select u.email, p.role, p.is_active, c.name as cooperative
  from auth.users u
  join public.profiles p on p.id = u.id
  left join public.cooperatives c on c.id = p.cooperative_id
 where u.email like '%@test.local'
 order by u.email;
