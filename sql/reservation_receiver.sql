-- 予約の「受付者」(2026-10-19)
alter table public.reservations add column received_by_staff_id int;

create or replace function public.set_reservation_receiver(p_id bigint, p_staff_id int) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not can_use_reservations() then return json_build_object('ok', false, 'code', 'forbidden'); end if;
  if not exists (select 1 from staff where id = p_staff_id and active and role in ('owner','manager','staff')) then
    return json_build_object('ok', false, 'code', 'bad_request');
  end if;
  update reservations set received_by_staff_id = p_staff_id where id = p_id;
  return json_build_object('ok', true);
end $$;

revoke all on function public.set_reservation_receiver(bigint, int) from public, anon;
grant execute on function public.set_reservation_receiver(bigint, int) to authenticated;
