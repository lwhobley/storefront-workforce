-- What each storefront serves, shown to staff on the map and their shift card.
alter table public.storefronts add column description text not null default ''
  check (length(description) <= 500);
