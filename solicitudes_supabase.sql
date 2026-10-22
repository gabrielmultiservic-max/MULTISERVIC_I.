-- Flujo de solicitudes de acceso para Personal.
-- Ejecutar este archivo completo en Supabase SQL Editor antes de usar Solicitudes.

create table if not exists public.user_profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null,
    email text not null,
    role text not null default 'personal' check (role in ('personal', 'gerencia')),
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.registration_requests (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null unique references auth.users(id) on delete cascade,
    full_name text not null,
    email text not null,
    status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
    submitted_at timestamptz not null default timezone('utc', now()),
    reviewed_at timestamptz,
    reviewed_by uuid references auth.users(id)
);

create index if not exists registration_requests_status_submitted_idx
    on public.registration_requests (status, submitted_at desc);

create or replace function public.set_user_profiles_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = timezone('utc', now());
    return new;
end;
$$;

drop trigger if exists user_profiles_set_updated_at on public.user_profiles;
create trigger user_profiles_set_updated_at
before update on public.user_profiles
for each row
execute function public.set_user_profiles_updated_at();

-- Cada cuenta nueva de Personal queda pendiente y crea su solicitud automáticamente.
-- Funciona tanto si Supabase exige confirmar el correo como si no.
create or replace function public.create_pending_registration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    requested_name text := coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), new.email);
begin
    insert into public.user_profiles (user_id, full_name, email, role, status)
    values (new.id, requested_name, new.email, 'personal', 'pending')
    on conflict (user_id) do nothing;

    insert into public.registration_requests (user_id, full_name, email, status)
    values (new.id, requested_name, new.email, 'pending')
    on conflict (user_id) do nothing;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created_pending_registration on auth.users;
create trigger on_auth_user_created_pending_registration
after insert on auth.users
for each row
execute function public.create_pending_registration();

create or replace function public.is_current_management()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
        from public.user_profiles
        where user_id = auth.uid()
          and role = 'gerencia'
          and status = 'approved'
    );
$$;

revoke all on function public.is_current_management() from public;
grant execute on function public.is_current_management() to authenticated;

alter table public.user_profiles enable row level security;
alter table public.registration_requests enable row level security;

drop policy if exists "Users can view their profile" on public.user_profiles;
create policy "Users can view their profile"
on public.user_profiles
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Management can view profiles" on public.user_profiles;
create policy "Management can view profiles"
on public.user_profiles
for select
to authenticated
using (public.is_current_management());

drop policy if exists "Management can view registration requests" on public.registration_requests;
create policy "Management can view registration requests"
on public.registration_requests
for select
to authenticated
using (public.is_current_management());

-- Solo Gerencia puede aprobar o rechazar y ambos cambios se realizan juntos.
create or replace function public.review_registration_request(
    p_request_id uuid,
    p_status text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    requested_user_id uuid;
begin
    if p_status not in ('approved', 'rejected') then
        raise exception 'Estado de solicitud inválido.';
    end if;

    if not public.is_current_management() then
        raise exception 'No tienes permiso para revisar solicitudes.';
    end if;

    update public.registration_requests
    set status = p_status,
        reviewed_at = timezone('utc', now()),
        reviewed_by = auth.uid()
    where id = p_request_id
      and status = 'pending'
    returning user_id into requested_user_id;

    if requested_user_id is null then
        raise exception 'La solicitud no existe o ya fue revisada.';
    end if;

    update public.user_profiles
    set status = p_status
    where user_id = requested_user_id;
end;
$$;

revoke all on function public.review_registration_request(uuid, text) from public;
grant execute on function public.review_registration_request(uuid, text) to authenticated;

-- Revoca el acceso de una cuenta Personal aprobada y la quita de Usuarios habilitados.
create or replace function public.revoke_registration_access(
    p_request_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    requested_user_id uuid;
begin
    if not public.is_current_management() then
        raise exception 'No tienes permiso para eliminar accesos.';
    end if;

    select user_id into requested_user_id
    from public.registration_requests
    where id = p_request_id
      and status = 'approved';

    if requested_user_id is null then
        raise exception 'El usuario no está habilitado o ya fue eliminado.';
    end if;

    delete from public.user_profiles
    where user_id = requested_user_id
      and role = 'personal';

    if not found then
        raise exception 'No se puede eliminar el acceso de esta cuenta.';
    end if;

    delete from public.registration_requests
    where id = p_request_id;
end;
$$;

revoke all on function public.revoke_registration_access(uuid) from public;
grant execute on function public.revoke_registration_access(uuid) to authenticated;

-- IMPORTANTE: marca la cuenta existente de Gerencia antes de usar la sección Solicitudes.
-- Reemplaza el correo por el correo real con el que Gerencia inicia sesión.
-- insert into public.user_profiles (user_id, full_name, email, role, status)
-- select id, coalesce(nullif(trim(raw_user_meta_data ->> 'full_name'), ''), email), email, 'gerencia', 'approved'
-- from auth.users
-- where email = 'gerencia@tu-dominio.cl'
-- on conflict (user_id) do update
-- set role = 'gerencia', status = 'approved';
