-- ============================================================================================
-- 81) HISTÓRICO DE EVENTOS DE CONDUCCIÓN (seguridad vial)
--
-- El visor 🔎 "Eventos del bus" (sql/13) consulta SONAR EN VIVO: sirve para investigar un caso,
-- pero no deja histórico, así que no se puede responder "¿qué conductor anduvo con excesos de
-- velocidad este mes?". Esto lo guarda.
--
-- Qué se guarda: SOLO la conducta de manejo, no todos los eventos del bus:
--   · exceso de velocidad REAL     (Speed > RoadSpeed, el límite de esa vía; lo marca SONAR)
--   · pasar del UMBRAL de la empresa (60 km/h por defecto, en eventos_bus_config) aunque la vía
--     permita más: en servicio urbano con pasajeros de pie eso ya es riesgo
--   · conducir con la puerta abierta
-- (los pasos por geocerca y los avisos de itinerario NO se guardan: son miles y ya se auditan
--  en despachos_sonar; aquí interesa el riesgo).
--
-- Quién iba manejando: el evento se cruza con el VIAJE REAL de SONAR (despachos_sonar: mid +
-- hora de inicio + duración) y de ahí sale el conductor; la cédula se resuelve con
-- conductores_sonar por nombre, para poder cruzarlo con el perfil sociodemográfico
-- y con los siniestros (sql/79).
--
-- COBERTURA: se revisan TODOS los carros. La lista de trackers no sale de una sola tabla, sino
-- de `vehiculosgps` + la foto en vivo de la flota (`ubicaciones`) + los móviles que despacharon en
-- los últimos 60 días (`eventos_bus_trackers`), porque de aquí van a salir alertas y campañas de
-- sensibilización: un carro que falte es un conductor que no se entera.
--
-- Se aplica DESPUÉS de sql/13, sql/15 y sql/65 (usa SONAR, despachos_sonar, ubicaciones y vehiculosgps).
-- ============================================================================================

-- 1) Los eventos de riesgo, uno por fila ------------------------------------------------------
create table if not exists public.eventos_bus (
  id               bigserial primary key,
  fecha            date        not null,          -- día (hora de Colombia)
  ocurrido_en      timestamptz not null,          -- momento exacto del evento
  mid              text        not null,          -- tracker en SONAR
  movil            text,                          -- número interno del bus
  tipo             text        not null,          -- 'exceso' | 'velocidad' | 'puerta'
  evento           text,                          -- texto tal como lo manda SONAR
  velocidad        numeric,                       -- km/h del bus
  limite           numeric,                       -- km/h de la vía (RoadSpeed)
  exceso_kmh       numeric generated always as (
                     case when velocidad is not null and limite is not null and limite > 0
                          then velocidad - limite end) stored,
  sobre_umbral     boolean not null default false,  -- pasó del umbral (60 km/h) aunque la vía permitiera más
  direccion        text,
  lat              numeric,
  lon              numeric,
  -- quién iba manejando (del viaje real de SONAR)
  itl_id           bigint,
  ruta             text,
  conductor        text,
  conductor_cedula text,
  conductor_codigo text,
  creado_en        timestamptz not null default now(),
  unique (mid, ocurrido_en, evento)
);
create index if not exists eventos_bus_fecha_idx     on public.eventos_bus (fecha desc);
create index if not exists eventos_bus_cedula_idx    on public.eventos_bus (conductor_cedula);
create index if not exists eventos_bus_movil_idx     on public.eventos_bus (movil);
create index if not exists eventos_bus_tipo_idx      on public.eventos_bus (tipo, fecha desc);
create index if not exists eventos_bus_umbral_idx    on public.eventos_bus (fecha desc) where sobre_umbral;
comment on table public.eventos_bus is 'Excesos de velocidad y puertas abiertas en marcha, con el conductor que iba manejando (sql/81).';

-- 1.b) Lo que se considera riesgo, configurable sin tocar código -----------------------------
-- `umbral_kmh`: velocidad que ya es riesgo POR SÍ SOLA en servicio urbano (60 por defecto),
-- aunque la vía permita más. `dias_backfill`: cuántos días atrás se revisa solo, sin que nadie
-- toque nada, para que el histórico se complete y se repare si una noche falla.
create table if not exists public.eventos_bus_config (
  id             int primary key default 1 check (id = 1),
  umbral_kmh     numeric not null default 60,
  dias_backfill  int     not null default 7,
  actualizado_en timestamptz not null default now()
);
insert into public.eventos_bus_config (id) values (1) on conflict (id) do nothing;

-- 2) Control del barrido: qué móvil de qué día ya se trajo ------------------------------------
create table if not exists public.eventos_bus_sync (
  fecha           date not null,
  mid             text not null,
  eventos         int  not null default 0,        -- cuántos de riesgo quedaron guardados
  ok              boolean not null default true,
  error           text,
  sincronizado_en timestamptz not null default now(),
  primary key (fecha, mid)
);

-- 3) Permisos: auditoría de la operación (admin y auditor) ------------------------------------
alter table public.eventos_bus        enable row level security;
alter table public.eventos_bus_sync   enable row level security;
alter table public.eventos_bus_config enable row level security;

drop policy if exists eventos_bus_config_admin on public.eventos_bus_config;
create policy eventos_bus_config_admin on public.eventos_bus_config
  for all to authenticated
  using ((select public.es_admin()) or (select public.es_auditor()))
  with check ((select public.es_admin()));
revoke all on public.eventos_bus_config from public, anon;
grant select, update on public.eventos_bus_config to authenticated;

drop policy if exists eventos_bus_ver on public.eventos_bus;
create policy eventos_bus_ver on public.eventos_bus
  for select to authenticated
  using ((select public.es_admin()) or (select public.es_auditor()));

drop policy if exists eventos_bus_sync_ver on public.eventos_bus_sync;
create policy eventos_bus_sync_ver on public.eventos_bus_sync
  for select to authenticated
  using ((select public.es_admin()) or (select public.es_auditor()));

revoke all on public.eventos_bus      from public, anon;
revoke all on public.eventos_bus_sync from public, anon;
grant select on public.eventos_bus      to authenticated;
grant select on public.eventos_bus_sync to authenticated;
revoke all on sequence public.eventos_bus_id_seq from public, anon;

-- 3.b) TODOS los carros: la lista de trackers no puede salir de una sola tabla ---------------
-- `vehiculosgps` es el maestro, pero puede tener huecos (un carro nuevo, un GPS cambiado).
-- Se une con la foto en vivo de la flota (`ubicaciones`, que refresca SONAR cada minuto) y con
-- los móviles que despacharon en los últimos 60 días. Así ningún carro se queda sin revisar.
create or replace function public.eventos_bus_trackers()
returns table (mid text, movil text)
language sql
stable
security definer
set search_path = public
as $$
  select t.mid, max(t.movil) as movil
  from (
    select g.tracker_id::text, g.movil::text from public.vehiculosgps g where coalesce(g.tracker_id, '') <> ''
    union all
    select u.mid::text, u.movil::text from public.ubicaciones u where coalesce(u.mid, '') <> ''
    union all
    select d.mid::text, d.movil::text from public.despachos_sonar d
      where coalesce(d.mid, '') <> '' and d.fecha > ((now() at time zone 'America/Bogota')::date - 60)
  ) as t(mid, movil)
  group by t.mid;
$$;
-- Uso interno (el barrido y el estado, que ya son security definer): la lista de trackers no
-- tiene por qué quedar expuesta a cualquier usuario con sesión.
revoke all on function public.eventos_bus_trackers() from public, anon, authenticated;

-- 4) NÚCLEO del barrido: trae de SONAR los eventos de una fecha para los móviles pendientes ---
--    Sin guard de rol (lo corre pg_cron o el wrapper de admin). Va por lotes: si se corta,
--    la siguiente corrida sigue donde quedó, porque se salta los que ya están en *_sync.
create or replace function public.eventos_bus_core(p_fecha date, p_limite int default 60)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sa text;
  v_mid text; v_movil text; v_body text; v_resp text; v_xml xml; v_status text;
  v_ini text; v_fin text;
  v_n int; v_tot int := 0; v_mov int := 0; v_err int := 0; v_pend int;
  v_umbral numeric;
begin
  -- Un solo barrido a la vez: si la corrida anterior se está demorando, esta no la pisa.
  if not pg_try_advisory_lock(hashtext('eventos_bus_core')) then
    return jsonb_build_object('ok', true, 'saltado', true, 'motivo', 'ya hay un barrido corriendo');
  end if;

  select coalesce(umbral_kmh, 60) into v_umbral from public.eventos_bus_config where id = 1;
  v_umbral := coalesce(v_umbral, 60);
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  select regexp_replace(decrypted_secret, '/[^/]+$', '') into v_sa
    from vault.decrypted_secrets where name = 'SONAR_SOAPACTION';
  if v_url is null then
    perform pg_advisory_unlock(hashtext('eventos_bus_core'));
    return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault');
  end if;

  -- El día en hora de Colombia, convertido a UTC (SONAR pide UTC)
  v_ini := to_char((p_fecha::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(((p_fecha + 1)::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');

  perform set_config('http.timeout_msec', '30000', true); -- un móvil colgado no se come la corrida

  for v_mid, v_movil in
    select k.mid, k.movil
    from public.eventos_bus_trackers() k
    where not exists (select 1 from public.eventos_bus_sync s
                      where s.fecha = p_fecha and s.mid = k.mid and s.ok)
    order by k.mid
    limit greatest(p_limite, 1)
  loop
    v_n := 0;
    begin
      v_body :=
        '<?xml version="1.0" encoding="utf-8"?>'
        || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
        || '<GET_TrackerEventsHistoryV2 xmlns="' || v_ns || '">'
        || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
        || '<mId>' || v_mid || '</mId><eventID></eventID>'
        || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
        || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
        || '</GET_TrackerEventsHistoryV2></soap:Body></soap:Envelope>';

      select content into v_resp from extensions.http((
        'POST', v_url,
        array[extensions.http_header('SOAPAction', v_sa || '/GET_TrackerEventsHistoryV2')],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_xml := v_resp::xml;
      v_status := (xpath('//x:status/text()', v_xml, array[array['x', v_ns]]))[1]::text;
      if coalesce(v_status, '') <> 'OK' then
        raise exception 'SONAR respondió %', coalesce(v_status, '?');
      end if;

      with crudo as (
        select
          ((xpath('/x:TrackerEventV2/x:GpsGMT/text()', n, array[array['x', v_ns]]))[1]::text)::timestamp
            at time zone 'UTC'                                                        as ocurrido_en,
          (xpath('/x:TrackerEventV2/x:eventDescription/text()', n, array[array['x', v_ns]]))[1]::text as evento,
          (xpath('/x:TrackerEventV2/x:Address/text()', n, array[array['x', v_ns]]))[1]::text          as direccion,
          nullif((xpath('/x:TrackerEventV2/x:Speed/text()',     n, array[array['x', v_ns]]))[1]::text, '')::numeric as velocidad,
          nullif((xpath('/x:TrackerEventV2/x:RoadSpeed/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric as limite,
          nullif((xpath('/x:TrackerEventV2/x:Latitude/text()',  n, array[array['x', v_ns]]))[1]::text, '')::numeric as lat,
          nullif((xpath('/x:TrackerEventV2/x:Longitude/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric as lon
        from unnest(xpath('//x:TrackerEventV2', v_xml, array[array['x', v_ns]])) as n
      ), riesgo as (
        -- Conducta de manejo, por tres caminos. OJO con lo que NO entra:
        --   · las aperturas y cierres normales de puerta (pasan en cada parada, son cientos al
        --     día): solo interesa "conduciendo con PUERTA ABIERTA";
        --   · los reportes periódicos de posición cuya velocidad supera por poco el RoadSpeed
        --     (ej. 24 en una vía de 20): eso no es un exceso marcado por SONAR, es ruido.
        -- Se guarda:
        --   · puerta abierta en marcha,
        --   · el evento de EXCESO que marca SONAR (con la velocidad y el límite de la vía),
        --   · cualquier lectura que pase del umbral de la empresa (60 km/h), venga del evento
        --     que venga: en servicio urbano con pasajeros de pie eso ya es riesgo.
        select c.*,
          case when c.evento ilike '%puerta abierta%' then 'puerta'
               when c.evento ilike '%exceso%'        then 'exceso'
               else 'velocidad' end as tipo,
          (c.velocidad is not null and c.velocidad > v_umbral) as sobre_umbral
        from crudo c
        where c.evento ilike '%puerta abierta%'
           or c.evento ilike '%exceso%'
           or (c.velocidad is not null and c.velocidad > v_umbral)
      )
      insert into public.eventos_bus
        (fecha, ocurrido_en, mid, movil, tipo, evento, velocidad, limite, sobre_umbral,
         direccion, lat, lon, itl_id, ruta, conductor, conductor_cedula, conductor_codigo)
      select
        (r.ocurrido_en at time zone 'America/Bogota')::date,
        r.ocurrido_en, v_mid,
        coalesce(v.conductor_movil, v_movil),
        r.tipo,
        coalesce(r.evento, case when r.tipo = 'velocidad' then 'Velocidad alta' else 'Exceso de velocidad' end),
        r.velocidad, r.limite, coalesce(r.sobre_umbral, false), r.direccion, r.lat, r.lon,
        v.itl_id, v.ruta, v.conductor, cs.cedula, cs.codigo
      from riesgo r
      -- El viaje real que estaba corriendo en ese momento (de ahí sale el conductor)
      left join lateral (
        select d.itl_id, d.ruta, d.conductor, d.movil as conductor_movil
        from public.despachos_sonar d
        where d.mid = v_mid
          and d.hora_inicio is not null
          and d.fecha between (r.ocurrido_en at time zone 'America/Bogota')::date - 1
                          and (r.ocurrido_en at time zone 'America/Bogota')::date
          and (d.fecha + d.hora_inicio) <= (r.ocurrido_en at time zone 'America/Bogota')
          and (r.ocurrido_en at time zone 'America/Bogota')
              <= (d.fecha + d.hora_inicio
                  + make_interval(secs => case when coalesce(d.elapsed_seg, 0) > 0
                                               then d.elapsed_seg else 5400 end))
        order by d.fecha desc, d.hora_inicio desc
        limit 1
      ) v on true
      left join public.conductores_sonar cs
        on v.conductor is not null and upper(btrim(cs.nombre)) = upper(btrim(v.conductor))
      on conflict (mid, ocurrido_en, evento) do nothing;

      get diagnostics v_n = row_count;
      v_tot := v_tot + v_n; v_mov := v_mov + 1;

      insert into public.eventos_bus_sync (fecha, mid, eventos, ok, error, sincronizado_en)
      values (p_fecha, v_mid, v_n, true, null, now())
      on conflict (fecha, mid) do update
        set eventos = excluded.eventos, ok = true, error = null, sincronizado_en = now();

    exception when others then
      v_err := v_err + 1;
      insert into public.eventos_bus_sync (fecha, mid, eventos, ok, error, sincronizado_en)
      values (p_fecha, v_mid, 0, false, left(sqlerrm, 300), now())
      on conflict (fecha, mid) do update
        set ok = false, error = excluded.error, sincronizado_en = now();
    end;
  end loop;

  select count(1) into v_pend
  from public.eventos_bus_trackers() k
  where not exists (select 1 from public.eventos_bus_sync s
                    where s.fecha = p_fecha and s.mid = k.mid and s.ok);

  perform pg_advisory_unlock(hashtext('eventos_bus_core'));
  return jsonb_build_object('ok', true, 'fecha', p_fecha, 'moviles', v_mov,
                            'eventos', v_tot, 'fallidos', v_err, 'pendientes', v_pend,
                            'umbral_kmh', v_umbral);
end $$;
revoke all on function public.eventos_bus_core(date, int) from public, anon, authenticated;

-- 5) Barrido automático del día anterior (lotes pequeños, se salta lo ya traído) --------------
-- Sin intervención humana: cada corrida busca el día MÁS RECIENTE que aún tenga carros sin
-- revisar (desde ayer hacia atrás, hasta `dias_backfill`) y lo trabaja. Así:
--   · el día de ayer se completa en las primeras corridas de la madrugada,
--   · si una noche falla SONAR o se cae la conexión, la noche siguiente lo recupera solo,
--   · al aplicar este archivo, los días anteriores se llenan solos (no hay que tocar botones).
create or replace function public.eventos_bus_nocturno()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  v_dias  int;
  v_f     date;
  v_pend  int;
begin
  select coalesce(dias_backfill, 7) into v_dias from public.eventos_bus_config where id = 1;
  v_dias := greatest(coalesce(v_dias, 7), 1);
  for v_f in
    select d::date from generate_series(v_hoy - v_dias, v_hoy - 1, interval '1 day') g(d)
    order by d desc
  loop
    select count(1) into v_pend
    from public.eventos_bus_trackers() k
    where not exists (select 1 from public.eventos_bus_sync s
                      where s.fecha = v_f and s.mid = k.mid and s.ok);
    if v_pend > 0 then
      return public.eventos_bus_core(v_f, 60);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'al_dia', true, 'revisado_hasta', v_hoy - 1);
end $$;
revoke all on function public.eventos_bus_nocturno() from public, anon, authenticated;

-- Cada 10 minutos entre las 02:00 y las 06:50 de Colombia (07:00–11:50 UTC): 30 corridas de 60
-- móviles = 1.800 intentos por noche, de sobra para la flota completa (y lo que falle se
-- reintenta en la siguiente corrida). Va DESPUÉS del sync de viajes (06:10 UTC), para que el
-- conductor de cada viaje ya esté en despachos_sonar.
select cron.unschedule('eventos-bus-nocturno')
  where exists (select 1 from cron.job where jobname = 'eventos-bus-nocturno');
select cron.schedule('eventos-bus-nocturno', '*/10 7-11 * * *',
                     'select public.eventos_bus_nocturno();');

-- 6) Carga manual desde la app (botón del administrador) --------------------------------------
create or replace function public.eventos_bus_cargar(p_fecha date, p_limite int default 60)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador puede traer los eventos.');
  end if;
  if p_fecha is null or p_fecha > (now() at time zone 'America/Bogota')::date then
    return jsonb_build_object('ok', false, 'error', 'Elige una fecha que ya haya pasado.');
  end if;
  return public.eventos_bus_core(p_fecha, least(greatest(p_limite, 1), 120));
end $$;
revoke all on function public.eventos_bus_cargar(date, int) from public, anon;
grant execute on function public.eventos_bus_cargar(date, int) to authenticated;

-- 7) Resumen por conductor para la pantalla de seguridad vial ---------------------------------
--    Devuelve, en el periodo pedido, cuánto arriesga cada conductor: excesos, el peor exceso,
--    puertas abiertas en marcha, días con eventos y en cuántos móviles.
create or replace function public.eventos_bus_resumen(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_items jsonb; v_dias int;
begin
  if not (public.es_admin() or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador y los auditores ven los eventos.');
  end if;
  select coalesce(jsonb_agg(x order by n_rap desc, n_exc desc, n_pue desc), '[]'::jsonb) into v_items
  from (
    select
      count(1) filter (where e.tipo = 'exceso') as n_exc,
      count(1) filter (where e.sobre_umbral)    as n_rap,
      count(1) filter (where e.tipo = 'puerta') as n_pue,
      jsonb_build_object(
      'conductor', coalesce(e.conductor, '(sin viaje asociado)'),
      'cedula',    e.conductor_cedula,
      'codigo',    e.conductor_codigo,
      'excesos',   count(1) filter (where e.tipo = 'exceso'),
      'rapidos',   count(1) filter (where e.sobre_umbral),
      'puertas',   count(1) filter (where e.tipo = 'puerta'),
      'peor_exceso', max(e.exceso_kmh) filter (where e.tipo = 'exceso'),
      'vel_max',   max(e.velocidad),
      'dias',      count(distinct e.fecha),
      'moviles',   count(distinct e.movil),
      'ultimo',    to_char(max(e.fecha), 'YYYY-MM-DD')
    ) as x
    from public.eventos_bus e
    where e.fecha between p_desde and p_hasta
    group by e.conductor, e.conductor_cedula, e.conductor_codigo
  ) s;
  select count(distinct fecha) into v_dias from public.eventos_bus where fecha between p_desde and p_hasta;
  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
                            'dias_con_datos', v_dias, 'items', v_items,
                            'umbral_kmh', (select umbral_kmh from public.eventos_bus_config where id = 1));
end $$;
revoke all on function public.eventos_bus_resumen(date, date) from public, anon;
grant execute on function public.eventos_bus_resumen(date, date) to authenticated;

-- 8) Estado de la carga (para la pantalla: hasta qué día hay histórico) -----------------------
create or replace function public.eventos_bus_estado()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when not (public.es_admin() or public.es_auditor()) then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'total',        (select count(1) from public.eventos_bus),
      'desde',        (select min(fecha) from public.eventos_bus),
      'hasta',        (select max(fecha) from public.eventos_bus),
      'ultima_carga', (select max(sincronizado_en) from public.eventos_bus_sync),
      'dias',         (select count(distinct fecha) from public.eventos_bus_sync where ok),
      'umbral_kmh', (select umbral_kmh from public.eventos_bus_config where id = 1),
      'carros',     (select count(1) from public.eventos_bus_trackers()),
      'revisados_ayer', (select count(1) from public.eventos_bus_sync s
                          where s.fecha = (now() at time zone 'America/Bogota')::date - 1 and s.ok),
      'pendientes_ayer', (select count(1) from public.eventos_bus_trackers() k
                           where not exists (select 1 from public.eventos_bus_sync s
                                             where s.fecha = (now() at time zone 'America/Bogota')::date - 1
                                               and s.mid = k.mid and s.ok)))
  end;
$$;
revoke all on function public.eventos_bus_estado() from public, anon;
grant execute on function public.eventos_bus_estado() to authenticated;
