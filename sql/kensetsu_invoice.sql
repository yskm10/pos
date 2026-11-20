-- 建設の請求書(発行=売上 / 受取=支払い)。飲食の経費帳とは別のテーブル・別ページ。
-- 閲覧: 経理=自分の登録分、店主=全件、税理士(expense_viewers)=全件を閲覧のみ
create table if not exists public.construction_invoices (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('issued','received')),
  invoice_date date not null,
  due_date date,
  party text not null,
  project text,
  invoice_no text,
  amount numeric not null,
  tax numeric,
  status text not null default 'unpaid' check (status in ('unpaid','paid')),
  paid_date date,
  memo text,
  file_ext text,
  created_by uuid default auth.uid(),
  created_at timestamptz default now()
);
create index if not exists construction_invoices_date_idx on public.construction_invoices(invoice_date);
alter table public.construction_invoices enable row level security;

drop policy if exists "建設請求書:閲覧" on public.construction_invoices;
create policy "建設請求書:閲覧" on public.construction_invoices for select to authenticated
  using (can_use_expense() and (created_by = auth.uid() or is_owner() or is_expense_viewer()));
drop policy if exists "建設請求書:登録" on public.construction_invoices;
create policy "建設請求書:登録" on public.construction_invoices for insert to authenticated
  with check (can_use_expense() and created_by = auth.uid());
drop policy if exists "建設請求書:変更" on public.construction_invoices;
create policy "建設請求書:変更" on public.construction_invoices for update to authenticated
  using (can_use_expense() and (created_by = auth.uid() or is_owner()));
drop policy if exists "建設請求書:削除" on public.construction_invoices;
create policy "建設請求書:削除" on public.construction_invoices for delete to authenticated
  using (can_use_expense() and (created_by = auth.uid() or is_owner()));

-- 請求書の原本(PDF・写真)の保管場所(非公開)。ファイル名は「請求書のid.拡張子」
insert into storage.buckets (id, name, public) values ('kensetsu-invoices', 'kensetsu-invoices', false) on conflict (id) do nothing;

drop policy if exists "建設請求書ファイル:閲覧" on storage.objects;
create policy "建設請求書ファイル:閲覧" on storage.objects for select to authenticated
  using (bucket_id = 'kensetsu-invoices' and exists (select 1 from public.construction_invoices c where c.id::text = split_part(name, '.', 1)));
drop policy if exists "建設請求書ファイル:登録" on storage.objects;
create policy "建設請求書ファイル:登録" on storage.objects for insert to authenticated
  with check (bucket_id = 'kensetsu-invoices' and exists (select 1 from public.construction_invoices c where c.id::text = split_part(name, '.', 1) and c.created_by = auth.uid()));
drop policy if exists "建設請求書ファイル:削除" on storage.objects;
create policy "建設請求書ファイル:削除" on storage.objects for delete to authenticated
  using (bucket_id = 'kensetsu-invoices' and exists (select 1 from public.construction_invoices c where c.id::text = split_part(name, '.', 1) and (c.created_by = auth.uid() or is_owner())));
