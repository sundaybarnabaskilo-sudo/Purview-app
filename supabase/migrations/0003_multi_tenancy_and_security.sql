-- =============================================================================
-- 0003_multi_tenancy_and_security.sql
--
-- 1. Turns Purview into a multi-cooperative platform (cooperative_id everywhere).
-- 2. Closes the privilege-escalation and tenant-leak holes found in 0001/0002.
-- 3. Moves every money-changing action into SECURITY DEFINER functions.
--
-- RUN ON STAGING FIRST. Apply together with 0004_member_onboarding.sql.
--
-- BREAKING CHANGES for the app (see chat notes):
--   * roles are now MEMBER | COOP_ADMIN | PLATFORM_ADMIN (SUPER_ADMIN is gone)
--   * members can no longer insert/update loans, ledgers or transactions directly
--   * loans are created with supabase.rpc('apply_loan', ...)
--   * profiles are created by a sign-up trigger (0004), not by the client
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. COOPERATIVES (the tenants)
-- -----------------------------------------------------------------------------
create table public.cooperatives (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  registration_number text unique,
  join_code           text not null unique
                      default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)),
  share_value_minor   bigint not null default 0,
  status              text not null default 'ACTIVE' check (status in ('ACTIVE', 'SUSPENDED')),
  created_at          timestamptz not null default now()
);

-- All existing data is moved into one default cooperative. Rename it afterwards.
insert into public.cooperatives (id, name)
values ('00000000-0000-0000-0000-000000000001', 'Default Cooperative (rename me)');

-- -----------------------------------------------------------------------------
-- 2. ADD cooperative_id TO EXISTING TABLES (backfill, then lock NOT NULL)
-- -----------------------------------------------------------------------------
alter table public.profiles add column cooperative_id uuid references public.cooperatives(id);
update public.profiles set cooperative_id = '00000000-0000-0000-0000-000000000001';

-- Roles: SUPER_ADMIN becomes COOP_ADMIN. Promote yourself to PLATFORM_ADMIN
-- manually afterwards (see bottom of this file).
alter table public.profiles drop constraint if exists profiles_role_check;
update public.profiles set role = 'COOP_ADMIN' where role = 'SUPER_ADMIN';
update public.profiles
   set permissions = array['APPROVE_LOANS','MANAGE_MEMBERS','MANAGE_SHARE_CAPITAL',
                           'VIEW_FINANCIAL_REPORTS','POST_LEDGER_ENTRIES',
                           'MANAGE_FEES','MANAGE_LOAN_POLICY']
 where role = 'COOP_ADMIN' and (permissions is null or cardinality(permissions) = 0);
alter table public.profiles
  add constraint profiles_role_check check (role in ('MEMBER', 'COOP_ADMIN', 'PLATFORM_ADMIN'));
-- Platform admins belong to no cooperative; everyone else must belong to one.
alter table public.profiles
  add constraint profiles_coop_matches_role
  check ((role = 'PLATFORM_ADMIN') = (cooperative_id is null));

alter table public.savings_ledger    add column cooperative_id uuid references public.cooperatives(id);
alter table public.share_capital     add column cooperative_id uuid references public.cooperatives(id);
alter table public.loan_applications add column cooperative_id uuid references public.cooperatives(id);
alter table public.loan_guarantors   add column cooperative_id uuid references public.cooperatives(id);
alter table public.transactions      add column cooperative_id uuid references public.cooperatives(id);

update public.savings_ledger    t set cooperative_id = p.cooperative_id from public.profiles p where p.id = t.member_id;
update public.share_capital     t set cooperative_id = p.cooperative_id from public.profiles p where p.id = t.member_id;
update public.transactions      t set cooperative_id = p.cooperative_id from public.profiles p where p.id = t.member_id;
update public.loan_applications t set cooperative_id = p.cooperative_id from public.profiles p where p.id = t.applicant_id;
update public.loan_guarantors   t set cooperative_id = l.cooperative_id from public.loan_applications l where l.id = t.loan_id;

alter table public.savings_ledger    alter column cooperative_id set not null;
alter table public.share_capital     alter column cooperative_id set not null;
alter table public.loan_applications alter column cooperative_id set not null;
alter table public.loan_guarantors   alter column cooperative_id set not null;
alter table public.transactions      alter column cooperative_id set not null;

create index on public.profiles (cooperative_id);
create index on public.savings_ledger (cooperative_id);
create index on public.share_capital (cooperative_id);
create index on public.loan_applications (cooperative_id, status);
create index on public.loan_guarantors (cooperative_id);
create index on public.transactions (cooperative_id, created_at desc);

-- Balances can never go negative (NOT VALID = enforced for new writes only).
alter table public.savings_ledger
  add constraint savings_balance_non_negative check (balance >= 0) not valid;

-- loan_repayments exists in your live database but not in the repo. It cannot be
-- scoped safely without seeing its columns, so it is LOCKED (RLS on, no policies)
-- until policies are written for it.
do $$
begin
  if to_regclass('public.loan_repayments') is not null then
    alter table public.loan_repayments enable row level security;
    raise notice 'loan_repayments found: RLS enabled with NO policies (locked). Send its definition to add tenant-scoped policies.';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 3. NEW TABLES
-- -----------------------------------------------------------------------------
-- Each cooperative's own loan tiers (replaces hard-coded 3/6/12 at 5/7/10 %).
create table public.loan_policies (
  id             uuid primary key default gen_random_uuid(),
  cooperative_id uuid not null references public.cooperatives(id) on delete cascade,
  term_months    int  not null check (term_months between 1 and 60),
  rate_bps       int  not null check (rate_bps between 0 and 5000),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (cooperative_id, term_months)
);
insert into public.loan_policies (cooperative_id, term_months, rate_bps)
values ('00000000-0000-0000-0000-000000000001', 3, 500),
       ('00000000-0000-0000-0000-000000000001', 6, 700),
       ('00000000-0000-0000-0000-000000000001', 12, 1000);

-- What PURVIEW charges cooperatives. Editable only by the platform admin.
create table public.platform_fee_rules (
  id          uuid primary key default gen_random_uuid(),
  applies_to  text not null,                          -- a transaction type, or 'SUBSCRIPTION'
  kind        text not null check (kind in ('FLAT', 'PERCENTAGE')),
  flat_amount bigint check (flat_amount >= 0),
  rate_bps    int check (rate_bps between 0 and 10000),
  cap_amount  bigint check (cap_amount >= 0),
  is_active   boolean not null default false,
  created_at  timestamptz not null default now(),
  check ((kind = 'FLAT' and flat_amount is not null) or (kind = 'PERCENTAGE' and rate_bps is not null))
);

-- What EACH COOPERATIVE charges its members. Never active without board approval.
create table public.cooperative_fee_rules (
  id                    uuid primary key default gen_random_uuid(),
  cooperative_id        uuid not null references public.cooperatives(id) on delete cascade,
  applies_to            text not null,
  kind                  text not null check (kind in ('FLAT', 'PERCENTAGE')),
  flat_amount           bigint check (flat_amount >= 0),
  rate_bps              int check (rate_bps between 0 and 10000),
  cap_amount            bigint check (cap_amount >= 0),
  is_active             boolean not null default false,
  approved_by_board_at  timestamptz,
  recorded_by           uuid default auth.uid() references public.profiles(id),
  created_at            timestamptz not null default now(),
  check ((kind = 'FLAT' and flat_amount is not null) or (kind = 'PERCENTAGE' and rate_bps is not null)),
  check (not is_active or approved_by_board_at is not null)
);

-- Who did what. Written only by the functions below.
create table public.audit_log (
  id             uuid primary key default gen_random_uuid(),
  cooperative_id uuid references public.cooperatives(id),
  actor_id       uuid,
  action         text not null,
  target_type    text,
  target_id      uuid,
  details        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);
create index on public.audit_log (cooperative_id, created_at desc);

-- -----------------------------------------------------------------------------
-- 4. HELPER FUNCTIONS (SECURITY DEFINER so they can read profiles without RLS recursion)
-- -----------------------------------------------------------------------------
create or replace function public.my_coop() returns uuid
language sql stable security definer set search_path = public as $$
  select cooperative_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'PLATFORM_ADMIN' and is_active
                     from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_coop_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'COOP_ADMIN' and is_active
                     from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.has_permission(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'COOP_ADMIN' and is_active
                          and p = any(coalesce(permissions, '{}'))
                     from public.profiles where id = auth.uid()), false);
$$;

-- Deprecated: kept only so any leftover policy or code that still calls it
-- gets "false" instead of an error. Remove once nothing references it.
create or replace function public.is_super_admin() returns boolean
language sql stable as $$ select false; $$;

-- Writes an audit row. Internal: only other definer functions may call it.
create or replace function public.write_audit(
  p_coop uuid, p_action text, p_target_type text, p_target_id uuid,
  p_details jsonb default '{}'::jsonb
) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log (cooperative_id, actor_id, action, target_type, target_id, details)
  values (p_coop, auth.uid(), p_action, p_target_type, p_target_id, p_details);
$$;

-- -----------------------------------------------------------------------------
-- 5. TENANT STAMPING: cooperative_id is always copied from the owner's profile,
--    so a client can never insert a row into someone else's cooperative.
-- -----------------------------------------------------------------------------
create or replace function public.fill_coop_from_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select cooperative_id into new.cooperative_id from public.profiles where id = new.member_id;
  if new.cooperative_id is null then raise exception 'Member has no cooperative'; end if;
  return new;
end $$;

create or replace function public.fill_coop_from_applicant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select cooperative_id into new.cooperative_id from public.profiles where id = new.applicant_id;
  if new.cooperative_id is null then raise exception 'Applicant has no cooperative'; end if;
  return new;
end $$;

create or replace function public.fill_coop_from_loan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select cooperative_id into new.cooperative_id from public.loan_applications where id = new.loan_id;
  if new.cooperative_id is null then raise exception 'Loan not found'; end if;
  return new;
end $$;

create trigger trg_savings_coop      before insert on public.savings_ledger    for each row execute function public.fill_coop_from_member();
create trigger trg_shares_coop       before insert on public.share_capital     for each row execute function public.fill_coop_from_member();
create trigger trg_transactions_coop before insert on public.transactions      for each row execute function public.fill_coop_from_member();
create trigger trg_loans_coop        before insert on public.loan_applications for each row execute function public.fill_coop_from_applicant();
create trigger trg_guarantors_coop   before insert on public.loan_guarantors   for each row execute function public.fill_coop_from_loan();

-- -----------------------------------------------------------------------------
-- 6. RLS: remove EVERY old policy (including any added by hand), then rebuild
-- -----------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname from pg_policies
    where schemaname = 'public'
      and tablename in ('profiles','savings_ledger','share_capital','loan_applications',
                        'loan_guarantors','transactions','loan_repayments')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

alter table public.cooperatives          enable row level security;
alter table public.loan_policies         enable row level security;
alter table public.platform_fee_rules    enable row level security;
alter table public.cooperative_fee_rules enable row level security;
alter table public.audit_log             enable row level security;

-- Table privileges: nothing for anon; read-only for members on money tables.
revoke all on all tables in schema public from anon;
revoke all on public.profiles, public.savings_ledger, public.share_capital,
              public.loan_applications, public.loan_guarantors, public.transactions,
              public.cooperatives, public.audit_log
  from authenticated;

grant select on public.savings_ledger, public.share_capital, public.loan_applications,
                public.loan_guarantors, public.transactions, public.audit_log,
                public.profiles to authenticated;
-- Members may edit ONLY these profile columns. role, is_active, cooperative_id,
-- member_number and virtual_account_* are not editable from the app.
grant update (full_name, phone_number, next_of_kin_name, next_of_kin_phone, updated_at)
  on public.profiles to authenticated;
-- join_code is deliberately not selectable; admins read it through get_join_code().
grant select (id, name, registration_number, share_value_minor, status, created_at)
  on public.cooperatives to authenticated;
grant select, insert, update, delete
  on public.loan_policies, public.platform_fee_rules, public.cooperative_fee_rules
  to authenticated;

-- profiles
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or (public.is_coop_admin() and cooperative_id = public.my_coop()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- cooperatives
create policy cooperatives_select on public.cooperatives for select to authenticated
  using (id = public.my_coop() or public.is_platform_admin());

-- money tables: member sees own rows; coop admin sees own cooperative only
create policy savings_select on public.savings_ledger for select to authenticated
  using (member_id = auth.uid() or (public.is_coop_admin() and cooperative_id = public.my_coop()));
create policy shares_select on public.share_capital for select to authenticated
  using (member_id = auth.uid() or (public.is_coop_admin() and cooperative_id = public.my_coop()));
create policy transactions_select on public.transactions for select to authenticated
  using (member_id = auth.uid() or (public.is_coop_admin() and cooperative_id = public.my_coop()));
create policy loans_select on public.loan_applications for select to authenticated
  using (applicant_id = auth.uid() or (public.is_coop_admin() and cooperative_id = public.my_coop()));
create policy guarantors_select on public.loan_guarantors for select to authenticated
  using (
    member_id = auth.uid()
    or (public.is_coop_admin() and cooperative_id = public.my_coop())
    or exists (select 1 from public.loan_applications la
                where la.id = loan_id and la.applicant_id = auth.uid())
  );
-- (No insert/update/delete policies on money tables: only the functions below write.)

-- loan policies: everyone in the cooperative reads; admins with the permission edit
create policy loan_policies_select on public.loan_policies for select to authenticated
  using (cooperative_id = public.my_coop() or public.is_platform_admin());
create policy loan_policies_write on public.loan_policies for all to authenticated
  using (public.has_permission('MANAGE_LOAN_POLICY') and cooperative_id = public.my_coop())
  with check (public.has_permission('MANAGE_LOAN_POLICY') and cooperative_id = public.my_coop());

-- platform fees: platform admin edits; cooperative admins may read what they are charged
create policy platform_fees_select on public.platform_fee_rules for select to authenticated
  using (public.is_platform_admin() or public.is_coop_admin());
create policy platform_fees_write on public.platform_fee_rules for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

-- cooperative fees: members see what they may be charged; admins with MANAGE_FEES edit
create policy coop_fees_select on public.cooperative_fee_rules for select to authenticated
  using (cooperative_id = public.my_coop());
create policy coop_fees_write on public.cooperative_fee_rules for all to authenticated
  using (public.has_permission('MANAGE_FEES') and cooperative_id = public.my_coop())
  with check (public.has_permission('MANAGE_FEES') and cooperative_id = public.my_coop());

-- audit log: read-only
create policy audit_select on public.audit_log for select to authenticated
  using ((public.is_coop_admin() and cooperative_id = public.my_coop()) or public.is_platform_admin());

-- -----------------------------------------------------------------------------
-- 7. PLATFORM / ADMIN FUNCTIONS
-- -----------------------------------------------------------------------------
create or replace function public.create_cooperative(p_name text, p_registration_number text default null)
returns public.cooperatives
language plpgsql security definer set search_path = public as $$
declare v public.cooperatives;
begin
  if not public.is_platform_admin() then raise exception 'Not authorised'; end if;
  if p_name is null or length(trim(p_name)) < 2 then raise exception 'Cooperative name is required'; end if;
  insert into public.cooperatives (name, registration_number)
  values (trim(p_name), nullif(trim(coalesce(p_registration_number, '')), ''))
  returning * into v;
  insert into public.loan_policies (cooperative_id, term_months, rate_bps)
  values (v.id, 3, 500), (v.id, 6, 700), (v.id, 12, 1000);
  perform public.write_audit(v.id, 'COOPERATIVE_CREATED', 'cooperative', v.id, jsonb_build_object('name', v.name));
  return v;
end $$;

create or replace function public.assign_coop_admin(p_user uuid, p_permissions text[])
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_allowed text[] := array['APPROVE_LOANS','MANAGE_MEMBERS','MANAGE_SHARE_CAPITAL',
                            'VIEW_FINANCIAL_REPORTS','POST_LEDGER_ENTRIES','MANAGE_FEES','MANAGE_LOAN_POLICY'];
  v_coop uuid;
begin
  if not public.is_platform_admin() then raise exception 'Not authorised'; end if;
  if p_permissions is null or cardinality(p_permissions) = 0 or not (p_permissions <@ v_allowed) then
    raise exception 'Invalid permissions';
  end if;
  update public.profiles
     set role = 'COOP_ADMIN', permissions = p_permissions, is_active = true, updated_at = now()
   where id = p_user and role in ('MEMBER', 'COOP_ADMIN')
  returning cooperative_id into v_coop;
  if not found then raise exception 'User not found'; end if;
  perform public.write_audit(v_coop, 'ADMIN_ASSIGNED', 'profile', p_user, jsonb_build_object('permissions', p_permissions));
end $$;

create or replace function public.get_join_code() returns text
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.has_permission('MANAGE_MEMBERS') then raise exception 'Not authorised'; end if;
  select join_code into v from public.cooperatives where id = public.my_coop();
  return v;
end $$;

create or replace function public.rotate_join_code() returns text
language plpgsql security definer set search_path = public as $$
declare v text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
begin
  if not public.has_permission('MANAGE_MEMBERS') then raise exception 'Not authorised'; end if;
  update public.cooperatives set join_code = v where id = public.my_coop();
  perform public.write_audit(public.my_coop(), 'JOIN_CODE_ROTATED', 'cooperative', public.my_coop());
  return v;
end $$;

-- New sign-ups start inactive. An admin activates them (or suspends them later).
create or replace function public.set_member_active(p_member uuid, p_active boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_permission('MANAGE_MEMBERS') then raise exception 'Not authorised'; end if;
  update public.profiles set is_active = p_active, updated_at = now()
   where id = p_member and cooperative_id = public.my_coop() and role = 'MEMBER';
  if not found then raise exception 'Member not found'; end if;
  perform public.write_audit(public.my_coop(), case when p_active then 'MEMBER_ACTIVATED' else 'MEMBER_SUSPENDED' end,
                             'profile', p_member);
end $$;

-- -----------------------------------------------------------------------------
-- 8. LOAN FUNCTIONS
-- -----------------------------------------------------------------------------
create or replace function public.apply_loan(
  p_amount bigint,
  p_term_months int,
  p_loan_type text default 'DEVELOPMENT',
  p_purpose text default 'General',
  p_guarantor_ids uuid[] default '{}'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_me public.profiles; v_loan_id uuid; v_g uuid;
begin
  select * into v_me from public.profiles where id = auth.uid();
  if not found or v_me.role <> 'MEMBER' or not v_me.is_active then
    raise exception 'Only active members can apply for loans';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid amount'; end if;
  if p_loan_type not in ('EMERGENCY','DEVELOPMENT','SCHOOL_FEES','ASSET_ACQUISITION') then
    raise exception 'Invalid loan type';
  end if;
  if not exists (select 1 from public.loan_policies
                  where cooperative_id = v_me.cooperative_id and term_months = p_term_months and is_active) then
    raise exception 'Your cooperative does not offer this repayment term';
  end if;

  perform pg_advisory_xact_lock(hashtext(auth.uid()::text));  -- stops double-submit races
  if exists (select 1 from public.loan_applications
              where applicant_id = auth.uid()
                and status in ('PENDING','UNDER_REVIEW','APPROVED','DISBURSED','ACTIVE')) then
    raise exception 'You already have a loan in progress';
  end if;
  -- TODO (Phase 8): enforce a maximum loan as a multiple of savings.

  insert into public.loan_applications
    (applicant_id, cooperative_id, loan_type, status, amount_requested, repayment_period_months, purpose)
  values
    (auth.uid(), v_me.cooperative_id, p_loan_type, 'PENDING', p_amount, p_term_months,
     left(coalesce(nullif(trim(p_purpose), ''), 'General'), 500))
  returning id into v_loan_id;

  for v_g in select distinct g from unnest(p_guarantor_ids) g loop
    if v_g = auth.uid() then raise exception 'You cannot guarantee your own loan'; end if;
    insert into public.loan_guarantors (loan_id, member_id, full_name, cooperative_id)
    select v_loan_id, id, full_name, cooperative_id from public.profiles
     where id = v_g and cooperative_id = v_me.cooperative_id and role = 'MEMBER' and is_active;
    if not found then raise exception 'Invalid guarantor'; end if;
  end loop;

  return v_loan_id;
end $$;

create or replace function public.guarantor_respond(p_loan_id uuid, p_approve boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.loan_guarantors g
     set has_approved = p_approve,
         approved_at = case when p_approve then now() else null end
    from public.loan_applications l
   where g.loan_id = p_loan_id and g.member_id = auth.uid()
     and l.id = g.loan_id and l.status in ('PENDING','UNDER_REVIEW');
  if not found then raise exception 'No pending guarantee request found'; end if;
end $$;

create or replace function public.approve_loan(p_loan_id uuid, p_amount bigint)
returns public.loan_applications
language plpgsql security definer set search_path = public as $$
declare v_loan public.loan_applications; v_rate int;
begin
  if not public.has_permission('APPROVE_LOANS') then raise exception 'Not authorised'; end if;
  select * into v_loan from public.loan_applications
   where id = p_loan_id and cooperative_id = public.my_coop() for update;
  if not found then raise exception 'Loan not found'; end if;
  if v_loan.applicant_id = auth.uid() then raise exception 'You cannot approve your own loan'; end if;
  if v_loan.status not in ('PENDING','UNDER_REVIEW') then raise exception 'Loan is not awaiting review'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > v_loan.amount_requested then
    raise exception 'Invalid approved amount';
  end if;
  if exists (select 1 from public.loan_guarantors where loan_id = p_loan_id and not has_approved) then
    raise exception 'Waiting for guarantor approval';
  end if;
  select rate_bps into v_rate from public.loan_policies
   where cooperative_id = v_loan.cooperative_id
     and term_months = v_loan.repayment_period_months and is_active;
  if v_rate is null then raise exception 'No active loan policy for this term'; end if;

  update public.loan_applications
     set status = 'APPROVED', amount_approved = p_amount, interest_rate_bps = v_rate,
         approved_by = auth.uid(), approved_at = now(), updated_at = now()
   where id = p_loan_id
  returning * into v_loan;
  perform public.write_audit(v_loan.cooperative_id, 'LOAN_APPROVED', 'loan_application', v_loan.id,
                             jsonb_build_object('amount', p_amount, 'rate_bps', v_rate));
  return v_loan;
end $$;

create or replace function public.reject_loan(p_loan_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_loan public.loan_applications;
begin
  if not public.has_permission('APPROVE_LOANS') then raise exception 'Not authorised'; end if;
  select * into v_loan from public.loan_applications
   where id = p_loan_id and cooperative_id = public.my_coop() for update;
  if not found then raise exception 'Loan not found'; end if;
  if v_loan.status not in ('PENDING','UNDER_REVIEW') then raise exception 'Loan is not awaiting review'; end if;
  update public.loan_applications set status = 'REJECTED', updated_at = now() where id = p_loan_id;
  perform public.write_audit(v_loan.cooperative_id, 'LOAN_REJECTED', 'loan_application', p_loan_id,
                             jsonb_build_object('reason', left(coalesce(p_reason, ''), 500)));
end $$;

-- -----------------------------------------------------------------------------
-- 9. apply_deposit(): same behaviour as 0002, plus amount validation and
--    explicit tenant stamping. Money that arrives is always credited, even to a
--    suspended member, so funds are never stranded.
-- -----------------------------------------------------------------------------
create or replace function public.apply_deposit(
  p_member_id uuid, p_amount bigint, p_external_reference text, p_narration text
) returns public.transactions
language plpgsql security definer set search_path = public as $$
declare v_ledger public.savings_ledger; v_transaction public.transactions;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'Invalid deposit amount'; end if;

  select * into v_transaction from public.transactions where external_reference = p_external_reference;
  if found then return v_transaction; end if;

  select * into v_ledger from public.savings_ledger
   where member_id = p_member_id order by created_at asc limit 1 for update;
  if not found then raise exception 'No savings ledger found for member %', p_member_id; end if;

  update public.savings_ledger
     set balance = balance + p_amount, last_transaction_at = now(), updated_at = now()
   where id = v_ledger.id;

  insert into public.transactions
    (member_id, cooperative_id, type, status, amount, balance_after,
     reference_account, reference_id, narration, processed_by, external_reference)
  values
    (p_member_id, v_ledger.cooperative_id, 'DEPOSIT', 'COMPLETED', p_amount,
     v_ledger.balance + p_amount, 'SAVINGS', v_ledger.id, p_narration, null, p_external_reference)
  returning * into v_transaction;
  return v_transaction;
exception
  when unique_violation then
    select * into v_transaction from public.transactions where external_reference = p_external_reference;
    return v_transaction;
end $$;

-- -----------------------------------------------------------------------------
-- 10. FUNCTION PERMISSIONS
-- -----------------------------------------------------------------------------
-- Internal / trusted-backend only
revoke execute on function
  public.write_audit(uuid, text, text, uuid, jsonb),
  public.fill_coop_from_member(), public.fill_coop_from_applicant(), public.fill_coop_from_loan(),
  public.apply_deposit(uuid, bigint, text, text)
from public, anon, authenticated;
grant execute on function public.apply_deposit(uuid, bigint, text, text) to service_role;

-- Callable by signed-in users (each function checks the caller's role itself)
revoke execute on function
  public.my_coop(), public.is_platform_admin(), public.is_coop_admin(), public.has_permission(text),
  public.create_cooperative(text, text), public.assign_coop_admin(uuid, text[]),
  public.get_join_code(), public.rotate_join_code(), public.set_member_active(uuid, boolean),
  public.apply_loan(bigint, int, text, text, uuid[]), public.guarantor_respond(uuid, boolean),
  public.approve_loan(uuid, bigint), public.reject_loan(uuid, text)
from public, anon;
grant execute on function
  public.my_coop(), public.is_platform_admin(), public.is_coop_admin(), public.has_permission(text),
  public.create_cooperative(text, text), public.assign_coop_admin(uuid, text[]),
  public.get_join_code(), public.rotate_join_code(), public.set_member_active(uuid, boolean),
  public.apply_loan(bigint, int, text, text, uuid[]), public.guarantor_respond(uuid, boolean),
  public.approve_loan(uuid, bigint), public.reject_loan(uuid, text)
to authenticated;

-- -----------------------------------------------------------------------------
-- BOOTSTRAP (run once, by hand, in the SQL editor, replacing the email):
--
--   update public.profiles
--      set role = 'PLATFORM_ADMIN', cooperative_id = null, is_active = true
--    where email = 'you@example.com';
--
-- Then, signed in as that user, create tenants with:
--   select * from public.create_cooperative('Example Cooperative', 'REG-123');
-- =============================================================================
