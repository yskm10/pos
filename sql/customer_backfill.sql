-- 電話番号なしの予約も顧客に登録する
-- 1) 既存の予約(電話番号なし)を顧客に登録して紐付け(同じ名前は同じ人として1件にまとめる)
with n as (
  select distinct on (guest_name) guest_name, last_name, first_name from reservations
  where customer_id is null and guest_phone is null and coalesce(guest_name,'')<>'' order by guest_name, id)
insert into customers(name,last_name,first_name)
select n.guest_name, n.last_name, n.first_name from n
where not exists (select 1 from customers c where c.phone is null and c.name = n.guest_name);

update reservations r set customer_id = c.id
from customers c
where r.customer_id is null and r.guest_phone is null and c.phone is null and c.name = r.guest_name;

-- 2) 今後の予約: 電話番号がなければ、同じ名前の電話番号なしの顧客に紐付け(なければ新規作成)
create or replace function public.save_reservation(p_id bigint, p jsonb, p_force boolean default false, p_override_reason text default null)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare
  v_phone text; c customers%rowtype; v_cid bigint; v_id bigint;
  v_date date; v_s int; v_e int; v_all boolean; v_party int; v_kind text;
  v_tables jsonb; v_conf json; v_memo text; v_name text; v_last text; v_first text;
begin
  if not can_use_reservations() then return json_build_object('ok', false, 'code', 'forbidden'); end if;
  v_last := btrim(coalesce(p->>'last_name', ''));
  v_first := btrim(coalesce(p->>'first_name', ''));
  v_name := v_last || case when v_first <> '' then '　' || v_first else '' end;
  v_date := (p->>'business_date')::date;
  v_s := (p->>'start_min')::int; v_e := (p->>'end_min')::int;
  v_party := (p->>'party_size')::int;
  v_kind := coalesce(p->>'kind', 'normal');
  v_all := coalesce((p->>'all_tables')::boolean, false);
  v_tables := coalesce(p->'tables', '[]'::jsonb);
  v_memo := nullif(p->>'memo', '');
  if v_last = '' or v_date is null or v_s is null or v_e is null or v_party is null or v_e <= v_s or v_party <= 0 then
    return json_build_object('ok', false, 'code', 'bad_request');
  end if;
  if v_kind = 'private' then v_all := true; end if;

  v_phone := norm_phone(p->>'guest_phone');
  if length(v_phone) >= 8 then
    select * into c from customers where phone = v_phone;
    if not found then
      insert into customers(name, last_name, first_name, phone) values (v_name, v_last, nullif(v_first, ''), v_phone) returning * into c;
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
  else
    select * into c from customers where phone is null and name = v_name order by id limit 1;
    if not found then
      insert into customers(name, last_name, first_name) values (v_name, v_last, nullif(v_first, '')) returning * into c;
    end if;
    v_cid := c.id;
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
    insert into reservations(customer_id, guest_name, last_name, first_name, guest_phone, business_date, start_min, end_min, party_size, kind, course_name, amount, all_tables, channel, memo, created_by_staff_id)
    values (v_cid, v_name, v_last, nullif(v_first, ''), nullif(v_phone, ''), v_date, v_s, v_e, v_party, v_kind, nullif(p->>'course_name',''), nullif(p->>'amount','')::int, v_all, coalesce(p->>'channel','phone'), v_memo, my_staff_id())
    returning id into v_id;
  else
    update reservations set customer_id = v_cid, guest_name = v_name, last_name = v_last, first_name = nullif(v_first, ''), guest_phone = nullif(v_phone, ''),
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
end $function$;
