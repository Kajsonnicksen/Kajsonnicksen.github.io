create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.user_data_backups (
  user_id uuid primary key references auth.users(id) on delete cascade,
  snapshot jsonb not null,
  updated_at timestamptz not null default now()
);
alter table private.user_data_backups enable row level security;
revoke all on table private.user_data_backups from public, anon, authenticated;

create or replace function public.refresh_user_data_backup(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if p_user_id is null then
    return;
  end if;

  insert into private.user_data_backups(user_id, snapshot, updated_at)
  values (
    p_user_id,
    jsonb_build_object(
      'version', 1,
      'display_name', (select p.display_name from public.profiles p where p.id = p_user_id),
      'habits', coalesce((
        select jsonb_agg(to_jsonb(h) order by h.position, h.created_at, h.id)
        from public.habits h where h.user_id = p_user_id and h.archived_at is null
      ), '[]'::jsonb),
      'training_plans', coalesce((
        select jsonb_agg(to_jsonb(t) order by t.weekday, t.created_at, t.id)
        from public.training_plans t where t.user_id = p_user_id and t.archived_at is null
      ), '[]'::jsonb),
      'habit_checks', coalesce((
        select jsonb_agg(to_jsonb(hc) order by hc.check_date, hc.id)
        from public.habit_checks hc join public.habits h on h.id = hc.habit_id and h.user_id = hc.user_id where hc.user_id = p_user_id and h.archived_at is null
      ), '[]'::jsonb),
      'training_checks', coalesce((
        select jsonb_agg(to_jsonb(tc) order by tc.week_start, tc.id)
        from public.training_checks tc join public.training_plans t on t.id = tc.training_plan_id and t.user_id = tc.user_id where tc.user_id = p_user_id and t.archived_at is null
      ), '[]'::jsonb),
      'reminders', coalesce((
        select jsonb_agg(to_jsonb(r) order by r.created_at, r.id)
        from public.reminders r where r.user_id = p_user_id
      ), '[]'::jsonb)
    ),
    now()
  )
  on conflict (user_id) do update
  set snapshot = excluded.snapshot,
      updated_at = excluded.updated_at;
end;
$function$;

create or replace function public.capture_user_data_backup_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid;
begin
  if tg_op = 'DELETE' then
    v_user_id := old.user_id;
  else
    v_user_id := new.user_id;
  end if;

  if tg_op = 'UPDATE' and old.user_id is distinct from new.user_id then
    perform public.refresh_user_data_backup(old.user_id);
  end if;

  perform public.refresh_user_data_backup(v_user_id);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

revoke all on function public.refresh_user_data_backup(uuid)
  from public, anon, authenticated;
revoke all on function public.capture_user_data_backup_change()
  from public, anon, authenticated;

drop trigger if exists habits_update_user_backup on public.habits;
create trigger habits_update_user_backup
after insert or update or delete on public.habits
for each row execute function public.capture_user_data_backup_change();

drop trigger if exists training_plans_update_user_backup on public.training_plans;
create trigger training_plans_update_user_backup
after insert or update or delete on public.training_plans
for each row execute function public.capture_user_data_backup_change();

drop trigger if exists habit_checks_update_user_backup on public.habit_checks;
create trigger habit_checks_update_user_backup
after insert or update or delete on public.habit_checks
for each row execute function public.capture_user_data_backup_change();

drop trigger if exists training_checks_update_user_backup on public.training_checks;
create trigger training_checks_update_user_backup
after insert or update or delete on public.training_checks
for each row execute function public.capture_user_data_backup_change();

drop trigger if exists reminders_update_user_backup on public.reminders;
create trigger reminders_update_user_backup
after insert or update or delete on public.reminders
for each row execute function public.capture_user_data_backup_change();

insert into private.user_data_backups(user_id, snapshot, updated_at)
select p.id,
  jsonb_build_object(
    'version', 1,
    'display_name', p.display_name,
    'habits', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.position, h.created_at, h.id)
      from public.habits h where h.user_id = p.id and h.archived_at is null
    ), '[]'::jsonb),
    'training_plans', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.weekday, t.created_at, t.id)
      from public.training_plans t where t.user_id = p.id and t.archived_at is null
    ), '[]'::jsonb),
    'habit_checks', coalesce((
      select jsonb_agg(to_jsonb(hc) order by hc.check_date, hc.id)
      from public.habit_checks hc join public.habits h on h.id = hc.habit_id and h.user_id = hc.user_id where hc.user_id = p.id and h.archived_at is null
    ), '[]'::jsonb),
    'training_checks', coalesce((
      select jsonb_agg(to_jsonb(tc) order by tc.week_start, tc.id)
      from public.training_checks tc join public.training_plans t on t.id = tc.training_plan_id and t.user_id = tc.user_id where tc.user_id = p.id and t.archived_at is null
    ), '[]'::jsonb),
    'reminders', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at, r.id)
      from public.reminders r where r.user_id = p.id
    ), '[]'::jsonb)
  ),
  now()
from public.profiles p
on conflict (user_id) do update
set snapshot = excluded.snapshot, updated_at = excluded.updated_at;
