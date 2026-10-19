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
