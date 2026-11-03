-- Run once in Supabase SQL Editor before connecting the web app.
-- Requires the base schema and leaderboard.sql to have been run first.

-- Supabase table grants and RLS policies are separate controls. Remove broad
-- default grants, then grant only normal CRUD access to signed-in users.
revoke all on table
  public.profiles,
  public.habits,
  public.habit_checks,
  public.training_plans,
  public.reminders,
  public.food_entries,
  public.nutrition_goals
from anon, authenticated;

grant select, insert, update, delete on table
  public.profiles,
  public.habit_checks,
  public.training_plans,
  public.reminders,
  public.food_entries,
  public.nutrition_goals
to authenticated;

-- Habits must be archived (archived_at), not hard-deleted, to preserve the
-- denominator for past competition percentages.
grant select, insert, update on table public.habits to authenticated;

-- Weekly plans need a separate table for completion state, one record per
-- plan per week.
create table if not exists public.training_checks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  training_plan_id uuid not null references public.training_plans(id) on delete cascade,
  week_start date not null,
  completed boolean not null default true,
  created_at timestamptz not null default now(),
  unique (user_id, training_plan_id, week_start)
);

alter table public.training_checks enable row level security;
revoke all on table public.training_checks from anon, authenticated;
grant select, insert, update, delete on table public.training_checks to authenticated;

drop policy if exists "Own training checks only" on public.training_checks;
create policy "Own training checks only"
on public.training_checks
for all
to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

-- Composite foreign keys ensure a user cannot create a check-off for another
-- user's habit or training plan, even if they learn its UUID.
do $block$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.habits'::regclass
      and conname = 'habits_id_user_id_key'
  ) then
    alter table public.habits
      add constraint habits_id_user_id_key unique (id, user_id);
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.training_plans'::regclass
      and conname = 'training_plans_id_user_id_key'
  ) then
    alter table public.training_plans
      add constraint training_plans_id_user_id_key unique (id, user_id);
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.habit_checks'::regclass
      and conname = 'habit_checks_habit_owner_fkey'
  ) then
    alter table public.habit_checks
      add constraint habit_checks_habit_owner_fkey
      foreign key (habit_id, user_id)
      references public.habits (id, user_id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_catalog.pg_constraint
    where conrelid = 'public.training_checks'::regclass
      and conname = 'training_checks_plan_owner_fkey'
  ) then
    alter table public.training_checks
      add constraint training_checks_plan_owner_fkey
      foreign key (training_plan_id, user_id)
      references public.training_plans (id, user_id)
      on delete cascade;
  end if;
end;
$block$;

create index if not exists habits_user_position_idx
  on public.habits (user_id, position);
create index if not exists habit_checks_user_date_idx
  on public.habit_checks (user_id, check_date);
create index if not exists training_plans_user_weekday_idx
  on public.training_plans (user_id, weekday);
create index if not exists training_checks_user_week_idx
  on public.training_checks (user_id, week_start);

-- Let a signed-in user discover their own competition ID without granting
-- direct read access to competition membership rows.
create or replace function public.get_my_routine_competitions()
returns table (
  competition_id uuid,
  competition_name text
)
language sql
stable
security definer
set search_path = ''
as $function$
  select c.id, c.name
  from public.routine_competitions c
  join public.routine_competition_members m on m.competition_id = c.id
  where m.user_id = auth.uid()
  order by c.created_at;
$function$;

revoke all on function public.get_my_routine_competitions()
  from public, anon, authenticated;
grant execute on function public.get_my_routine_competitions()
  to authenticated;

