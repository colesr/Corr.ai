-- =====================================================================
-- CORR.AI — Supabase schema
-- Run this once in the Supabase SQL editor on a fresh project.
-- Safe to re-run: every CREATE is guarded with IF NOT EXISTS or DROP+CREATE.
-- =====================================================================

-- ---------------------------------------------------------------------
-- profiles: 1:1 with auth.users. Holds the user-visible display name,
-- the user's preferences blob, and a pointer to their active canvas.
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id                  uuid primary key references auth.users(id) on delete cascade,
  display_name        text unique not null,
  preferences         jsonb not null default '{}'::jsonb,
  active_canvas_name  text,
  created_at          timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- favorites: one row per (user, item). item_data is the full card
-- snapshot (title, a, b, summary, why, strength, domains, ...).
-- ---------------------------------------------------------------------
create table if not exists public.favorites (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  item_title   text not null,
  item_data    jsonb not null,
  created_at   timestamptz not null default now(),
  unique (user_id, item_title)
);
create index if not exists favorites_user_idx on public.favorites(user_id);

-- ---------------------------------------------------------------------
-- reactions: one row per (user, item) with a like/dislike.
-- ---------------------------------------------------------------------
create table if not exists public.reactions (
  user_id      uuid not null references auth.users(id) on delete cascade,
  item_title   text not null,
  reaction     text not null check (reaction in ('like','dislike')),
  updated_at   timestamptz not null default now(),
  primary key (user_id, item_title)
);

-- ---------------------------------------------------------------------
-- notes: one row per (user, item) with free-form note text.
-- ---------------------------------------------------------------------
create table if not exists public.notes (
  user_id      uuid not null references auth.users(id) on delete cascade,
  item_title   text not null,
  note_text    text not null,
  updated_at   timestamptz not null default now(),
  primary key (user_id, item_title)
);

-- ---------------------------------------------------------------------
-- canvases: one row per (user, canvas name). data is the {nodes, edges,
-- pan, zoom} blob — kept opaque to the DB.
-- ---------------------------------------------------------------------
create table if not exists public.canvases (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  data         jsonb not null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (user_id, name)
);
create index if not exists canvases_user_idx on public.canvases(user_id);

-- =====================================================================
-- ROW LEVEL SECURITY
-- Each user can only see and modify their own rows.
-- =====================================================================
alter table public.profiles  enable row level security;
alter table public.favorites enable row level security;
alter table public.reactions enable row level security;
alter table public.notes     enable row level security;
alter table public.canvases  enable row level security;

drop policy if exists "profiles: select own"  on public.profiles;
drop policy if exists "profiles: insert own"  on public.profiles;
drop policy if exists "profiles: update own"  on public.profiles;
create policy "profiles: select own"  on public.profiles for select using (auth.uid() = id);
create policy "profiles: insert own"  on public.profiles for insert with check (auth.uid() = id);
create policy "profiles: update own"  on public.profiles for update using (auth.uid() = id);

drop policy if exists "favorites: all own" on public.favorites;
create policy "favorites: all own" on public.favorites for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "reactions: all own" on public.reactions;
create policy "reactions: all own" on public.reactions for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "notes: all own" on public.notes;
create policy "notes: all own" on public.notes for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "canvases: all own" on public.canvases;
create policy "canvases: all own" on public.canvases for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- =====================================================================
-- AUTO-PROFILE TRIGGER
-- When a new auth.users row is created, automatically create a matching
-- profiles row using the display_name from raw_user_meta_data.
-- The client passes { data: { display_name } } to supabase.auth.signUp.
-- =====================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
      split_part(new.email, '@', 1)
    )
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =====================================================================
-- updated_at TRIGGERS (keep updated_at fresh on row writes)
-- =====================================================================
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

drop trigger if exists touch_reactions on public.reactions;
create trigger touch_reactions before update on public.reactions
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_notes on public.notes;
create trigger touch_notes before update on public.notes
  for each row execute function public.touch_updated_at();

drop trigger if exists touch_canvases on public.canvases;
create trigger touch_canvases before update on public.canvases
  for each row execute function public.touch_updated_at();
