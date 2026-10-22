-- Tabla centralizada para la seccion Clientes de MULTISERVIC.
-- Ejecutar completo en Supabase SQL Editor.

create table if not exists public.clients (
    id uuid primary key default gen_random_uuid(),
    nombre text not null,
    rut text not null,
    direccion text,
    persona_contacto text not null,
    created_at timestamptz not null default timezone('utc', now()),
    updated_at timestamptz not null default timezone('utc', now())
);

-- Evita duplicar un mismo RUT aunque cambien mayusculas o espacios.
create unique index if not exists clients_rut_unique_idx
    on public.clients (lower(trim(rut)));

create index if not exists clients_nombre_idx
    on public.clients (lower(nombre));

-- Actualiza updated_at automaticamente al modificar un cliente.
create or replace function public.set_clients_updated_at()
returns triggera
language plpgsql
as $$
begin
    new.updated_at = timezone('utc', now());
    return new;
end;
$$;

drop trigger if exists clients_set_updated_at on public.clients;
create trigger clients_set_updated_at
before update on public.clients
for each row
execute function public.set_clients_updated_at();

-- Seguridad: solo usuarios autenticados pueden consultar y gestionar clientes.
alter table public.clients enable row level security;

drop policy if exists "Authenticated users can view clients" on public.clients;
create policy "Authenticated users can view clients"
on public.clients
for select
to authenticated
using (true);

drop policy if exists "Authenticated users can insert clients" on public.clients;
create policy "Authenticated users can insert clients"
on public.clients
for insert
to authenticated
with check (true);

drop policy if exists "Authenticated users can update clients" on public.clients;
create policy "Authenticated users can update clients"
on public.clients
for update
to authenticated
using (true)
with check (true);

drop policy if exists "Authenticated users can delete clients" on public.clients;
create policy "Authenticated users can delete clients"
on public.clients
for delete
to authenticated
using (true);

-- Verificacion opcional:
-- select * from public.clients order by created_at desc;
