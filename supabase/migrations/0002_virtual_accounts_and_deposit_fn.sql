-- =============================================================================
-- Phase 3 extension: dedicated virtual accounts + idempotent deposit posting
-- =============================================================================

alter table public.profiles
  add column virtual_account_number text unique,
  add column virtual_account_provider text;

-- Stores the payment processor's own event ID. The UNIQUE constraint is what
-- makes deposit processing idempotent: if a webhook fires twice for the same
-- event (processors often retry), the second attempt cannot credit twice.
alter table public.transactions
  add column external_reference text unique;

-- -----------------------------------------------------------------------------
-- apply_deposit(): the ONLY path by which a webhook-driven deposit reaches
-- the ledger. Runs as one atomic operation so the balance update and its
-- transaction record can never end up out of sync with each other.
-- -----------------------------------------------------------------------------
create or replace function public.apply_deposit(
  p_member_id uuid,
  p_amount bigint,
  p_external_reference text,
  p_narration text
)
returns public.transactions
language plpgsql
security definer
as $$
declare
  v_ledger      public.savings_ledger;
  v_transaction public.transactions;
begin
  -- Idempotency check FIRST: if this exact event was already processed,
  -- hand back the existing record instead of crediting the member again.
  select * into v_transaction
  from public.transactions
  where external_reference = p_external_reference;

  if found then
    return v_transaction;
  end if;

  select * into v_ledger
  from public.savings_ledger
  where member_id = p_member_id
  order by created_at asc
  limit 1
  for update; -- locks the row so two concurrent deposits can't race each other

  if not found then
    raise exception 'No savings ledger found for member %', p_member_id;
  end if;

  update public.savings_ledger
  set balance = balance + p_amount,
      last_transaction_at = now(),
      updated_at = now()
  where id = v_ledger.id;

  insert into public.transactions (
    member_id, type, status, amount, balance_after,
    reference_account, reference_id, narration, processed_by, external_reference
  ) values (
    p_member_id, 'DEPOSIT', 'COMPLETED', p_amount, v_ledger.balance + p_amount,
    'SAVINGS', v_ledger.id, p_narration, null, p_external_reference
  )
  returning * into v_transaction;

  return v_transaction;

exception
  -- Backstop for the rare case where two duplicate webhooks slip past the
  -- check above at the same instant — the UNIQUE constraint catches it here.
  when unique_violation then
    select * into v_transaction
    from public.transactions
    where external_reference = p_external_reference;
    return v_transaction;
end;
$$;

-- This function touches ledger balances directly, so it must only be
-- callable by the trusted backend (the webhook function's service-role key)
-- — never by a member's own client, even an authenticated one.
revoke execute on function public.apply_deposit from public, anon, authenticated;
grant execute on function public.apply_deposit to service_role;
