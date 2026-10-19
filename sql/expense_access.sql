-- 経費帳(小口現金・取引先分類)を店主・経理のみに制限する
create or replace function public.can_use_expense() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.auth_user_id = auth.uid() and s.active and s.role in ('owner','accounting'));
$$;
revoke all on function public.can_use_expense() from public, anon;
grant execute on function public.can_use_expense() to authenticated;

drop policy if exists auth_all_petty_cash on public.petty_cash;
create policy "小口現金:店主・経理のみ" on public.petty_cash for all to authenticated using (can_use_expense()) with check (can_use_expense());

drop policy if exists auth_all_vendor_map on public.vendor_category_map;
create policy "取引先分類:店主・経理のみ" on public.vendor_category_map for all to authenticated using (can_use_expense()) with check (can_use_expense());

-- 税理士(全件を閲覧のみ)/ 経理(自分が登録した分だけ)の分離
-- 経理=accountingのまま、expenses は元の「本人または app_admins」のまま。
-- 税理士だけ、expense_viewers に登録して全件を「閲覧のみ」にする(変更・削除はできない)。
create table if not exists public.expense_viewers (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.expense_viewers enable row level security;  -- ポリシー無し=直接は誰も読めない(関数経由のみ)

create or replace function public.is_expense_viewer() returns boolean
language sql stable security definer set search_path = public as $$
  select can_use_expense() and exists (select 1 from expense_viewers v where v.user_id = auth.uid());
$$;
revoke all on function public.is_expense_viewer() from public, anon;
grant execute on function public.is_expense_viewer() to authenticated;

drop policy if exists "経費:税理士は全件閲覧" on public.expenses;
create policy "経費:税理士は全件閲覧" on public.expenses for select to authenticated using (is_expense_viewer());

drop policy if exists "領収書:税理士は全件閲覧" on storage.objects;
create policy "領収書:税理士は全件閲覧" on storage.objects for select to authenticated using (bucket_id = 'receipts' and is_expense_viewer());

-- 山本税理士を登録
insert into public.expense_viewers (user_id) select auth_user_id from public.staff where id = 9 and role = 'accounting' and auth_user_id is not null on conflict do nothing;
