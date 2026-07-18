-- ============================================================
-- Jobix — سكريبت إعداد قاعدة البيانات (شغّله مرة واحدة بس)
-- روح لـ Supabase Dashboard > SQL Editor > New query
-- الصق السكريبت كله واضغط Run
-- ============================================================

-- ---------- جدول البروفايلات ----------
create table if not exists public.profiles (
  id uuid references auth.users on delete cascade primary key,
  username text unique,
  role text check (role in ('worker','employer')) default 'worker',
  age int,
  phone text,
  bio text,
  video_url text,
  rating_avg numeric default 0,
  rating_count int default 0,
  created_at timestamptz default now()
);

alter table public.profiles enable row level security;

drop policy if exists "profiles are viewable by everyone" on public.profiles;
create policy "profiles are viewable by everyone"
  on public.profiles for select using (true);

drop policy if exists "users can update own profile" on public.profiles;
create policy "users can update own profile"
  on public.profiles for update using (auth.uid() = id);

drop policy if exists "users can insert own profile" on public.profiles;
create policy "users can insert own profile"
  on public.profiles for insert with check (auth.uid() = id);

-- إنشاء صف بروفايل تلقائيًا عند إنشاء أي مستخدم جديد
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, username, role)
  values (
    new.id,
    new.raw_user_meta_data->>'username',
    coalesce(new.raw_user_meta_data->>'role', 'worker')
  )
  on conflict (id) do nothing;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------- جدول الوظائف ----------
create table if not exists public.jobs (
  id uuid default gen_random_uuid() primary key,
  employer_id uuid references public.profiles(id) on delete cascade,
  title text not null,
  description text,
  salary text,
  category text check (category in ('permanent','gig')) default 'permanent',
  min_age int default 16,
  max_age int default 60,
  video_url text,
  location text,
  whatsapp text,
  status text default 'open',
  created_at timestamptz default now()
);

alter table public.jobs enable row level security;

drop policy if exists "jobs viewable by everyone" on public.jobs;
create policy "jobs viewable by everyone"
  on public.jobs for select using (true);

drop policy if exists "employers can insert jobs" on public.jobs;
create policy "employers can insert jobs"
  on public.jobs for insert with check (auth.uid() = employer_id);

drop policy if exists "employers can update own jobs" on public.jobs;
create policy "employers can update own jobs"
  on public.jobs for update using (auth.uid() = employer_id);

drop policy if exists "employers can delete own jobs" on public.jobs;
create policy "employers can delete own jobs"
  on public.jobs for delete using (auth.uid() = employer_id);

-- ---------- جدول طلبات التقديم ----------
create table if not exists public.applications (
  id uuid default gen_random_uuid() primary key,
  job_id uuid references public.jobs(id) on delete cascade,
  worker_id uuid references public.profiles(id) on delete cascade,
  video_url text,
  status text default 'pending', -- pending | accepted | rejected | completed
  created_at timestamptz default now(),
  unique(job_id, worker_id)
);

alter table public.applications enable row level security;

drop policy if exists "applicants and job owner can view" on public.applications;
create policy "applicants and job owner can view"
  on public.applications for select using (
    auth.uid() = worker_id
    or auth.uid() = (select employer_id from public.jobs where jobs.id = job_id)
  );

drop policy if exists "workers can apply" on public.applications;
create policy "workers can apply"
  on public.applications for insert with check (auth.uid() = worker_id);

drop policy if exists "worker or employer can update application" on public.applications;
create policy "worker or employer can update application"
  on public.applications for update using (
    auth.uid() = worker_id
    or auth.uid() = (select employer_id from public.jobs where jobs.id = job_id)
  );

-- ---------- جدول التقييمات ----------
create table if not exists public.ratings (
  id uuid default gen_random_uuid() primary key,
  application_id uuid references public.applications(id) on delete cascade,
  from_id uuid references public.profiles(id),
  to_id uuid references public.profiles(id),
  stars int check (stars between 1 and 5),
  comment text,
  created_at timestamptz default now(),
  unique(application_id, from_id)
);

alter table public.ratings enable row level security;

drop policy if exists "ratings viewable by everyone" on public.ratings;
create policy "ratings viewable by everyone"
  on public.ratings for select using (true);

drop policy if exists "users can insert own ratings" on public.ratings;
create policy "users can insert own ratings"
  on public.ratings for insert with check (auth.uid() = from_id);

-- تحديث متوسط تقييم البروفايل تلقائيًا بعد كل تقييم جديد
create or replace function public.update_profile_rating()
returns trigger as $$
begin
  update public.profiles
  set rating_count = (select count(*) from public.ratings where to_id = new.to_id),
      rating_avg = (select avg(stars) from public.ratings where to_id = new.to_id)
  where id = new.to_id;
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_rating_created on public.ratings;
create trigger on_rating_created
  after insert on public.ratings
  for each row execute procedure public.update_profile_rating();

-- ---------- تخزين الفيديوهات (Storage) ----------
insert into storage.buckets (id, name, public)
values ('videos', 'videos', true)
on conflict (id) do nothing;

drop policy if exists "public can view videos" on storage.objects;
create policy "public can view videos"
  on storage.objects for select using (bucket_id = 'videos');

drop policy if exists "authenticated can upload videos" on storage.objects;
create policy "authenticated can upload videos"
  on storage.objects for insert
  with check (bucket_id = 'videos' and auth.role() = 'authenticated');

drop policy if exists "owner can update own videos" on storage.objects;
create policy "owner can update own videos"
  on storage.objects for update
  using (bucket_id = 'videos' and owner = auth.uid());

drop policy if exists "owner can delete own videos" on storage.objects;
create policy "owner can delete own videos"
  on storage.objects for delete
  using (bucket_id = 'videos' and owner = auth.uid());

-- ============================================================
-- خلاص! دلوقتي الموقع/التطبيق جاهز يشتغل فعليًا:
-- - تسجيل صاحب شغل وعامل
-- - نشر وظائف وفلترة بالسن
-- - تقديم بفيديو
-- - قبول/رفض/إنهاء الشغل
-- - تقييم من الاتجاهين
-- ============================================================
