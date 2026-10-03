-- Madeira compatibility reports — run this once in the Supabase SQL editor.
--
-- What it sets up, and who can do what with the PUBLIC (anon) key that ships
-- inside the app and the website:
--   reports       anyone can file one and read them all; nobody can edit or
--                 delete one through the API (you can, in the dashboard)
--   game_summary  per-game totals the Compatibility page lists
--   logs bucket   anyone can UPLOAD a report's log; only you can READ one
--                 (Storage in the dashboard) — logs carry device paths, so they
--                 are never public
-- Re-running the script is safe.

-- ── Reports ──────────────────────────────────────────────────────────────────

create table if not exists public.reports (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  game             text not null check (char_length(game) between 1 and 120),
  -- "Untitled Goose Game" -> "untitled-goose-game": the page a game's reports
  -- are grouped on. The app computes the same key to link to it.
  game_key         text generated always as
                     (trim(both '-' from regexp_replace(lower(game), '[^a-z0-9]+', '-', 'g'))) stored,
  steam_app_id     integer check (steam_app_id between 1 and 99999999),
  rating           text not null check (rating in ('perfect', 'playable', 'runs', 'boots', 'broken')),
  issues           text[] not null default '{}'
                     check (issues <@ array['crash', 'slow', 'graphics', 'audio', 'controls', 'video']::text[]),
  fps              text check (fps in ('under-20', '20-30', '30-45', '45-60', '60')),
  description      text not null default '' check (char_length(description) <= 2000),
  madeira_version  text check (char_length(madeira_version) <= 80),
  device           text check (char_length(device) <= 40),
  ios              text check (char_length(ios) <= 20),
  arch             text check (arch in ('x64', 'x86')),
  settings         jsonb check (pg_column_size(settings) <= 1000),
  has_log          boolean not null default false,
  -- A random id per app install, for the rate limit below. Not readable
  -- through the API.
  client_id        uuid
);

create index if not exists reports_game_key_idx on public.reports (game_key, created_at desc);
create index if not exists reports_created_idx  on public.reports (created_at desc);
create index if not exists reports_client_idx   on public.reports (client_id, created_at desc);

alter table public.reports enable row level security;

drop policy if exists "anyone can file a report" on public.reports;
create policy "anyone can file a report" on public.reports
  for insert to anon, authenticated with check (true);

drop policy if exists "anyone can read reports" on public.reports;
create policy "anyone can read reports" on public.reports
  for select to anon, authenticated using (true);

-- Column privileges: the public key may write only these columns and read
-- everything except client_id. created_at is always the server's clock. Every
-- grant is explicit, so this works with "Automatically expose new tables" off.
grant usage on schema public to anon, authenticated;
revoke all on public.reports from anon, authenticated;
grant insert (id, game, steam_app_id, rating, issues, fps, description,
              madeira_version, device, ios, arch, settings, has_log, client_id)
  on public.reports to anon, authenticated;
grant select (id, created_at, game, game_key, steam_app_id, rating, issues, fps,
              description, madeira_version, device, ios, arch, settings, has_log)
  on public.reports to anon, authenticated;

-- A brake on floods: 10 reports an hour per install, 30 a minute overall.
create or replace function public.reports_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.client_id is not null and (
       select count(*) from public.reports
        where client_id = new.client_id and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Too many reports from this device in the last hour';
  end if;
  if (select count(*) from public.reports where created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Too many reports right now — try again in a minute';
  end if;
  new.created_at := now();
  return new;
end $$;

drop trigger if exists reports_before_insert on public.reports;
create trigger reports_before_insert before insert on public.reports
  for each row execute function public.reports_before_insert();

-- ── Per-game totals ──────────────────────────────────────────────────────────

create or replace view public.game_summary with (security_invoker = on) as
select game_key                                             as key,
       (array_agg(game order by created_at desc))[1]        as game,
       max(steam_app_id)                                    as steam_app_id,
       count(*)                                             as reports,
       max(created_at)                                      as last_report,
       count(*) filter (where rating = 'perfect')           as perfect,
       count(*) filter (where rating = 'playable')          as playable,
       count(*) filter (where rating = 'runs')              as runs,
       count(*) filter (where rating = 'boots')             as boots,
       count(*) filter (where rating = 'broken')            as broken
  from public.reports
 where game_key <> ''
 group by game_key;

grant select on public.game_summary to anon, authenticated;

-- ── Log files ────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('logs', 'logs', false, 15728640, array['application/gzip'])
on conflict (id) do update
  set public = false, file_size_limit = 15728640, allowed_mime_types = array['application/gzip'];

drop policy if exists "anyone can upload a report log" on storage.objects;
create policy "anyone can upload a report log" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'logs' and name ~ '^[0-9a-f-]{36}\.txt\.gz$');
-- No select, update or delete policies: uploads cannot be read, replaced or
-- removed with the public key. Download them from Storage in the dashboard.
