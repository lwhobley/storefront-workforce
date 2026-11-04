-- Ratings and do-not-rehire flags. Both are about people, so reading them needs
-- view_workers and changing them needs manage_workers.
--
-- Ratings are a history: a manager adds a rating, nobody edits or deletes one.
-- A do-not-rehire flag is one row per person; clearing it deletes the row.
--
-- (Applied to the live project from another working copy; recorded here as applied.)

-- workers (venue_id, id) is already unique (see 0003), which the foreign keys below need.

create table public.worker_ratings (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues (id) on delete cascade,
  worker_id uuid not null,
  event_id uuid references public.events (id) on delete set null,
  stars smallint not null check (stars between 1 and 5),
  note text not null default '' check (length(note) <= 500),
  rated_by uuid references auth.users (id) on delete set null default auth.uid(),
  rated_at timestamptz not null default now(),
  foreign key (venue_id, worker_id) references public.workers (venue_id, id) on delete cascade
);
create index worker_ratings_worker_idx on public.worker_ratings (venue_id, worker_id);
alter table public.worker_ratings enable row level security;
create policy worker_ratings_read on public.worker_ratings for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_workers'));
create policy worker_ratings_insert on public.worker_ratings for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'manage_workers'));
grant select, insert on public.worker_ratings to authenticated;

create table public.rehire_flags (
  venue_id uuid not null references public.venues (id) on delete cascade,
  worker_id uuid not null,
  reason text not null check (length(trim(reason)) > 0 and length(reason) <= 500),
  flagged_by uuid references auth.users (id) on delete set null default auth.uid(),
  flagged_at timestamptz not null default now(),
  primary key (venue_id, worker_id),
  foreign key (venue_id, worker_id) references public.workers (venue_id, id) on delete cascade
);
alter table public.rehire_flags enable row level security;
create policy rehire_flags_read on public.rehire_flags for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_workers'));
create policy rehire_flags_write on public.rehire_flags for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));
grant select, insert, update, delete on public.rehire_flags to authenticated;
