-- 134_conectados_ubicacion.sql
-- "podriamos ver las ubicaciones de las personas que estan conectadas... la tabla de los
--  conectados, eso es importante" (22/10/2026).
--
-- Hasta ahora sesion_activa solo guardaba quien estaba en linea, su latencia y su version.
-- La ubicacion existia unicamente en auditoria_accesos, y solo la del MOMENTO DEL INGRESO.
-- Ahora el latido (cada 12 s) puede traer la posicion, asi que en Conectados se ve DONDE ESTA
-- cada quien y de hace cuanto es ese dato.
--
-- COMPATIBILIDAD: hay 98 personas conectadas con la app ya cargada en el navegador, que
-- llaman heartbeat(p_latencia_ms, p_version). NO se deja una segunda funcion sobrecargada:
-- como PostgREST resuelve por NOMBRE de parametro, dos firmas que aceptan esos dos nombres
-- harian la llamada ambigua y el latido fallaria para todos. En su lugar se reemplaza la
-- funcion por una sola con los tres parametros nuevos OPCIONALES: quien llama con dos sigue
-- funcionando igual. El hueco del drop dura milisegundos y el cliente ya trata el error de
-- latido como "no expulsar".
--
-- PROPORCIONALIDAD: el navegador pide permiso y la persona puede negarlo; en ese caso no hay
-- posicion y no se inventa ninguna. Hoy solo 2 de cada 3 accesos traen GPS. Antes de usar esto
-- para controlar a alguien, hay que avisarle (Ley 1581 de 2012): para eso esta el modulo de
-- avisos de obligatoria respuesta.

alter table public.sesion_activa
  add column if not exists lat      numeric,
  add column if not exists lon      numeric,
  add column if not exists gps_prec numeric,
  add column if not exists gps_en   timestamptz;

comment on column public.sesion_activa.lat is 'Ultima latitud reportada por el latido (null si no dio permiso).';
comment on column public.sesion_activa.gps_en is 'Cuando se tomo esa posicion: sin esto no se sabe si el punto es de ahora o de hace dos horas.';

-- ---------------------------------------------------------------------------
-- Latido con ubicacion
-- ---------------------------------------------------------------------------
drop function if exists public.heartbeat(integer, text);

create or replace function public.heartbeat(
  p_latencia_ms integer default null,
  p_version     text    default null,
  p_lat         numeric default null,
  p_lon         numeric default null,
  p_prec        numeric default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_vig boolean;
begin
  update public.sesion_activa
     set updated_at  = now(),
         latencia_ms = coalesce(p_latencia_ms, latencia_ms),
         app_version = coalesce(nullif(trim(p_version), ''), app_version),
         -- La posicion solo se pisa cuando llega una nueva; si el navegador no la dio,
         -- se conserva la ultima conocida junto con SU hora (gps_en), para no hacer creer
         -- que un punto viejo es de ahora.
         lat      = case when p_lat is not null then p_lat  else lat end,
         lon      = case when p_lon is not null then p_lon  else lon end,
         gps_prec = case when p_lat is not null then p_prec else gps_prec end,
         gps_en   = case when p_lat is not null then now()  else gps_en end
   where user_id = auth.uid()
     and session_id = (auth.jwt() ->> 'session_id')::uuid;
  v_vig := found;
  if not v_vig then return jsonb_build_object('estado', 'reemplazada'); end if;
  if not public.en_horario() then return jsonb_build_object('estado', 'fuera_horario'); end if;
  return jsonb_build_object('estado', 'ok');
end $function$;

revoke all on function public.heartbeat(integer, text, numeric, numeric, numeric) from public, anon;
grant execute on function public.heartbeat(integer, text, numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Conectados, ahora con ubicacion
-- Si el latido todavia no trajo posicion (app sin recargar o permiso negado), se cae a la
-- ULTIMA UBICACION DE INGRESO que ya se venia guardando en auditoria_accesos. Asi la pantalla
-- sirve desde el primer dia y se distingue una cosa de la otra con 'gps_origen'.
-- ---------------------------------------------------------------------------
drop function if exists public.listar_conectados(integer);

create or replace function public.listar_conectados(p_minutos integer default 3)
returns table (
  email text, nombre text, rol text, ultimo timestamptz, en_linea boolean,
  ruta text, hora_inicio text, hora_fin text, latencia_ms integer, app_version text,
  lat numeric, lon numeric, gps_prec numeric, gps_en timestamptz, gps_origen text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select u.email,
         coalesce(p.nombre, ''),
         coalesce(p.rol, ''),
         sa.updated_at,
         sa.updated_at > now() - make_interval(mins => greatest(1, coalesce(p_minutos, 3))),
         h.ruta, h.hora_inicio, h.hora_fin,
         sa.latencia_ms, sa.app_version,
         coalesce(sa.lat, ing.lat)      as lat,
         coalesce(sa.lon, ing.lon)      as lon,
         sa.gps_prec,
         coalesce(sa.gps_en, ing.cuando) as gps_en,
         case when sa.lat is not null then 'en vivo'
              when ing.lat is not null then 'del ingreso'
              else null end             as gps_origen
  from public.sesion_activa sa
  join auth.users u on u.id = sa.user_id
  left join public.perfiles p on p.id = sa.user_id
  left join lateral (
    select ho.observacion as ruta,
           to_char(ho.hora_inicio, 'HH24:MI') as hora_inicio,
           to_char(ho.hora_fin,    'HH24:MI') as hora_fin
    from public.horarios ho
    where lower(ho.email) = lower(u.email)
      and ho.fecha = (now() at time zone 'America/Bogota')::date
    order by ho.updated_at desc nulls last
    limit 1
  ) h on true
  left join lateral (
    select split_part(a.gps, ',', 1)::numeric as lat,
           split_part(a.gps, ',', 2)::numeric as lon,
           a.creado_en as cuando
      from public.auditoria_accesos a
     where a.user_id = sa.user_id
       and a.evento = 'ingreso'
       and a.gps ~ '^\s*-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?\s*$'
     order by a.creado_en desc
     limit 1
  ) ing on true
  where public.es_admin()
    and exists (select 1 from auth.sessions s where s.user_id = sa.user_id)
  order by sa.updated_at desc;
$function$;

revoke all on function public.listar_conectados(integer) from public, anon;
grant execute on function public.listar_conectados(integer) to authenticated;

-- Comprobacion (solo lectura)
select 'columnas nuevas en sesion_activa' as dato,
       (select count(*)::text from information_schema.columns
         where table_schema='public' and table_name='sesion_activa'
           and column_name in ('lat','lon','gps_prec','gps_en')) || ' de 4' as valor
union all
select 'firmas de heartbeat (debe ser 1)',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='heartbeat')
union all
select 'listar_conectados devuelve ubicacion',
       case when (select count(*) from information_schema.routines r
                   join information_schema.parameters pa on pa.specific_name = r.specific_name
                  where r.routine_schema='public' and r.routine_name='listar_conectados'
                    and pa.parameter_name in ('lat','lon','gps_origen')) = 3
            then 'si' else 'revisar' end
union all
select 'conectados con ubicacion de ingreso disponible',
       (select count(distinct a.user_id)::text
          from public.auditoria_accesos a
         where a.evento='ingreso' and a.gps ~ '^\s*-?\d+(\.\d+)?\s*,'
           and a.creado_en >= now() - interval '2 days');
