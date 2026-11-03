-- Monthly extension for the private routine leaderboard.
-- Applied with Supabase migration add_routine_daily_comparison_since.

create or replace function public.get_routine_daily_comparison_since(
  p_competition_id uuid,
  p_start_date date
)
returns table(
  score_date date,
  display_name text,
  completed_habits integer,
  total_habits integer,
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
begin
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_start_date is null or p_start_date > v_today or p_start_date < v_today - 90 then
    raise exception 'Invalid comparison start date' using errcode = '22023';
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

  return query
  with day_list as (
    select g.day::date as score_date
    from pg_catalog.generate_series(
      greatest(p_start_date, v_competition_start)::timestamp,
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
      count(h.id)::integer as total_habits,
      count(hc.id) filter (where hc.completed)::integer as completed_habits
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
    dt.score_date,
    p.display_name,
    dt.completed_habits,
    dt.total_habits,
    round(
      100 * coalesce(
        dt.completed_habits::numeric / nullif(dt.total_habits, 0),
        0
      ),
      1
    ) as completion_percent
  from daily_totals dt
  join public.profiles p on p.id = dt.user_id
  order by dt.score_date, p.display_name;
end;
$function$;

revoke all on function public.get_routine_daily_comparison_since(uuid, date)
  from public, anon, authenticated;
grant execute on function public.get_routine_daily_comparison_since(uuid, date)
  to authenticated;
