-- ============================================================================================
-- 81) HISTÓRICO DE EVENTOS DE CONDUCCIÓN (seguridad vial)
--
-- El visor 🔎 "Eventos del bus" (sql/13) consulta SONAR EN VIVO: sirve para investigar un caso,
-- pero no deja histórico, así que no se puede responder "¿qué conductor anduvo con excesos de
-- velocidad este mes?". Esto lo guarda.
--
-- Qué se guarda: SOLO la conducta de manejo, no todos los eventos del bus:
--   · exceso de velocidad REAL  (Speed > RoadSpeed de la vía, como en el visor)
--   · conducir con la puerta abierta
-- (los pasos por geocerca y los avisos de itinerario NO se guardan: son miles y ya se auditan
--  en despachos_sonar; aquí interesa el riesgo).
--
-- Quién iba manejando: el evento se cruza con el VIAJE REAL de SONAR (despachos_sonar: mid +
-- hora de inicio + duración) y de ahí sale el conductor; la cédula se resuelve con
-- conductores_sonar por nombre, para poder cruzarlo con el perfil sociodemográfico
-- y con los siniestros (sql/79).
--
-- Se aplica DESPUÉS de sql/13, sql/15 y sql/65 (usa SONAR, despachos_sonar y vehiculosgps).
-- ============================================================================================

-- 1) Los eventos de riesgo, uno por fila ------------------------------------------------------
create table if not exists public.eventos_bus (
  id               bigserial primary key,
  fecha            date        not null,          -- día (hora de Colombia)
  ocurrido_en      timestamptz not null,          -- momento exacto del evento
  mid              text        not null,          -- tracker en SONAR
  movil            text,                          -- número interno del bus
  tipo             text        not null,          -- 'exceso' | 'puerta'
  evento           text,                          -- texto tal como lo manda SONAR
  velocidad        numeric,                       -- km/h del bus
  limite           numeric,                       -- km/h de la vía (RoadSpeed)
  exceso_kmh       numeric generated always as (
                     case when velocidad is not null and limite is not null and limite > 0
                          then velocidad - limite end) stored,
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
comment on table public.eventos_bus is 'Excesos de velocidad y puertas abiertas en marcha, con el conductor que iba manejando (sql/81).';

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
alter table public.eventos_bus      enable row level security;
alter table public.eventos_bus_sync enable row level security;

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

-- 4) NÚCLEO del barrido: trae de SONAR los eventos de una fecha para los móviles pendientes ---
--    Sin guard de rol (lo corre pg_cron o el wrapper de admin). Va por lotes: si se corta,
--    la siguiente corrida sigue donde quedó, porque se salta los que ya están en *_sync.
create or replace function public.eventos_bus_core(p_fecha date, p_limite int default 40)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sa text;
  v_mid text; v_body text; v_resp text; v_xml xml; v_status text;
  v_ini text; v_fin text;
  v_n int; v_tot int := 0; v_mov int := 0; v_err int := 0; v_pend int;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  select regexp_replace(decrypted_secret, '/[^/]+$', '') into v_sa
    from vault.decrypted_secrets where name = 'SONAR_SOAPACTION';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  -- El día en hora de Colombia, convertido a UTC (SONAR pide UTC)
  v_ini := to_char((p_fecha::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(((p_fecha + 1)::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');

  perform set_config('http.timeout_msec', '55000', true); -- el V2 tarda más que el V1

  for v_mid in
    select distinct g.tracker_id
    from public.vehiculosgps g
    where coalesce(g.tracker_id, '') <> ''
      and not exists (select 1 from public.eventos_bus_sync s
                      where s.fecha = p_fecha and s.mid = g.tracker_id and s.ok)
    order by g.tracker_id
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
        -- Solo la conducta de manejo: exceso REAL contra el límite de la vía, o puerta abierta
        select c.*,
          case when c.evento ilike '%puerta%' then 'puerta' else 'exceso' end as tipo
        from crudo c
        where c.evento ilike '%puerta%'
           or (c.velocidad is not null and c.limite is not null and c.limite > 0 and c.velocidad > c.limite)
      )
      insert into public.eventos_bus
        (fecha, ocurrido_en, mid, movil, tipo, evento, velocidad, limite, direccion, lat, lon,
         itl_id, ruta, conductor, conductor_cedula, conductor_codigo)
      select
        (r.ocurrido_en at time zone 'America/Bogota')::date,
        r.ocurrido_en, v_mid,
        coalesce(v.conductor_movil, (select g2.movil from public.vehiculosgps g2 where g2.tracker_id = v_mid limit 1)),
        r.tipo, coalesce(r.evento, 'Exceso de velocidad'), r.velocidad, r.limite, r.direccion, r.lat, r.lon,
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
  from public.vehiculosgps g
  where coalesce(g.tracker_id, '') <> ''
    and not exists (select 1 from public.eventos_bus_sync s
                    where s.fecha = p_fecha and s.mid = g.tracker_id and s.ok);

  return jsonb_build_object('ok', true, 'fecha', p_fecha, 'moviles', v_mov,
                            'eventos', v_tot, 'fallidos', v_err, 'pendientes', v_pend);
end $$;
revoke all on function public.eventos_bus_core(date, int) from public, anon, authenticated;

-- 5) Barrido automático del día anterior (lotes pequeños, se salta lo ya traído) --------------
create or replace function public.eventos_bus_nocturno()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_ayer date := (now() at time zone 'America/Bogota')::date - 1;
begin
  return public.eventos_bus_core(v_ayer, 40);
end $$;
revoke all on function public.eventos_bus_nocturno() from public, anon, authenticated;

-- Cada 10 minutos entre las 02:00 y las 05:50 de Colombia (07:00–10:50 UTC): 24 corridas de 40
-- móviles alcanzan de sobra para la flota, y se corre DESPUÉS del sync de viajes (06:10 UTC),
-- para que el conductor de cada viaje ya esté en despachos_sonar.
select cron.unschedule('eventos-bus-nocturno')
  where exists (select 1 from cron.job where jobname = 'eventos-bus-nocturno');
select cron.schedule('eventos-bus-nocturno', '*/10 7-10 * * *',
                     'select public.eventos_bus_nocturno();');

-- 6) Carga manual desde la app (botón del administrador) --------------------------------------
create or replace function public.eventos_bus_cargar(p_fecha date, p_limite int default 40)
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
  select coalesce(jsonb_agg(x order by n_exc desc, n_pue desc), '[]'::jsonb) into v_items
  from (
    select
      count(1) filter (where e.tipo = 'exceso') as n_exc,
      count(1) filter (where e.tipo = 'puerta') as n_pue,
      jsonb_build_object(
      'conductor', coalesce(e.conductor, '(sin viaje asociado)'),
      'cedula',    e.conductor_cedula,
      'codigo',    e.conductor_codigo,
      'excesos',   count(1) filter (where e.tipo = 'exceso'),
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
                            'dias_con_datos', v_dias, 'items', v_items);
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
      'pendientes_ayer', (select count(1) from public.vehiculosgps g
                           where coalesce(g.tracker_id, '') <> ''
                             and not exists (select 1 from public.eventos_bus_sync s
                                             where s.fecha = (now() at time zone 'America/Bogota')::date - 1
                                               and s.mid = g.tracker_id and s.ok)))
  end;
$$;
revoke all on function public.eventos_bus_estado() from public, anon;
grant execute on function public.eventos_bus_estado() to authenticated;
