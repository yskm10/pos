-- POSで来店客(顧客)を選べるようにする / 顧客別売上のための土台
-- ・売上(sales)とテーブル(tables)に customer_id を追加(任意)
-- ・顧客の検索(POSの全役割) / 新規登録(店主・店長のみ) / 統合(店主のみ)

alter table public.sales  add column if not exists customer_id bigint references public.customers(id) on delete set null;
alter table public.tables add column if not exists customer_id bigint references public.customers(id) on delete set null;
create index if not exists sales_customer_idx on public.sales(customer_id) where customer_id is not null;

-- 役割の判定
create or replace function public.can_pick_customer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.auth_user_id = auth.uid() and s.active and s.role in ('owner','manager','staff','register'));
$$;
create or replace function public.can_register_customer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.auth_user_id = auth.uid() and s.active and s.role in ('owner','manager'));
$$;

-- 検索: 名前・かな(空白を無視)の部分一致、または電話番号(8桁以上の数字)の完全一致。最大10件。
-- 返す項目は id・名前・かな・状態のみ(電話番号・メモ・売上は返さない)
create or replace function public.pos_search_customers(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text; d text; r jsonb;
begin
  if not can_pick_customer() then return '[]'::jsonb; end if;
  q := regexp_replace(coalesce(p_q,''), '[\s　]', '', 'g');
  d := norm_phone(p_q);
  if length(d) >= 8 and length(d) >= length(q) - 2 then
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'kana', kana, 'status', status)), '[]'::jsonb)
      into r from customers where phone = d;
    return r;
  end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  q := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_');
  select coalesce(jsonb_agg(x), '[]'::jsonb) into r from (
    select jsonb_build_object('id', id, 'name', name, 'kana', kana, 'status', status) x
    from customers
    where regexp_replace(name, '[\s　]', '', 'g') ilike '%' || q || '%'
       or regexp_replace(coalesce(kana,''), '[\s　]', '', 'g') ilike '%' || q || '%'
    order by updated_at desc nulls last, id desc limit 10) t;
  return r;
end $$;

-- id から名前を引く(テーブルに付いているお客様の表示用)
create or replace function public.pos_get_customers(p_ids bigint[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not can_pick_customer() then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'status', status)), '[]'::jsonb)
    into r from customers where id = any(p_ids);
  return r;
end $$;

-- 新規登録(店主・店長のみ)。電話番号は任意。同じ電話番号が既にあれば、その人を返す。
create or replace function public.pos_create_customer(p_last text, p_first text, p_kana text, p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l text; f text; d text; c customers%rowtype; nm text;
begin
  if not can_register_customer() then return jsonb_build_object('ok', false, 'code', 'forbidden'); end if;
  l := nullif(btrim(coalesce(p_last,'')), ''); f := nullif(btrim(coalesce(p_first,'')), '');
  if l is null then return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', '姓を入力してください'); end if;
  d := norm_phone(p_phone);
  if d <> '' and length(d) < 8 then return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', '電話番号は8桁以上で入力してください'); end if;
  if d <> '' then
    select * into c from customers where phone = d;
    if found then return jsonb_build_object('ok', true, 'existing', true, 'id', c.id, 'name', c.name); end if;
  end if;
  nm := l || case when f is null then '' else '　' || f end;
  insert into customers (name, last_name, first_name, kana, phone)
    values (nm, l, f, nullif(btrim(coalesce(p_kana,'')), ''), nullif(d, ''))
    returning * into c;
  return jsonb_build_object('ok', true, 'existing', false, 'id', c.id, 'name', c.name);
end $$;

-- 統合(店主のみ): drop を keep にまとめる。電話番号が両方ある場合は別人の可能性があるので拒否。
create or replace function public.merge_customers(p_keep bigint, p_drop bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k customers%rowtype; d customers%rowtype; ph text; rk int; rd int;
begin
  if not is_owner() then return jsonb_build_object('ok', false, 'code', 'forbidden'); end if;
  if p_keep is null or p_drop is null or p_keep = p_drop then return jsonb_build_object('ok', false, 'code', 'bad_request'); end if;
  select * into k from customers where id = p_keep for update;
  select * into d from customers where id = p_drop for update;
  if k.id is null or d.id is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if k.phone is not null and d.phone is not null then
    return jsonb_build_object('ok', false, 'code', 'both_phone', 'message', '電話番号が両方に登録されています(別人の可能性があるため統合できません)');
  end if;
  ph := coalesce(k.phone, d.phone);
  rk := case k.status when 'stopped' then 2 when 'caution' then 1 else 0 end;
  rd := case d.status when 'stopped' then 2 when 'caution' then 1 else 0 end;
  update sales        set customer_id = p_keep where customer_id = p_drop;
  update tables       set customer_id = p_keep where customer_id = p_drop;
  update reservations set customer_id = p_keep where customer_id = p_drop;
  update customers set phone = null where id = p_drop;
  update customers set
    phone = ph,
    kana = coalesce(kana, d.kana),
    notes = nullif(concat_ws(E'\n', notes, case when d.notes is not null then '(統合) ' || d.notes end), ''),
    status = case when rd > rk then d.status else status end,
    status_reason = case when rd > rk then d.status_reason else status_reason end,
    updated_at = now()
   where id = p_keep;
  delete from customers where id = p_drop;
  return jsonb_build_object('ok', true);
end $$;

-- 権限(ログインなしでは呼べない)
revoke all on function public.can_pick_customer(), public.can_register_customer(),
  public.pos_search_customers(text), public.pos_get_customers(bigint[]),
  public.pos_create_customer(text,text,text,text), public.merge_customers(bigint,bigint) from public, anon;
grant execute on function public.can_pick_customer(), public.can_register_customer(),
  public.pos_search_customers(text), public.pos_get_customers(bigint[]),
  public.pos_create_customer(text,text,text,text), public.merge_customers(bigint,bigint) to authenticated;
