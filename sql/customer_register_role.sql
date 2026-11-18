-- 顧客の新規登録をレジ(register)でもできるようにする
create or replace function public.can_register_customer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.auth_user_id = auth.uid() and s.active and s.role in ('owner','manager','register'));
$$;
