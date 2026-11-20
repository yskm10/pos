-- 預り金(コンペ参加費など): 入金の記録とコンペ名ごとの残り
-- ・expenses.group_name: 預り金の支出がどのコンペのものか
-- ・deposit_in: 預り金の入金(参加者から受け取った分)
alter table public.expenses add column if not exists group_name text;

create table if not exists public.deposit_in (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  amount numeric not null check (amount > 0),
  group_name text not null,
  memo text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
alter table public.deposit_in enable row level security;

drop policy if exists "預り金入金:閲覧" on public.deposit_in;
create policy "預り金入金:閲覧" on public.deposit_in for select to authenticated
  using (can_use_expense() and (created_by = auth.uid() or is_owner() or is_expense_viewer()));
drop policy if exists "預り金入金:登録" on public.deposit_in;
create policy "預り金入金:登録" on public.deposit_in for insert to authenticated
  with check (can_use_expense() and created_by = auth.uid());
drop policy if exists "預り金入金:変更" on public.deposit_in;
create policy "預り金入金:変更" on public.deposit_in for update to authenticated
  using (can_use_expense() and (created_by = auth.uid() or is_owner()));
drop policy if exists "預り金入金:削除" on public.deposit_in;
create policy "預り金入金:削除" on public.deposit_in for delete to authenticated
  using (can_use_expense() and (created_by = auth.uid() or is_owner()));
