-- =====================================================================
-- AI Bootcamp Attendance Tracker - database schema (Supabase / Postgres)
-- Structure only. Contains NO member data and NO secrets.
--
-- How to use: Supabase dashboard -> SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------
create extension if not exists unaccent with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz default now(),
  constraint groups_name_key unique (name)
);

create table if not exists public.members (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  group_id       uuid references public.groups(id) on delete set null,
  created_at     timestamptz default now(),
  member_key     text,
  member_number  text,
  constraint members_name_key unique (name)
);

create table if not exists public.attendance_records (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members(id) on delete cascade,
  week_date   date not null,
  present     boolean default false,
  created_at  timestamptz default now(),
  constraint attendance_records_member_id_week_date_key unique (member_id, week_date)
);

create table if not exists public.attendance_summaries (
  id               uuid primary key default gen_random_uuid(),
  summary_date     date not null,
  total_count      integer not null default 0,
  present_count    integer not null default 0,
  absent_count     integer not null default 0,
  attendance_rate  text not null,
  absent_members   jsonb default '[]'::jsonb,
  message          text not null,
  created_at       timestamptz default now(),
  constraint attendance_summaries_summary_date_unique unique (summary_date)
);

create table if not exists public.app_settings (
  setting_key    text primary key,
  setting_value  text not null,
  updated_at     timestamptz default now()
);

create table if not exists public.app_logo_assets (
  id            uuid primary key default gen_random_uuid(),
  logo_name     text not null,
  storage_path  text not null,
  file_type     text not null,
  file_size     integer not null,
  is_default    boolean not null default false,
  created_at    timestamptz not null default now(),
  constraint app_logo_assets_storage_path_key unique (storage_path)
);

-- Extra indexes on members
create unique index if not exists members_member_key_unique
  on public.members (member_key);
create unique index if not exists members_member_number_unique
  on public.members (member_number)
  where member_number is not null and member_number <> '';

-- ---------------------------------------------------------------------
-- 2. Helper function + trigger (auto-fills members.member_key)
-- ---------------------------------------------------------------------
create or replace function public.normalize_member_name(input_name text)
returns text
language sql
immutable
as $$
  select trim(
    regexp_replace(
      regexp_replace(
        lower(extensions.unaccent(coalesce(input_name, ''))),
        '[\.\,\_\-]+',
        ' ',
        'g'
      ),
      '\s+',
      ' ',
      'g'
    )
  );
$$;

create or replace function public.set_member_key()
returns trigger
language plpgsql
as $$
begin
  new.member_key := public.normalize_member_name(new.name);
  return new;
end;
$$;

drop trigger if exists trg_set_member_key on public.members;
create trigger trg_set_member_key
  before insert or update on public.members
  for each row execute function public.set_member_key();

-- ---------------------------------------------------------------------
-- 3. Public check-in function (used by the QR check-in page)
-- ---------------------------------------------------------------------
create or replace function public.public_qr_check_in(
  p_member_number text,
  p_attendance_date date default (timezone('Asia/Manila'::text, now()))::date
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_clean_number text;
  v_member_id uuid;
  v_status text;
  v_start_date date;
  v_end_date date;
  v_already_present boolean;
  v_clean_name text;
begin
  -- Clean QR/member number input.
  -- Accepts plain numbers like 252022, and also labels like "Member Number: 252022".
  v_clean_number := trim(coalesce(p_member_number, ''));

  v_clean_number := regexp_replace(
    v_clean_number,
    '^(phone|member[[:space:]]*(no\.?|number)?|id)[[:space:]]*[:#-]?[[:space:]]*',
    '',
    'i'
  );

  v_clean_number := regexp_replace(v_clean_number, '[^0-9A-Za-z]', '', 'g');

  if v_clean_number = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'missing_number',
      'message', 'QR code is missing a valid member number.'
    );
  end if;

  -- Optional event status check.
  select setting_value
  into v_status
  from public.app_settings
  where setting_key = 'event_status'
  limit 1;

  if v_status is not null and lower(v_status) <> 'active' then
    return jsonb_build_object(
      'ok', false,
      'code', 'event_inactive',
      'message', 'Check-in is not active right now.'
    );
  end if;

  -- Event start date check.
  select setting_value::date
  into v_start_date
  from public.app_settings
  where setting_key = 'tracker_start_date'
    and setting_value ~ '^\d{4}-\d{2}-\d{2}$'
  limit 1;

  if v_start_date is not null and p_attendance_date < v_start_date then
    return jsonb_build_object(
      'ok', false,
      'code', 'before_event_start',
      'message', 'Check-in date is before the event start date.'
    );
  end if;

  -- Event end date check.
  select setting_value::date
  into v_end_date
  from public.app_settings
  where setting_key = 'event_end_date'
    and setting_value ~ '^\d{4}-\d{2}-\d{2}$'
  limit 1;

  if v_end_date is not null and p_attendance_date > v_end_date then
    return jsonb_build_object(
      'ok', false,
      'code', 'after_event_end',
      'message', 'Check-in date is after the event end date.'
    );
  end if;

  -- Private member lookup.
  -- This does NOT expose the full members table to anon.
  select id
  into v_member_id
  from public.members
  where regexp_replace(coalesce(member_number, ''), '[^0-9A-Za-z]', '', 'g') = v_clean_number
  limit 1;

  -- Fallback: if no number match, try matching by full name (case-insensitive,
  -- whitespace-normalized). Supports non-COP members whose QR encodes their
  -- name instead of a member number.
  if v_member_id is null then
    v_clean_name := lower(trim(regexp_replace(coalesce(p_member_number, ''), '\s+', ' ', 'g')));

    if v_clean_name <> '' then
      select id
      into v_member_id
      from public.members
      where lower(trim(regexp_replace(coalesce(name, ''), '\s+', ' ', 'g'))) = v_clean_name
      limit 1;
    end if;
  end if;

  if v_member_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'member_not_found',
      'message', 'No member found for this QR code.'
    );
  end if;

  -- Check if already present.
  select exists (
    select 1
    from public.attendance_records
    where member_id = v_member_id
      and week_date = p_attendance_date
      and present = true
  )
  into v_already_present;

  if v_already_present then
    return jsonb_build_object(
      'ok', true,
      'code', 'already_checked_in',
      'message', 'You are already checked in.'
    );
  end if;

  -- Mark Present. Duplicate same-day records are safely ignored.
  insert into public.attendance_records (member_id, week_date, present)
  values (v_member_id, p_attendance_date, true)
  on conflict (member_id, week_date)
  do update set present = true;

  return jsonb_build_object(
    'ok', true,
    'code', 'checked_in',
    'message', 'You are checked in.'
  );
end;
$function$;

-- ---------------------------------------------------------------------
-- 4. Public registration function (used by the "Register" page)
--    Note: search_path added here as a security best practice.
-- ---------------------------------------------------------------------
create or replace function public.public_register_participant(
  p_name text,
  p_member_number text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existing  record;
  v_new_id    uuid;
begin
  if trim(p_name) = '' or p_name is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_name',
      'message', 'Name is required.');
  end if;

  if p_member_number is null or length(p_member_number) < 7 then
    return jsonb_build_object('ok', false, 'code', 'invalid_number',
      'message', 'A valid contact number (at least 7 digits) is required.');
  end if;

  -- Check 1: same contact number already on file
  select id, name, member_number into v_existing
    from public.members
   where member_number = p_member_number
   limit 1;

  if found then
    if lower(trim(v_existing.name)) = lower(trim(p_name)) then
      -- Same name AND same number: same person re-registering (e.g. lost QR)
      return jsonb_build_object(
        'ok', false, 'code', 'already_registered',
        'message', 'This contact number is already registered as ' || v_existing.name || '.',
        'name', v_existing.name
      );
    else
      -- Same number, different name: block
      return jsonb_build_object(
        'ok', false, 'code', 'number_collision',
        'message', 'This contact number is already registered under a different name. Please check the number you entered, or ask a leader for help.'
      );
    end if;
  end if;

  -- Check 2: same name already registered under a different number
  select id, name, member_number into v_existing
    from public.members
   where lower(trim(name)) = lower(trim(p_name))
   limit 1;

  if found then
    return jsonb_build_object(
      'ok', false, 'code', 'name_collision',
      'message', 'This name is already registered with a different number. If this is you, ask a leader for help. ' ||
                  '-> If you''re a different person, add a middle initial to your name and register again.',
      'name', v_existing.name
    );
  end if;

  insert into public.members (name, member_number, group_id)
  values (trim(p_name), p_member_number, null)
  returning id into v_new_id;

  return jsonb_build_object(
    'ok', true, 'code', 'registered',
    'id', v_new_id,
    'name', trim(p_name),
    'member_number', p_member_number
  );
end;
$function$;

grant execute on function public.public_qr_check_in(text, date) to anon, authenticated;
grant execute on function public.public_register_participant(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. View (admin export). security_invoker = respects row level security.
-- ---------------------------------------------------------------------
create or replace view public.attendance_with_names
with (security_invoker = true) as
select
  attendance_records.id as attendance_id,
  attendance_records.week_date,
  members.name as member_name,
  coalesce(groups.name, 'Ungrouped'::text) as group_name,
  attendance_records.present,
  attendance_records.created_at
from attendance_records
join members on attendance_records.member_id = members.id
left join groups on members.group_id = groups.id
order by attendance_records.week_date desc,
         coalesce(groups.name, 'Ungrouped'::text),
         members.name;

-- ---------------------------------------------------------------------
-- 6. Row Level Security
--    Rule of thumb: logged-in admins can manage everything.
--    Anonymous visitors can only: check in, and read non-secret settings.
--    IMPORTANT: sign-ups must be DISABLED in Authentication settings,
--    because every logged-in user is treated as an admin.
-- ---------------------------------------------------------------------
alter table public.groups               enable row level security;
alter table public.members              enable row level security;
alter table public.attendance_records   enable row level security;
alter table public.attendance_summaries enable row level security;  -- no policies = locked
alter table public.app_settings         enable row level security;
alter table public.app_logo_assets      enable row level security;

-- groups
drop policy if exists "Auth users can select groups" on public.groups;
drop policy if exists "Auth users can insert groups" on public.groups;
drop policy if exists "Auth users can update groups" on public.groups;
drop policy if exists "Auth users can delete groups" on public.groups;
create policy "Auth users can select groups" on public.groups for select to authenticated using (true);
create policy "Auth users can insert groups" on public.groups for insert to authenticated with check (true);
create policy "Auth users can update groups" on public.groups for update to authenticated using (true) with check (true);
create policy "Auth users can delete groups" on public.groups for delete to authenticated using (true);

-- members
drop policy if exists "Auth users can select members" on public.members;
drop policy if exists "Auth users can insert members" on public.members;
drop policy if exists "Auth users can update members" on public.members;
drop policy if exists "Auth users can delete members" on public.members;
create policy "Auth users can select members" on public.members for select to authenticated using (true);
create policy "Auth users can insert members" on public.members for insert to authenticated with check (true);
create policy "Auth users can update members" on public.members for update to authenticated using (true) with check (true);
create policy "Auth users can delete members" on public.members for delete to authenticated using (true);

-- attendance_records
drop policy if exists "Auth users can select attendance_records" on public.attendance_records;
drop policy if exists "Auth users can insert attendance_records" on public.attendance_records;
drop policy if exists "Auth users can update attendance_records" on public.attendance_records;
drop policy if exists "Auth users can delete attendance_records" on public.attendance_records;
drop policy if exists "Anon can insert public check-in attendance" on public.attendance_records;
create policy "Auth users can select attendance_records" on public.attendance_records for select to authenticated using (true);
create policy "Auth users can insert attendance_records" on public.attendance_records for insert to authenticated with check (true);
create policy "Auth users can update attendance_records" on public.attendance_records for update to authenticated using (true) with check (true);
create policy "Auth users can delete attendance_records" on public.attendance_records for delete to authenticated using (true);
create policy "Anon can insert public check-in attendance" on public.attendance_records for insert to anon with check (present = true);

-- app_settings
-- SECURITY: anonymous visitors may read settings EXCEPT the Gemini API key.
drop policy if exists "Auth users can select app_settings" on public.app_settings;
drop policy if exists "Auth users can insert app_settings" on public.app_settings;
drop policy if exists "Auth users can update app_settings" on public.app_settings;
drop policy if exists "Auth users can delete app_settings" on public.app_settings;
drop policy if exists "Anon can read public app settings" on public.app_settings;
create policy "Auth users can select app_settings" on public.app_settings for select to authenticated using (true);
create policy "Auth users can insert app_settings" on public.app_settings for insert to authenticated with check (true);
create policy "Auth users can update app_settings" on public.app_settings for update to authenticated using (true) with check (true);
create policy "Auth users can delete app_settings" on public.app_settings for delete to authenticated using (true);
create policy "Anon can read public app settings" on public.app_settings
  for select to anon using (setting_key <> 'gemini_api_key');

-- app_logo_assets
drop policy if exists "Authenticated can read logo assets" on public.app_logo_assets;
drop policy if exists "Authenticated can insert logo assets" on public.app_logo_assets;
drop policy if exists "Authenticated can update logo assets" on public.app_logo_assets;
drop policy if exists "Authenticated can delete logo assets" on public.app_logo_assets;
create policy "Authenticated can read logo assets" on public.app_logo_assets for select to authenticated using (true);
create policy "Authenticated can insert logo assets" on public.app_logo_assets for insert to authenticated with check (true);
create policy "Authenticated can update logo assets" on public.app_logo_assets for update to authenticated using (true) with check (true);
create policy "Authenticated can delete logo assets" on public.app_logo_assets for delete to authenticated using (is_default = false);

-- ---------------------------------------------------------------------
-- 7. Storage bucket for logos
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('app-branding', 'app-branding', true)
on conflict (id) do nothing;

drop policy if exists "Public can read branding logos" on storage.objects;
drop policy if exists "Authenticated can upload branding logos" on storage.objects;
drop policy if exists "Authenticated can update branding logos" on storage.objects;
drop policy if exists "Authenticated can delete branding logos" on storage.objects;

create policy "Public can read branding logos" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'app-branding');

create policy "Authenticated can upload branding logos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'app-branding' and name like 'logos/%');

create policy "Authenticated can update branding logos" on storage.objects
  for update to authenticated
  using (bucket_id = 'app-branding' and name like 'logos/%')
  with check (bucket_id = 'app-branding' and name like 'logos/%');

create policy "Authenticated can delete branding logos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'app-branding' and name like 'logos/%');

-- =====================================================================
-- Done. Next: create your admin user (Authentication -> Users -> Add user)
-- and turn OFF "Allow new users to sign up" (Authentication -> Sign In / Providers).
-- =====================================================================
