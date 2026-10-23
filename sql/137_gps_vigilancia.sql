-- 137_gps_vigilancia.sql
-- "siempre tenemos los carros operativos desde SONAR, que SONAR entregue la posicion, no
--  podemos vigilar que eso sea asi y reportar a los auditores si un carro dejo de reportar"
--  (23/10/2026).
--
-- Hasta ahora habia que ABRIR la pantalla para enterarse. Esto lo da vuelta: cada 10 minutos la
-- base revisa sola y, cuando un carro que esta operando deja de dar posicion, abre una alerta
-- que le aparece a los auditores y al administrador en el menu.
--
-- QUIEN DEBERIA ESTAR REPORTANDO (lo dice SONAR, no nosotros):
-- `moviles_operacion` es el espejo de GET_MobileOperationInfo, refrescado cada 2 minutos. Trae
-- 338 filas (toda la flota) con el viaje asignado y, lo importante, `ultimo_gps`: la hora del
-- ultimo reporte SEGUN SONAR. El universo vigilado son los que tienen un viaje **iniciado hoy y
-- hace menos de 4 horas**: eso es un carro que deberia estar rodando ahora. Sin el limite de las
-- 4 horas, a las 23:00 se alertaria por carros que terminaron su jornada a las 10 de la manana.
--
-- EL UMBRAL son 20 MINUTOS, y no es un numero al azar. Medido el 23/10/2026 a las 10:32 sobre
-- los buses que salieron: +10 min -> 25 carros, +15 -> 19, +20 -> 15, +30 -> 15, +45 -> 14.
-- La curva se APLANA en 20 minutos: antes de ahi lo que se cuenta es ruido (un tunel, un reporte
-- esporadico); de ahi en adelante lo que queda son fallas de verdad. Sobre el universo de SONAR
-- (175 carros con viaje de hoy) el umbral de 20 minutos deja **3 alertas**, no 15.
--
-- SE GUARDA EL DESFASE con nuestra propia tabla `ubicaciones`. Si SONAR dice que el carro
-- reporto hace 2 minutos y nosotros lo tenemos hace 3 horas, el problema NO es del equipo sino
-- de nuestra sincronizacion, y hay que arreglarlo aqui. Medido hoy: desfase 0 en los 3 casos,
-- o sea que `sync_ubicaciones` esta al dia y lo que falla son los equipos.
--
-- UNA ALERTA POR CARRO: se abre cuando deja de reportar y se cierra sola cuando vuelve. No se
-- cierra al terminar la jornada, a proposito: un carro que lleva 94 dias mudo tiene UNA alerta
-- de 94 dias, no 94 alertas. El auditor puede marcarla como vista sin cerrarla (eso lo hace el
-- equipo cuando vuelve a dar señal).
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

create table if not exists public.gps_alertas (
  id               bigserial primary key,
  movil            text not null,
  placa            text,
  mid              text,
  ruta             text,
  abierta_en       timestamptz not null default now(),
  fecha            date not null default (now() at time zone 'America/Bogota')::date,
  ultimo_reporte   timestamptz,
  minutos_al_abrir int,
  desfase_min      int,
  estado           text not null default 'ABIERTA' check (estado in ('ABIERTA', 'CERRADA')),
  cerrada_en       timestamptz,
  motivo_cierre    text,
  atendida_en      timestamptz,
  atendida_por     text,
  nota             text
);

comment on table  public.gps_alertas is 'Un carro que SONAR tiene operando y dejo de entregar posicion (sql/137).';
comment on column public.gps_alertas.desfase_min is 'SONAR menos nuestra tabla. Si es grande, el que esta mal somos nosotros, no el equipo.';
comment on column public.gps_alertas.atendida_en is 'El auditor vio la alerta. No la cierra: la cierra el equipo cuando vuelve a reportar.';

-- Una sola alerta abierta por movil: sin esto el cron abriria una cada 10 minutos.
create unique index if not exists gps_alertas_una_abierta
  on public.gps_alertas (movil) where estado = 'ABIERTA';
create index if not exists gps_alertas_abiertas_idx
  on public.gps_alertas (estado, abierta_en desc);

-- Nadie lee la tabla directo: todo pasa por las funciones de abajo, que validan el rol.
alter table public.gps_alertas enable row level security;

-- ---------------------------------------------------------------------------
-- La vigilancia. La corre el cron; no la llama nadie desde la app.
-- ---------------------------------------------------------------------------
create or replace function public.gps_vigilar(p_min int default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_abiertas int := 0;
  v_cerradas int := 0;
  v_op       int := 0;
begin
  drop table if exists _op;
  create temp table _op on commit drop as
  select btrim(coalesce(o.movil, ''))      as movil,
         max(o.placa)                      as placa,
         max(o.mid)                        as mid,
         max(o.ruta)                       as ruta,
         max(o.ultimo_gps)                 as sonar,
         max(u.gps_gmt)                    as nuestro
    from public.moviles_operacion o
    left join public.ubicaciones u
           on btrim(coalesce(u.movil, '')) = btrim(coalesce(o.movil, ''))
   where btrim(coalesce(o.movil, '')) <> ''
     and o.inicio is not null
     and (o.inicio at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date
     and o.inicio > now() - interval '4 hours'
   group by btrim(coalesce(o.movil, ''));

  select count(*) into v_op from _op;

  -- Guardia: si SONAR respondio mal y la tabla vino vacia o casi, NO se abre nada. Una alerta
  -- falsa en masa quema la confianza en el aviso y despues nadie lo mira.
  if v_op < 5 then
    return jsonb_build_object('ok', true, 'operando', v_op, 'abiertas', 0, 'cerradas', 0,
                              'nota', 'muy pocos moviles en operacion: no se vigila');
  end if;

  with nuevas as (
    insert into public.gps_alertas (movil, placa, mid, ruta, ultimo_reporte,
                                    minutos_al_abrir, desfase_min)
    select o.movil, o.placa, o.mid, o.ruta, o.sonar,
           (extract(epoch from (now() - o.sonar)) / 60)::int,
           case when o.sonar is null or o.nuestro is null then null
                else (extract(epoch from (o.sonar - o.nuestro)) / 60)::int end
      from _op o
     where (o.sonar is null or o.sonar <= now() - make_interval(mins => p_min))
       and not exists (select 1 from public.gps_alertas a
                        where a.movil = o.movil and a.estado = 'ABIERTA')
    returning 1
  ) select count(*) into v_abiertas from nuevas;

  -- Se cierra cuando el equipo vuelve a dar señal, este operando o no.
  with cerradas as (
    update public.gps_alertas a
       set estado = 'CERRADA', cerrada_en = now(), motivo_cierre = 'volvio a reportar'
     where a.estado = 'ABIERTA'
       and exists (select 1 from public.ubicaciones u
                    where btrim(coalesce(u.movil, '')) = a.movil
                      and u.gps_gmt > now() - make_interval(mins => p_min))
    returning 1
  ) select count(*) into v_cerradas from cerradas;

  return jsonb_build_object('ok', true, 'operando', v_op,
                            'abiertas', v_abiertas, 'cerradas', v_cerradas,
                            'total_abiertas', (select count(*) from public.gps_alertas
                                                where estado = 'ABIERTA'));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

revoke all on function public.gps_vigilar(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lo que ve la app: las alertas abiertas (administrador y auditores)
-- ---------------------------------------------------------------------------
create or replace function public.gps_alertas_abiertas()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case when not ((select public.es_admin()) or (select public.es_auditor()))
              then jsonb_build_object('ok', false, 'error', 'Solo administracion y control.')
  else jsonb_build_object(
    'ok', true,
    'total', (select count(*) from public.gps_alertas where estado = 'ABIERTA'),
    'sin_ver', (select count(*) from public.gps_alertas
                 where estado = 'ABIERTA' and atendida_en is null),
    'lista', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', a.id, 'movil', a.movil, 'placa', a.placa, 'ruta', a.ruta, 'mid', a.mid,
                'desde', to_char(a.abierta_en at time zone 'America/Bogota', 'DD/MM HH24:MI'),
                'hace', case
                  when now() - a.abierta_en >= interval '2 days'
                    then extract(day from now() - a.abierta_en)::int || ' días'
                  when now() - a.abierta_en >= interval '1 day' then '1 día'
                  when now() - a.abierta_en >= interval '1 hour'
                    then floor(extract(epoch from now() - a.abierta_en) / 3600)::int || ' horas'
                  else greatest(1, floor(extract(epoch from now() - a.abierta_en) / 60)::int) || ' min'
                  end,
                'ultimo', coalesce(to_char(a.ultimo_reporte at time zone 'America/Bogota',
                                           'DD/MM/YYYY HH24:MI'), 'nunca'),
                'desfase_min', a.desfase_min,
                'vista', a.atendida_en is not null,
                'vista_por', a.atendida_por,
                'nota', a.nota
              ) order by a.abierta_en desc), '[]'::jsonb)
              from public.gps_alertas a where a.estado = 'ABIERTA'))
  end;
$function$;

revoke all on function public.gps_alertas_abiertas() from public, anon;
grant execute on function public.gps_alertas_abiertas() to authenticated;

-- El auditor deja constancia de que la vio y de lo que hizo. NO cierra la alerta:
-- la cierra el equipo cuando vuelve a reportar.
create or replace function public.gps_alerta_vista(p_id bigint, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not ((select public.es_admin()) or (select public.es_auditor())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y control.');
  end if;
  update public.gps_alertas
     set atendida_en = now(),
         atendida_por = coalesce(auth.jwt() ->> 'email', atendida_por),
         nota = coalesce(nullif(btrim(p_nota), ''), nota)
   where id = p_id and estado = 'ABIERTA';
  if not found then return jsonb_build_object('ok', false, 'error', 'Esa alerta ya no esta abierta.'); end if;
  return jsonb_build_object('ok', true);
end $function$;

revoke all on function public.gps_alerta_vista(bigint, text) from public, anon;
grant execute on function public.gps_alerta_vista(bigint, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Cada 10 minutos. Es una consulta a tablas locales (no llama a SONAR): barata y sin riesgo
-- del tope de 120 s de los crons.
-- ---------------------------------------------------------------------------
select cron.unschedule('gps-vigilar') where exists (select 1 from cron.job where jobname = 'gps-vigilar');
select cron.schedule('gps-vigilar', '*/10 * * * *', $cron$select public.gps_vigilar()$cron$);

-- Comprobacion (solo lectura; la primera pasada la hace el cron o una llamada aparte)
select 'carros con viaje de hoy (ultimas 4 h)' as dato,
       (select count(*)::text from public.moviles_operacion o
         where o.inicio is not null
           and (o.inicio at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date
           and o.inicio > now() - interval '4 hours') as valor
union all
select 'de esos, sin posicion hace +20 min',
       (select count(*)::text from public.moviles_operacion o
         where o.inicio is not null
           and (o.inicio at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date
           and o.inicio > now() - interval '4 hours'
           and (o.ultimo_gps is null or o.ultimo_gps <= now() - interval '20 minutes'))
union all
select 'cron gps-vigilar activo',
       (select case when count(*) > 0 then 'si' else 'NO' end::text
          from cron.job where jobname = 'gps-vigilar' and active)
union all
select 'indice de una sola alerta abierta por movil',
       (select case when count(*) > 0 then 'si' else 'NO' end::text
          from pg_indexes where schemaname = 'public' and indexname = 'gps_alertas_una_abierta');
