-- お客様の電話番号を後から登録・訂正する(店主・店長・レジ)。同じ番号が別のお客様にあれば登録せず、その人を知らせる。
create or replace function public.set_customer_phone(p_id bigint, p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d text; o customers%rowtype;
begin
  if not can_register_customer() then return jsonb_build_object('ok', false, 'code', 'forbidden'); end if;
  d := norm_phone(p_phone);
  if length(d) < 8 then return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', '電話番号は8桁以上で入力してください'); end if;
  select * into o from customers where phone = d and id <> p_id;
  if found then return jsonb_build_object('ok', false, 'code', 'duplicate', 'id', o.id, 'name', o.name); end if;
  update customers set phone = d, updated_at = now() where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.set_customer_phone(bigint, text) from public, anon;
grant execute on function public.set_customer_phone(bigint, text) to authenticated;
