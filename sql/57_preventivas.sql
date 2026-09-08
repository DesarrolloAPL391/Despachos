-- 57: Programación de PREVENTIVAS (revisión técnico-mecánica en CDA).
-- Objetivo: que los despachadores vean la programación del bimestre y puedan
-- NOTIFICAR al conductor por WhatsApp (el botón abre WhatsApp con el mensaje ya
-- escrito; el despachador elige el contacto del conductor y lo envía).
-- Se lleva control de qué carro ya se notificó (quién y cuándo).

-- ---- 1) Tabla ----
create table if not exists public.preventivas (
  id              bigint generated always as identity primary key,
  bimestre        text,
  interno         text not null,
  placa           text,
  centro_costos   text,
  ruta            text,
  propietario     text,
  fecha           date not null,
  lugar           text,
  correo_afiliado text,
  resultado       text default 'PENDIENTE POR REVISION',
  -- control de notificación al conductor
  notificado      boolean     not null default false,
  notificado_por  text,                 -- correo del despachador que notificó
  notificado_en   timestamptz,
  notif_veces     int         not null default 0,
  observaciones   text,
  created_at      timestamptz not null default now()
);
create index if not exists preventivas_fecha_idx    on public.preventivas (fecha);
create index if not exists preventivas_interno_idx   on public.preventivas (interno);
create index if not exists preventivas_notif_idx     on public.preventivas (notificado);

-- ---- 2) RLS: la ven admin y despachadores; el admin además puede editar ----
alter table public.preventivas enable row level security;

drop policy if exists preventivas_select on public.preventivas;
create policy preventivas_select on public.preventivas
  for select to authenticated
  using ( (select public.es_admin()) or (select public.es_despachador()) );

drop policy if exists preventivas_admin on public.preventivas;
create policy preventivas_admin on public.preventivas
  for all to authenticated
  using ( (select public.es_admin()) )
  with check ( (select public.es_admin()) );

-- ---- 3) RPC: marcar un carro como NOTIFICADO (despachador o admin) ----
-- La escritura del despachador NO va por RLS (solo el admin tiene policy de
-- escritura); pasa por esta función SECURITY DEFINER que solo toca los campos
-- de notificación y registra quién y cuándo.
create or replace function public.preventiva_notificada(p_id bigint)
returns public.preventivas
language plpgsql
security definer
set search_path to 'public'
as $$
declare v public.preventivas;
begin
  if not ( public.es_admin() or public.es_despachador() ) then
    raise exception 'no autorizado';
  end if;
  update public.preventivas
     set notificado     = true,
         notificado_por  = coalesce(auth.email(), notificado_por),
         notificado_en   = now(),
         notif_veces     = notif_veces + 1
   where id = p_id
   returning * into v;
  if v.id is null then
    raise exception 'preventiva % no existe', p_id;
  end if;
  return v;
end $$;

revoke all on function public.preventiva_notificada(bigint) from public;
grant execute on function public.preventiva_notificada(bigint) to authenticated;

-- (opcional) deshacer una notificación por error — solo admin
create or replace function public.preventiva_desnotificar(p_id bigint)
returns public.preventivas
language plpgsql
security definer
set search_path to 'public'
as $$
declare v public.preventivas;
begin
  if not public.es_admin() then raise exception 'no autorizado'; end if;
  update public.preventivas
     set notificado = false, notificado_por = null, notificado_en = null, notif_veces = 0
   where id = p_id
   returning * into v;
  return v;
end $$;
revoke all on function public.preventiva_desnotificar(bigint) from public;
grant execute on function public.preventiva_desnotificar(bigint) to authenticated;
