-- Performance (Phase 4): notes about people, and a same-venue check on ratings.
--
-- Ratings and do-not-rehire flags already exist (0016, audited since 0019). Reliability
-- scores, rankings and staffing suggestions are worked out in the app from shifts,
-- punches and assignment changes (the shared attendance outcomes in workforce_core), so
-- they need no tables. Their weights live in venues.settings -> 'reliability'
-- (window_events, window_days, no_show_points, call_off_points, late_points, min_events);
-- missing keys use the app's defaults.
--
-- Who sees what: everything about a person's performance needs view_workers venue-wide
-- to read and manage_workers to write. Employees, storefront leads, NPO coordinators and
-- agency contacts hold neither, so they never see ratings, notes, flags or scores, not
-- even their own.

-- ---------------------------------------------------------------------------
-- Notes: a manager's running notes about a person. A history like ratings: added,
-- never edited or removed (corrections are a new note).
-- ---------------------------------------------------------------------------
create table public.worker_notes (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues (id) on delete cascade,
  worker_id uuid not null,
  event_id uuid,
  body text not null check (length(trim(body)) > 0 and length(body) <= 1000),
  written_by uuid references auth.users (id) on delete set null default auth.uid(),
  written_at timestamptz not null default now(),
  foreign key (venue_id, worker_id) references public.workers (venue_id, id) on delete cascade,
  foreign key (venue_id, event_id) references public.events (venue_id, id) on delete set null (event_id)
);
create index worker_notes_worker_idx on public.worker_notes (venue_id, worker_id, written_at);
alter table public.worker_notes enable row level security;
revoke all on public.worker_notes from anon;
create policy worker_notes_read on public.worker_notes for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_workers'));
create policy worker_notes_insert on public.worker_notes for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'manage_workers'));
revoke all on public.worker_notes from authenticated;
grant select on public.worker_notes to authenticated;
-- Who wrote it and when are set by the database, not the client.
grant insert (venue_id, worker_id, event_id, body) on public.worker_notes to authenticated;

create trigger worker_notes_audit after insert or update or delete on public.worker_notes
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Ratings: the event a rating is about must be at the same venue, and who rated and
-- when are set by the database (a manager cannot backdate or sign as someone else).
-- ---------------------------------------------------------------------------
alter table public.worker_ratings
  add constraint worker_ratings_event_same_venue
  foreign key (venue_id, event_id) references public.events (venue_id, id) on delete set null (event_id);

revoke insert on public.worker_ratings from authenticated;
grant insert (venue_id, worker_id, event_id, stars, note) on public.worker_ratings to authenticated;

-- Flags: likewise, who flagged and when come from the database.
revoke insert on public.rehire_flags from authenticated;
grant insert (venue_id, worker_id, reason) on public.rehire_flags to authenticated;
