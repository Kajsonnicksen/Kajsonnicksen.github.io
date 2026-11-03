-- One-time migration for a private two-person routine leaderboard.
-- Run this in the Supabase SQL Editor after the original schema has been created.

-- Preserve deleted routine history by archiving habits instead of deleting them.
alter table public.habits
  add column if not exists archived_at timestamptz;

revoke delete on table public.habits from authenticated;

-- A competition contains members, but the browser cannot query these tables
-- directly. The SECURITY DEFINER function below checks membership and returns
-- only display names and completion percentages.
create table if not exists public.routine_competitions (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table if not exists public.routine_competition_members (
  competition_id uuid not null references public.routine_competitions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (competition_id, user_id)
);

alter table public.routine_competitions enable row level security;
alter table public.routine_competition_members enable row level security;

revoke all on table public.routine_competitions from anon, authenticated;
revoke all on table public.routine_competition_members from anon, authenticated;

create or replace function public.get_routine_leaderboard(
  p_competition_id uuid,
  p_days integer default 7
)
returns table (
  display_name text,
  completion_percent numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_today date := (now() at time zone 'Europe/Copenhagen')::date;
  v_competition_start date;
  v_start date;
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_days is null or p_days not in (7, 30) then
    raise exception 'p_days must be 7 or 30' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.routine_competition_members m
    where m.competition_id = p_competition_id
      and m.user_id = v_user_id
  ) then
    raise exception 'You are not a member of this competition' using errcode = '42501';
  end if;

  select (c.created_at at time zone 'Europe/Copenhagen')::date
    into v_competition_start
  from public.routine_competitions c
  where c.id = p_competition_id;

  if v_competition_start is null then
    raise exception 'Competition not found' using errcode = '22023';
  end if;

  v_start := greatest(v_today - (p_days - 1), v_competition_start);

  return query
  with day_list as (
    select g.day::date as score_date
    from pg_catalog.generate_series(
      v_start::timestamp,
      v_today::timestamp,
      interval '1 day'
    ) as g(day)
  ), member_days as (
    select m.user_id, d.score_date
    from public.routine_competition_members m
    cross join day_list d
    where m.competition_id = p_competition_id
  ), daily_totals as (
    select
      md.user_id,
      md.score_date,
      count(h.id)::numeric as total_habits,
      count(hc.id) filter (where hc.completed)::numeric as completed_habits
    from member_days md
    left join public.habits h
      on h.user_id = md.user_id
      and (h.created_at at time zone 'Europe/Copenhagen')::date <= md.score_date
      and (
        h.archived_at is null
        or (h.archived_at at time zone 'Europe/Copenhagen')::date >= md.score_date
      )
    left join public.habit_checks hc
      on hc.user_id = md.user_id
      and hc.habit_id = h.id
      and hc.check_date = md.score_date
    group by md.user_id, md.score_date
  )
  select
    p.display_name,
    round(
      100 * coalesce(
        avg(coalesce(dt.completed_habits / nullif(dt.total_habits, 0), 0)),
        0
      ),
      1
    ) as completion_percent
  from daily_totals dt
  join public.profiles p on p.id = dt.user_id
  group by dt.user_id, p.display_name
  order by completion_percent desc, p.display_name asc;
end;
$function$;

revoke all on function public.get_routine_leaderboard(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.get_routine_leaderboard(uuid, integer)
  to authenticated;

-- Create (or reuse) the competition and add the two existing profiles.
-- The submitted setup SQL creates these display names from the existing accounts.
do $block$
declare
  v_kaj_id uuid;
  v_erik_id uuid;
  v_competition_id uuid;
begin
  select p.id into v_kaj_id
  from public.profiles p
  where p.display_name = 'Kaj'
  order by p.created_at
  limit 1;

  select p.id into v_erik_id
  from public.profiles p
  where p.display_name = 'Erik'
  order by p.created_at
  limit 1;

  if v_kaj_id is null or v_erik_id is null then
    raise exception 'Could not find both Kaj and Erik in public.profiles. Check display_name values before running this section.';
  end if;

  insert into public.routine_competitions (name, created_by)
  values ('Kaj og Erik', v_kaj_id)
  on conflict (name) do update set created_by = excluded.created_by
  returning id into v_competition_id;

  insert into public.routine_competition_members (competition_id, user_id)
  values
    (v_competition_id, v_kaj_id),
    (v_competition_id, v_erik_id)
  on conflict (competition_id, user_id) do nothing;
end;
$block$;

-- Copy this ID for the frontend RPC call.
select id as competition_id
from public.routine_competitions
where name = 'Kaj og Erik';

-- Example read call (run as a signed-in user in the app, not as SQL Editor):
-- select * from public.get_routine_leaderboard('<competition-uuid>', 7);

