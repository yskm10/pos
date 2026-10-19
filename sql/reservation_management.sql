-- 予約管理(2026-10-19)。Supabase の SQL Editor にそのまま貼り付けて実行する
create or replace function public.can_use_reservations() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where auth_user_id = auth.uid() and active and role in ('owner','manager','staff','register'));
$$;

create or replace function public.norm_phone(p text) returns text
language sql immutable as $$
  select regexp_replace(translate(coalesce(p,''), '０１２３４５６７８９', '0123456789'), '\D', '', 'g');
$$;

create table public.reservation_config (
  id int primary key default 1 check (id = 1),
  course_day_before_pct int not null default 50,
  course_same_day_pct int not null default 100,
  private_days int not null default 3,
  private_pct int not null default 100,
  normal_minutes int not null default 120,
  course_minutes int not null default 150,
  private_minutes int not null default 180,
  timeline_start_min int not null default 960,
  timeline_end_min int not null default 1560
);
insert into public.reservation_config (id) values (1);

create table public.customers (
  id bigint generated always as identity primary key,
  name text not null,
  kana text,
  phone text unique,
  notes text,
  status text not null default 'normal' check (status in ('normal','caution','stopped')),
  status_reason text,
  status_changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.reservations (
  id bigint generated always as identity primary key,
  customer_id bigint references public.customers(id),
  guest_name text not null,
  guest_phone text,
  business_date date not null,
  start_min int not null check (start_min >= 0 and start_min < 2400),
  end_min int not null,
  party_size int not null check (party_size > 0),
  kind text not null default 'normal' check (kind in ('normal','course','private')),
  course_name text,
  amount int,
  all_tables boolean not null default false,
  channel text not null default 'phone' check (channel in ('phone','line','walkin','other')),
  status text not null default 'reserved' check (status in ('reserved','seated','done','cancelled','no_show','same_day_no_show')),
  memo text,
  created_by_staff_id int,
  cancelled_at timestamptz,
  fee_pct int,
  fee_amount int,
  fee_status text not null default 'none' check (fee_status in ('none','unbilled','billed','paid','waived')),
  fee_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_min > start_min)
);
create index reservations_date_idx on public.reservations (business_date);
create index reservations_customer_idx on public.reservations (customer_id);

create table public.reservation_tables (
  reservation_id bigint not null references public.reservations(id) on delete cascade,
  table_id text not null,
  table_name text,
  primary key (reservation_id, table_id)
);

create table public.reservation_history (
  id bigint generated always as identity primary key,
  reservation_id bigint not null,
  action text not null,
  changed_at timestamptz not null default now(),
  changed_by int,
  old_row jsonb,
  new_row jsonb
);

alter table public.reservation_config enable row level security;
alter table public.customers enable row level security;
alter table public.reservations enable row level security;
alter table public.reservation_tables enable row level security;
alter table public.reservation_history enable row level security;

create policy "予約設定:閲覧" on public.reservation_config for select using (can_use_reservations());
create policy "予約設定:店主のみ更新" on public.reservation_config for update using (is_owner()) with check (is_owner());
create policy "顧客:店主のみ" on public.customers for all using (is_owner()) with check (is_owner());
create policy "予約:閲覧" on public.reservations for select using (can_use_reservations());
create policy "予約席:閲覧" on public.reservation_tables for select using (can_use_reservations());
create policy "予約履歴:店主のみ閲覧" on public.reservation_history for select using (is_owner());

create or replace function public.log_reservation_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into reservation_history(reservation_id, action, changed_by, new_row) values (new.id, 'insert', my_staff_id(), to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    insert into reservation_history(reservation_id, action, changed_by, old_row, new_row) values (new.id, 'update', my_staff_id(), to_jsonb(old), to_jsonb(new));
    return new;
  else
    insert into reservation_history(reservation_id, action, changed_by, old_row) values (old.id, 'delete', my_staff_id(), to_jsonb(old));
    return old;
  end if;
end $$;
create trigger reservations_log after insert or update or delete on public.reservations
  for each row execute function public.log_reservation_change();

create or replace function public.lookup_customer(p_phone text) returns json
language plpgsql stable security definer set search_path = public as $$
declare c customers%rowtype; d text; r json;
begin
  if not can_use_reservations() then return json_build_object('found', false); end if;
  d := norm_phone(p_phone);
  if length(d) < 8 then return json_build_object('found', false); end if;
  select * into c from customers where phone = d;
  if not found then return json_build_object('found', false); end if;
  select json_build_object(
    'found', true, 'name', c.name, 'status', c.status, 'reason', c.status_reason,
    'no_show', count(*) filter (where status = 'no_show'),
    'same_day_no_show', count(*) filter (where status = 'same_day_no_show'),
    'cancelled', count(*) filter (where status = 'cancelled'),
    'visits', count(*) filter (where status in ('seated','done')),
    'last_incident', max(business_date) filter (where status in ('no_show','same_day_no_show')),
    'names', (select coalesce(json_agg(n), '[]'::json) from (select distinct guest_name n from reservations where customer_id = c.id limit 5) x)
  ) into r from reservations where customer_id = c.id;
  return r;
end $$;

create or replace function public.save_reservation(p_id bigint, p jsonb, p_force boolean default false, p_override_reason text default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_phone text; c customers%rowtype; v_cid bigint; v_id bigint;
  v_date date; v_s int; v_e int; v_all boolean; v_party int; v_kind text;
  v_tables jsonb; v_conf json; v_memo text; v_name text;
begin
  if not can_use_reservations() then return json_build_object('ok', false, 'code', 'forbidden'); end if;
  v_name := btrim(coalesce(p->>'guest_name', ''));
  v_date := (p->>'business_date')::date;
  v_s := (p->>'start_min')::int; v_e := (p->>'end_min')::int;
  v_party := (p->>'party_size')::int;
  v_kind := coalesce(p->>'kind', 'normal');
  v_all := coalesce((p->>'all_tables')::boolean, false);
  v_tables := coalesce(p->'tables', '[]'::jsonb);
  v_memo := nullif(p->>'memo', '');
  if v_name = '' or v_date is null or v_s is null or v_e is null or v_party is null or v_e <= v_s or v_party <= 0 then
    return json_build_object('ok', false, 'code', 'bad_request');
  end if;
  if v_kind = 'private' then v_all := true; end if;

  v_phone := norm_phone(p->>'guest_phone');
  if length(v_phone) >= 8 then
    select * into c from customers where phone = v_phone;
    if not found then
      insert into customers(name, phone) values (v_name, v_phone) returning * into c;
    end if;
    v_cid := c.id;
    if c.status = 'stopped' then
      if not is_owner() then
        return json_build_object('ok', false, 'code', 'stopped', 'reason', c.status_reason);
      end if;
      if coalesce(btrim(p_override_reason), '') = '' then
        return json_build_object('ok', false, 'code', 'stopped_need_reason', 'reason', c.status_reason);
      end if;
      v_memo := coalesce(v_memo || E'\n', '') || '[受付停止中を解除して受付: ' || btrim(p_override_reason) || ']';
    end if;
  end if;

  if not p_force then
    select coalesce(json_agg(json_build_object('id', r.id, 'guest_name', r.guest_name, 'start_min', r.start_min, 'end_min', r.end_min)), '[]'::json) into v_conf
    from reservations r
    where r.business_date = v_date and r.status in ('reserved','seated')
      and r.id is distinct from p_id
      and r.start_min < v_e and r.end_min > v_s
      and (r.all_tables or v_all
           or exists (select 1 from reservation_tables rt
                      where rt.reservation_id = r.id
                        and rt.table_id in (select x->>'id' from jsonb_array_elements(v_tables) x)));
    if json_array_length(v_conf) > 0 then
      return json_build_object('ok', false, 'code', 'conflict', 'conflicts', v_conf);
    end if;
  end if;

  if p_id is null then
    insert into reservations(customer_id, guest_name, guest_phone, business_date, start_min, end_min, party_size, kind, course_name, amount, all_tables, channel, memo, created_by_staff_id)
    values (v_cid, v_name, nullif(btrim(coalesce(p->>'guest_phone','')), ''), v_date, v_s, v_e, v_party, v_kind, nullif(p->>'course_name',''), nullif(p->>'amount','')::int, v_all, coalesce(p->>'channel','phone'), v_memo, my_staff_id())
    returning id into v_id;
  else
    update reservations set customer_id = v_cid, guest_name = v_name, guest_phone = nullif(btrim(coalesce(p->>'guest_phone','')), ''),
      business_date = v_date, start_min = v_s, end_min = v_e, party_size = v_party, kind = v_kind,
      course_name = nullif(p->>'course_name',''), amount = nullif(p->>'amount','')::int, all_tables = v_all,
      channel = coalesce(p->>'channel','phone'), memo = v_memo, updated_at = now()
    where id = p_id returning id into v_id;
    if v_id is null then return json_build_object('ok', false, 'code', 'not_found'); end if;
    delete from reservation_tables where reservation_id = v_id;
  end if;

  if not v_all then
    insert into reservation_tables(reservation_id, table_id, table_name)
    select v_id, x->>'id', x->>'name' from jsonb_array_elements(v_tables) x
    on conflict do nothing;
  end if;
  return json_build_object('ok', true, 'id', v_id);
end $$;

create or replace function public.set_reservation_status(p_id bigint, p_status text) returns json
language plpgsql security definer set search_path = public as $$
declare r reservations%rowtype; cfg reservation_config%rowtype; v_today date; v_days int; v_pct int := 0; v_fee int; v_cancel boolean;
begin
  if not can_use_reservations() then return json_build_object('ok', false, 'code', 'forbidden'); end if;
  if p_status not in ('reserved','seated','done','cancelled','no_show','same_day_no_show') then
    return json_build_object('ok', false, 'code', 'bad_request');
  end if;
  select * into r from reservations where id = p_id;
  if not found then return json_build_object('ok', false, 'code', 'not_found'); end if;
  select * into cfg from reservation_config where id = 1;
  v_cancel := p_status in ('cancelled','no_show','same_day_no_show');
  if v_cancel then
    v_today := ((now() at time zone 'Asia/Tokyo') - interval '7 hours')::date;
    v_days := r.business_date - v_today;
    if r.kind = 'course' then
      if p_status <> 'cancelled' then v_pct := cfg.course_same_day_pct;
      elsif v_days >= 2 then v_pct := 0;
      elsif v_days = 1 then v_pct := cfg.course_day_before_pct;
      else v_pct := cfg.course_same_day_pct; end if;
    elsif r.kind = 'private' then
      if p_status <> 'cancelled' or v_days <= cfg.private_days then v_pct := cfg.private_pct; end if;
    end if;
    v_fee := case when r.amount is not null then round(r.amount * v_pct / 100.0)::int else null end;
    update reservations set status = p_status, cancelled_at = coalesce(cancelled_at, now()), fee_pct = v_pct, fee_amount = v_fee,
      fee_status = case when v_pct > 0 then 'unbilled' else 'none' end, updated_at = now() where id = p_id;
    return json_build_object('ok', true, 'fee_pct', v_pct, 'fee_amount', v_fee);
  else
    update reservations set status = p_status, updated_at = now(),
      cancelled_at = case when r.status in ('cancelled','no_show','same_day_no_show') then null else cancelled_at end,
      fee_pct = case when r.fee_status in ('none','unbilled') then null else fee_pct end,
      fee_amount = case when r.fee_status in ('none','unbilled') then null else fee_amount end,
      fee_status = case when r.fee_status in ('none','unbilled') then 'none' else fee_status end
    where id = p_id;
    return json_build_object('ok', true);
  end if;
end $$;

create or replace function public.set_reservation_fee(p_id bigint, p_amount int, p_status text, p_note text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_attendance_admin() then return json_build_object('ok', false, 'code', 'forbidden'); end if;
  if p_status not in ('none','unbilled','billed','paid','waived') then return json_build_object('ok', false, 'code', 'bad_request'); end if;
  update reservations set fee_amount = p_amount, fee_status = p_status, fee_note = nullif(p_note, ''), updated_at = now() where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.delete_reservation(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not is_attendance_admin() then return json_build_object('ok', false, 'code', 'forbidden'); end if;
  delete from reservations where id = p_id;
  return json_build_object('ok', true);
end $$;

revoke all on function public.can_use_reservations(), public.lookup_customer(text), public.save_reservation(bigint, jsonb, boolean, text),
  public.set_reservation_status(bigint, text), public.set_reservation_fee(bigint, int, text, text), public.delete_reservation(bigint),
  public.log_reservation_change() from public, anon;
grant execute on function public.can_use_reservations(), public.lookup_customer(text), public.save_reservation(bigint, jsonb, boolean, text),
  public.set_reservation_status(bigint, text), public.set_reservation_fee(bigint, int, text, text), public.delete_reservation(bigint) to authenticated;
grant select on public.reservation_config, public.reservations, public.reservation_tables, public.reservation_history to authenticated;
grant update on public.reservation_config to authenticated;
grant select, insert, update, delete on public.customers to authenticated;
