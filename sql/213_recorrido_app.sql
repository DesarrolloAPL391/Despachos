-- ============================================================================================
-- 213 · 🧭 Conozca la app: el recorrido de bienvenida de la Gerencia (26/11/2026)
-- Pedido: "quiero que cuando el gerente inicie sesión vea todos los beneficios de la aplicación,
-- que le muestre y le explique todo de acuerdo a los módulos que tiene la app".
--
-- El recorrido se abre SOLO al entrar a quien está en la lista de Gerencia (permiso_gerencia, sql/97)
-- y todavía no ha visto esa versión. Cualquiera que lo tenga en el menú lo puede volver a abrir.
-- Aquí solo se guarda qué cuenta ya lo vio y en qué versión: nada de correos ni datos de personas.
-- ============================================================================================

create table if not exists public.recorrido_app_visto (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  version  text not null,
  visto_en timestamptz not null default now()
);
alter table public.recorrido_app_visto enable row level security;
revoke all on public.recorrido_app_visto from public, anon, authenticated;

-- ¿Le toca verlo al entrar? Solo responde sobre la cuenta que pregunta.
create or replace function public.recorrido_app_estado(p_version text)
returns json
language sql stable security definer set search_path to 'public'
as $fn$
  select json_build_object(
    'gerencia', exists (
      select 1 from public.permiso_gerencia g
       where lower(g.email) = lower(coalesce((select u.email from auth.users u where u.id = auth.uid()), ''))),
    'visto', exists (
      select 1 from public.recorrido_app_visto v where v.user_id = auth.uid() and v.version = p_version));
$fn$;

-- Ya lo vio (al cerrarlo): no se vuelve a abrir solo hasta que cambie la versión.
create or replace function public.recorrido_app_marcar(p_version text)
returns void
language plpgsql security definer set search_path to 'public'
as $fn$
begin
  if auth.uid() is null then
    raise exception 'Hace falta iniciar sesión' using errcode = '42501';
  end if;
  if coalesce(length(p_version), 0) not between 1 and 20 then
    raise exception 'Versión inválida' using errcode = '22023';
  end if;
  insert into public.recorrido_app_visto (user_id, version) values (auth.uid(), p_version)
  on conflict (user_id) do update set version = excluded.version, visto_en = now();
end
$fn$;

revoke all on function public.recorrido_app_estado(text) from public, anon;
revoke all on function public.recorrido_app_marcar(text) from public, anon;
grant execute on function public.recorrido_app_estado(text) to authenticated;
grant execute on function public.recorrido_app_marcar(text) to authenticated;
