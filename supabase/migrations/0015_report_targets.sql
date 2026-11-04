-- Report targets: the green and yellow bounds for fill rate and attendance on the Reports
-- screen. One row per venue; a venue without a row uses the defaults in the app.
-- Kept out of venues.settings so that changing a target does not start a new rules version.
--
-- (Applied to the live project from another working copy; recorded here as applied.)

create table public.report_targets (
  venue_id uuid primary key references public.venues (id) on delete cascade,
  fill_green numeric(5, 4) not null default 0.98 check (fill_green between 0 and 2),
  fill_yellow numeric(5, 4) not null default 0.90 check (fill_yellow between 0 and 2),
  attendance_green numeric(5, 4) not null default 0.95 check (attendance_green between 0 and 1),
  attendance_yellow numeric(5, 4) not null default 0.85 check (attendance_yellow between 0 and 1),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null default auth.uid(),
  check (fill_yellow <= fill_green),
  check (attendance_yellow <= attendance_green)
);
alter table public.report_targets enable row level security;
-- Anyone who can see reports reads the targets; only settings managers change them.
create policy report_targets_read on public.report_targets for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_reports'));
create policy report_targets_insert on public.report_targets for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'manage_settings'));
create policy report_targets_update on public.report_targets for update to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings'))
  with check (public.has_venue_permission(venue_id, 'manage_settings'));
grant select, insert, update on public.report_targets to authenticated;
