-- =============================================================================
-- verify_security.sql
-- Run in the Supabase SQL editor on STAGING after applying 0003 and 0004.
-- Run each numbered block on its own. Every block ends in ROLLBACK, so nothing
-- is saved. "EXPECT" tells you what a correct result looks like.
--
-- Replace the placeholders first:
--   <MEMBER_A>  uuid of a MEMBER in cooperative 1
--   <MEMBER_B>  uuid of a MEMBER in cooperative 2 (create a second cooperative)
--   <LOAN_ID>   uuid of any loan application
-- =============================================================================

-- 1. A member cannot make themselves an admin.
begin;
select set_config('request.jwt.claims', '{"sub":"<MEMBER_A>","role":"authenticated"}', true);
set local role authenticated;
update public.profiles set role = 'COOP_ADMIN' where id = '<MEMBER_A>';
-- EXPECT: ERROR  permission denied for table profiles / column "role"
rollback;

-- 2. A member cannot credit their own savings.
begin;
select set_config('request.jwt.claims', '{"sub":"<MEMBER_A>","role":"authenticated"}', true);
set local role authenticated;
update public.savings_ledger set balance = balance + 100000 where member_id = '<MEMBER_A>';
-- EXPECT: ERROR  permission denied for table savings_ledger
rollback;

-- 3. A member cannot write a transaction or a loan row directly.
begin;
select set_config('request.jwt.claims', '{"sub":"<MEMBER_A>","role":"authenticated"}', true);
set local role authenticated;
insert into public.loan_applications (applicant_id, loan_type, amount_requested, repayment_period_months, purpose)
values ('<MEMBER_A>', 'EMERGENCY', 100, 3, 'x');
-- EXPECT: ERROR  permission denied for table loan_applications
rollback;

-- 4. A member cannot approve a loan.
begin;
select set_config('request.jwt.claims', '{"sub":"<MEMBER_A>","role":"authenticated"}', true);
set local role authenticated;
select public.approve_loan('<LOAN_ID>', 100);
-- EXPECT: ERROR  Not authorised
rollback;

-- 5. Tenant isolation: a member of cooperative 1 sees nothing of cooperative 2.
begin;
select set_config('request.jwt.claims', '{"sub":"<MEMBER_A>","role":"authenticated"}', true);
set local role authenticated;
select count(*) as should_be_zero from public.profiles where id = '<MEMBER_B>';
select count(*) as should_be_zero from public.savings_ledger where member_id = '<MEMBER_B>';
-- EXPECT: 0 and 0
rollback;

-- 6. Anonymous users can read nothing.
begin;
set local role anon;
select count(*) from public.profiles;
-- EXPECT: ERROR  permission denied for table profiles
rollback;

-- 7. Forged deposits: calling apply_deposit from a signed-in session must fail.
begin;
select set_config('request.jwt.claims', '{"sub":"<MEMBER_A>","role":"authenticated"}', true);
set local role authenticated;
select public.apply_deposit('<MEMBER_A>', 100000, 'forged-1', 'test');
-- EXPECT: ERROR  permission denied for function apply_deposit
rollback;

-- 8. Sign-up with a bad cooperative code must fail (run from the app or:)
--    insert into auth.users (...) is not recommended; instead try signing up in
--    the app with join_code = 'WRONG'. EXPECT: sign-up rejected, no profile row.
