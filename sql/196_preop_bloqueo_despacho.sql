-- 196: TODO CARRO DEBE TENER SU PREOPERACIONAL ANTES DE SER DESPACHADO (pedido del 18/11/2026:
-- "debemos de tener una restriccion en el despacho, todo carro antes de ser despachado debe
-- tener su preoperacional").
--
-- La regla es POR BUS Y POR DIA (Res. 315 de 2013, art. 4: alistamiento diario del vehiculo):
-- el bus puede despacharse si hoy (hora Colombia) alguien le hizo el preoperacional, sin importar
-- cual conductor. Se midio el 18/11: no hay despachos antes de las 03:00 y los preoperacionales
-- empiezan a esa hora, asi que "el del mismo dia" no deja por fuera a la madrugada.
--
-- Molde = bloqueo de licencia (sql/110): la fecha vive en una tabla de configuracion, no en el
-- codigo. Antes de `desde` la app muestra el aviso con la cuenta regresiva; desde `desde`, bloquea.
-- Apagado (activo = false), la app no muestra nada. Se cambia sin publicar:
--   select public.preop_bloqueo_config_guardar(p_activo => true, p_desde => '2026-11-23 03:00-05');
--
-- Este archivo SOLO crea objetos nuevos y deja el bloqueo APAGADO: no cambia nada de lo que ya
-- funciona. La app publicada no llama a estas funciones.
--
-- No bloquea (y lo dice) si el bus no esta 'Activo' en el parque: el formulario del conductor no
-- deja elegir esos buses (preop_guardar), asi que el bus quedaria trancado para siempre. El 18/11
-- los 171 buses despachados en la ultima semana estaban Activos.

set lock_timeout = '5s';

create table if not exists public.preop_bloqueo_config (
  id             int primary key default 1 check (id = 1),
  activo         boolean not null default false,
  desde          timestamptz,
  nota           text,
  actualizado_en timestamptz not null default now(),
  actualizado_por text
);
alter table public.preop_bloqueo_config enable row level security;
-- Sin politicas ni permisos: solo la leen las funciones de abajo (security definer).
revoke all on public.preop_bloqueo_config from public, anon, authenticated;

insert into public.preop_bloqueo_config (id, activo, desde, nota)
values (1, false, null, '18/11/2026: creado APAGADO. Se enciende con preop_bloqueo_config_guardar.')
on conflict (id) do nothing;

-- ¿Este bus ya tiene el preoperacional de hoy? La usa la app al elegir el bus y otra vez al despachar.
create or replace function public.preop_despacho_estado(p_interno text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy     date := (now() at time zone 'America/Bogota')::date;
  v_mov     text := btrim(coalesce(p_interno, ''));
  cfg       public.preop_bloqueo_config%rowtype;
  v_act     boolean;
  v_vig     boolean;
  v_n       int;
  v_primera timestamptz;
  v_nombre  text;
  v_nov     int;
  v_puntos  jsonb;
  v_hab     boolean;
begin
  if not ((select public.es_admin()) or (select public.es_despachador())
          or (select public.es_operaciones()) or (select public.es_auditor())) then
    return jsonb_build_object('bloqueado', false);
  end if;
  if v_mov = '' then
    return jsonb_build_object('bloqueado', false);
  end if;

  select * into cfg from public.preop_bloqueo_config where id = 1;
  v_act := coalesce(cfg.activo, false);
  v_vig := v_act and cfg.desde is not null and now() >= cfg.desde;

  select count(*), min(p.creado_en) into v_n, v_primera
    from public.preoperacionales p
   where p.fecha = v_hoy and btrim(p.movil) = v_mov;

  select p.nombre into v_nombre
    from public.preoperacionales p
   where p.fecha = v_hoy and btrim(p.movil) = v_mov
   order by p.creado_en limit 1;

  -- Lo que el conductor reporto en mal estado hoy y taller todavia no atendio: solo se avisa.
  select count(distinct i.pregunta)::int, coalesce(jsonb_agg(distinct i.pregunta), '[]'::jsonb)
    into v_nov, v_puntos
    from public.preoperacionales p
    join public.preoperacional_items i on i.preop_id = p.id
   where p.fecha = v_hoy and btrim(p.movil) = v_mov
     and p.estado = 'PENDIENTE' and i.respuesta = 'MAL';

  v_hab := exists (select 1 from public.parque_automotor pa
                    where btrim(pa.numero_interno) = v_mov and pa.estado = 'Activo');

  return jsonb_build_object(
    'interno',    v_mov,
    'activo',     v_act,                                -- el interruptor
    'vigente',    v_vig,                                -- ya esta bloqueando
    'desde',      case when v_act then cfg.desde end,   -- desde cuando bloquea (null = apagado)
    'tiene',      v_n > 0,
    'cuantos',    v_n,
    'hora',       to_char(v_primera at time zone 'America/Bogota', 'HH24:MI'),
    'conductor',  v_nombre,
    'novedades',  coalesce(v_nov, 0),
    'puntos',     v_puntos,
    'habilitado', v_hab,                                -- el formulario acepta este bus
    'bloqueado',  v_vig and v_n = 0 and v_hab);
end $fn$;
revoke all on function public.preop_despacho_estado(text) from public, anon;
grant execute on function public.preop_despacho_estado(text) to authenticated;

-- Encender, apagar o mover la fecha. Solo administracion (o el SQL Editor).
create or replace function public.preop_bloqueo_config_guardar(
  p_activo boolean     default null,
  p_desde  timestamptz default null,
  p_nota   text        default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not ((select public.es_admin()) or (select public.es_consola())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración cambia el bloqueo del preoperacional.');
  end if;
  update public.preop_bloqueo_config
     set activo = coalesce(p_activo, activo),
         desde  = coalesce(p_desde, desde),
         nota   = coalesce(nullif(btrim(coalesce(p_nota, '')), ''), nota),
         actualizado_en  = now(),
         actualizado_por = coalesce(auth.jwt() ->> 'email', 'consola')
   where id = 1;
  return jsonb_build_object('ok', true) || (select to_jsonb(c) from public.preop_bloqueo_config c where c.id = 1);
end $fn$;
revoke all on function public.preop_bloqueo_config_guardar(boolean, timestamptz, text) from public, anon;
grant execute on function public.preop_bloqueo_config_guardar(boolean, timestamptz, text) to authenticated;
