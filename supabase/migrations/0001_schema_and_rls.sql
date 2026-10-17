-- =============================================================================
-- Phase 2: Core schema + Row-Level Security
-- Mirrors src/types/cooperative.ts. Money columns are BIGINT (minor currency
-- unit, e.g. kobo/cents) to match MinorCurrencyUnit — never store floats here.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. PROFILES  (extends auth.users — one row per authenticated person)
-- -----------------------------------------------------------------------------
create table public.profiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  email              text not null unique,
  full_name          text not null,
  phone_number       text not null,
  member_number      text not null unique,
  role               text not null check (role in ('MEMBER', 'SUPER_ADMIN')),
  is_active          boolean not null default true,

  -- Member-only fields (null for SUPER_ADMIN rows)
  branch_id          uuid,
  date_joined        timestamptz,
  next_of_kin_name   text,
  next_of_kin_phone  text,

  -- Super-Admin-only field (null for MEMBER rows)
  permissions        text[],

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 2. SAVINGS LEDGER
-- -----------------------------------------------------------------------------
create table public.savings_ledger (
  id                       uuid primary key default gen_random_uuid(),
  member_id                uuid not null references public.profiles(id) on delete cascade,
  account_number           text not null unique,
  account_type             text not null check (account_type in ('REGULAR', 'FIXED_DEPOSIT', 'TARGET_SAVINGS')),
  status                   text not null default 'ACTIVE' check (status in ('ACTIVE', 'DORMANT', 'CLOSED')),
  balance                  bigint not null default 0,
  currency                 text not null default 'NGN',
  annual_interest_rate_bps int not null default 0,
  last_transaction_at      timestamptz,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 3. SHARE CAPITAL
-- -----------------------------------------------------------------------------
create table public.share_capital (
  id                        uuid primary key default gen_random_uuid(),
  member_id                 uuid not null references public.profiles(id) on delete cascade,
  total_shares              int not null default 0,
  share_value               bigint not null,
  total_contributed         bigint not null default 0,
  dividends_earned_to_date  bigint not null default 0,
  last_contribution_at      timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 4. LOAN APPLICATIONS  (+ guarantors as a proper child table)
-- -----------------------------------------------------------------------------
create table public.loan_applications (
  id                       uuid primary key default gen_random_uuid(),
  applicant_id             uuid not null references public.profiles(id) on delete cascade,
  loan_type                text not null check (loan_type in ('EMERGENCY', 'DEVELOPMENT', 'SCHOOL_FEES', 'ASSET_ACQUISITION')),
  status                   text not null default 'PENDING'
                           check (status in ('PENDING','UNDER_REVIEW','APPROVED','REJECTED','DISBURSED','ACTIVE','DEFAULTED','CLOSED')),
  amount_requested         bigint not null,
  amount_approved          bigint,
  interest_rate_bps        int,
  repayment_period_months  int not null,
  purpose                  text not null,
  approved_by              uuid references public.profiles(id),
  approved_at              timestamptz,
  disbursed_at             timestamptz,
  submitted_at             timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

-- Guarantor[] from the TS type becomes its own table here — cleaner to query
-- and lets a guarantor approve their own row under RLS.
create table public.loan_guarantors (
  id            uuid primary key default gen_random_uuid(),
  loan_id       uuid not null references public.loan_applications(id) on delete cascade,
  member_id     uuid not null references public.profiles(id),
  full_name     text not null,
  has_approved  boolean not null default false,
  approved_at   timestamptz
);

-- -----------------------------------------------------------------------------
-- 5. TRANSACTIONS  (the cash book / audit trail)
-- -----------------------------------------------------------------------------
create table public.transactions (
  id                 uuid primary key default gen_random_uuid(),
  member_id          uuid not null references public.profiles(id) on delete cascade,
  type               text not null check (type in
                       ('DEPOSIT','WITHDRAWAL','SHARE_PURCHASE','DIVIDEND_PAYOUT',
                        'LOAN_DISBURSEMENT','LOAN_REPAYMENT','INTEREST_CREDIT','FEE_CHARGE')),
  status             text not null default 'PENDING' check (status in ('PENDING','COMPLETED','FAILED','REVERSED')),
  amount             bigint not null,
  balance_after      bigint not null,
  reference_account  text not null check (reference_account in ('SAVINGS','SHARE_CAPITAL','LOAN')),
  reference_id       uuid not null,
  narration          text not null,
  processed_by       uuid references public.profiles(id),
  created_at         timestamptz not null default now()
);

-- =============================================================================
-- 6. HELPER FUNCTION — the one place "is this user a Super-Admin?" is decided
-- =============================================================================
create or replace function public.is_super_admin()
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'SUPER_ADMIN'
  );
$$;

-- =============================================================================
-- 7. ENABLE RLS — everything is locked down by default until a policy allows it
-- =============================================================================
alter table public.profiles          enable row level security;
alter table public.savings_ledger    enable row level security;
alter table public.share_capital     enable row level security;
alter table public.loan_applications enable row level security;
alter table public.loan_guarantors   enable row level security;
alter table public.transactions      enable row level security;

-- -----------------------------------------------------------------------------
-- PROFILES policies
-- -----------------------------------------------------------------------------
create policy "profiles_select_own_or_admin"
  on public.profiles for select
  using (id = auth.uid() or public.is_super_admin());

create policy "profiles_update_own_or_admin"
  on public.profiles for update
  using (id = auth.uid() or public.is_super_admin());

create policy "profiles_insert_self"
  on public.profiles for insert
  with check (id = auth.uid());

-- -----------------------------------------------------------------------------
-- SAVINGS LEDGER policies — members read-only on their own row; only admins write
-- -----------------------------------------------------------------------------
create policy "savings_select_own_or_admin"
  on public.savings_ledger for select
  using (member_id = auth.uid() or public.is_super_admin());

create policy "savings_write_admin_only"
  on public.savings_ledger for all
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- -----------------------------------------------------------------------------
-- SHARE CAPITAL policies — same pattern
-- -----------------------------------------------------------------------------
create policy "shares_select_own_or_admin"
  on public.share_capital for select
  using (member_id = auth.uid() or public.is_super_admin());

create policy "shares_write_admin_only"
  on public.share_capital for all
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- -----------------------------------------------------------------------------
-- LOAN APPLICATIONS policies — members CAN submit their own application,
-- but only as PENDING; only an admin can move it through the workflow.
-- -----------------------------------------------------------------------------
create policy "loans_select_own_or_admin"
  on public.loan_applications for select
  using (applicant_id = auth.uid() or public.is_super_admin());

create policy "loans_insert_own_pending_only"
  on public.loan_applications for insert
  with check (applicant_id = auth.uid() and status = 'PENDING');

create policy "loans_update_admin_only"
  on public.loan_applications for update
  using (public.is_super_admin())
  with check (public.is_super_admin());

-- -----------------------------------------------------------------------------
-- LOAN GUARANTORS policies — a guarantor can see/approve their own row only
-- -----------------------------------------------------------------------------
create policy "guarantors_select_related_or_admin"
  on public.loan_guarantors for select
  using (
    member_id = auth.uid()
    or public.is_super_admin()
    or exists (
      select 1 from public.loan_applications la
      where la.id = loan_id and la.applicant_id = auth.uid()
    )
  );

create policy "guarantors_approve_own_row"
  on public.loan_guarantors for update
  using (member_id = auth.uid())
  with check (member_id = auth.uid());

create policy "guarantors_insert_admin_only"
  on public.loan_guarantors for insert
  with check (public.is_super_admin());

-- -----------------------------------------------------------------------------
-- TRANSACTIONS policies — the audit trail is read-only for members, admin-write
-- -----------------------------------------------------------------------------
create policy "transactions_select_own_or_admin"
  on public.transactions for select
  using (member_id = auth.uid() or public.is_super_admin());

create policy "transactions_write_admin_only"
  on public.transactions for all
  using (public.is_super_admin())
  with check (public.is_super_admin());
