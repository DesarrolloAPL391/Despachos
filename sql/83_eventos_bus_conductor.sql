-- ============================================================================================
-- 83) SEGURIDAD VIAL: ponerle CONDUCTOR a los eventos que caen entre viaje y viaje
--
-- Medido el 20/09/2026 sobre 4 móviles del día anterior:
--     móvil 5070 → 105 eventos, 6 viajes, 21 con conductor
--     móvil 5514 → 103 eventos, 7 viajes, 19 con conductor
--     móvil 8170 →  33 eventos, 5 viajes,  2 con conductor
-- Es decir: los viajes existen, pero la mayoría de los eventos NO caen dentro de la ventana de
-- un viaje (pasan en el traslado al terminal, en la espera, al salir del patio). Con la regla
-- anterior —solo dentro del viaje— se perdía el 80% de la información, y sin conductor una
-- estadística de seguridad vial no sirve para sensibilizar a nadie.
--
-- Regla nueva, en orden y sin inventar:
--   1. si el evento cae DENTRO de un viaje       → ese conductor;
--   2. si no, se mira el viaje que terminó hasta 60 min antes y el que arranca hasta 60 min
--      después:
--        · si los dos son del MISMO conductor, o solo existe uno → ese conductor;
--        · si son de conductores DISTINTOS → se deja SIN conductor (hubo cambio de turno y
--          atribuirlo sería acusar al que no fue).
--   3. fuera de eso → sin conductor.
--
-- Además: el resumen ahora cuenta EPISODIOS, no lecturas sueltas. Un bus que va tres minutos a
-- 65 km/h genera varias lecturas seguidas; eso es UNA vez que se pasó, no ocho. Se agrupan las
-- lecturas del mismo móvil y tipo separadas por menos de 5 minutos.
--
-- Se aplica sobre una base con sql/81 y sql/82 ya ejecutados. No borra nada: vuelve a resolver
-- el conductor de lo que ya está guardado.
-- ============================================================================================

-- 1) Quién manejaba en un instante dado ------------------------------------------------------
create or replace function public.eventos_bus_conductor(p_mid text, p_ts timestamptz)
returns table (itl_id bigint, ruta text, conductor text, origen text)
language sql
stable
security definer
set search_path = public
as $$
  with t as (select (p_ts at time zone 'America/Bogota') as ts),
  v as (
    select d.itl_id, d.ruta, d.conductor,
           (d.fecha + d.hora_inicio) as ini,
           (d.fecha + d.hora_inicio
             + make_interval(secs => case when coalesce(d.elapsed_seg, 0) > 0
                                          then d.elapsed_seg else 5400 end)) as fin
    from public.despachos_sonar d, t
    where d.mid = p_mid
      and d.hora_inicio is not null
      and coalesce(btrim(d.conductor), '') <> ''
      and d.fecha between (t.ts)::date - 1 and (t.ts)::date + 1
  ),
  dentro as (
    select v.itl_id, v.ruta, v.conductor from v, t
    where t.ts between v.ini and v.fin
    order by v.ini desc limit 1
  ),
  antes as (
    select v.itl_id, v.ruta, v.conductor from v, t
    where v.fin <= t.ts and v.fin > t.ts - interval '60 minutes'
    order by v.fin desc limit 1
  ),
  despues as (
    select v.itl_id, v.ruta, v.conductor from v, t
    where v.ini >= t.ts and v.ini < t.ts + interval '60 minutes'
    order by v.ini asc limit 1
  )
  select z.itl_id, z.ruta, z.conductor, z.origen
  from (
    select 1 as prio, d.itl_id, d.ruta, d.conductor, 'en viaje'::text as origen from dentro d
    union all
    -- entre viajes: solo si no hay duda de quién iba (mismo conductor antes y después, o uno solo)
    select 2, a.itl_id, a.ruta, a.conductor, 'entre viajes'
    from antes a
    where not exists (select 1 from dentro)
      and (not exists (select 1 from despues)
           or exists (select 1 from despues p where upper(btrim(p.conductor)) = upper(btrim(a.conductor))))
    union all
    select 3, p.itl_id, p.ruta, p.conductor, 'entre viajes'
    from despues p
    where not exists (select 1 from dentro) and not exists (select 1 from antes)
  ) z
  order by z.prio
  limit 1;
$$;
revoke all on function public.eventos_bus_conductor(text, timestamptz) from public, anon, authenticated;

-- 2) El barrido usa esa regla ----------------------------------------------------------------
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
        -- Qué es conducta de riesgo (y qué NO): las aperturas y cierres normales de puerta pasan
        -- en cada parada y no entran; los pings de posición que superan el RoadSpeed por 2-4 km/h
        -- tampoco. Se guarda: rodar con puerta abierta, el exceso que marca SONAR, y cualquier
        -- lectura por encima del umbral de la empresa (60 km/h), venga del evento que venga.
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
        r.ocurrido_en, v_mid, v_movil,
        r.tipo,
        coalesce(r.evento, case when r.tipo = 'velocidad' then 'Velocidad alta' else 'Exceso de velocidad' end),
        r.velocidad, r.limite, coalesce(r.sobre_umbral, false), r.direccion, r.lat, r.lon,
        v.itl_id, v.ruta, v.conductor, cs.cedula, cs.codigo
      from riesgo r
      left join lateral public.eventos_bus_conductor(v_mid, r.ocurrido_en) v on true
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

-- 3) Volver a resolver el conductor de lo YA guardado (no hay que bajar nada de SONAR) --------
create or replace function public.eventos_bus_reasignar(p_desde date, p_hasta date)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_n int;
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador puede reasignar.');
  end if;
  with pendientes as (
    select e.id, x.itl_id, x.ruta, x.conductor, cs.cedula, cs.codigo
    from public.eventos_bus e
    left join lateral public.eventos_bus_conductor(e.mid, e.ocurrido_en) x on true
    left join public.conductores_sonar cs
      on x.conductor is not null and upper(btrim(cs.nombre)) = upper(btrim(x.conductor))
    where e.fecha between p_desde and p_hasta
      and e.conductor is null
  )
  update public.eventos_bus e
     set itl_id           = r.itl_id,
         ruta             = coalesce(r.ruta, e.ruta),
         conductor        = r.conductor,
         conductor_cedula = r.cedula,
         conductor_codigo = r.codigo
    from pendientes r
   where r.id = e.id and r.conductor is not null;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'reasignados', v_n,
    'sin_conductor', (select count(1) from public.eventos_bus
                       where fecha between p_desde and p_hasta and conductor is null),
    'total', (select count(1) from public.eventos_bus where fecha between p_desde and p_hasta));
end $$;
revoke all on function public.eventos_bus_reasignar(date, date) from public, anon;
grant execute on function public.eventos_bus_reasignar(date, date) to authenticated;

-- 4) El resumen cuenta EPISODIOS, no lecturas sueltas -----------------------------------------
-- Tres minutos a 65 km/h son varias lecturas seguidas: eso es UNA vez que se pasó, no ocho.
-- Se agrupan las lecturas del mismo móvil y tipo separadas por menos de 5 minutos.
create or replace function public.eventos_bus_resumen(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_items jsonb; v_dias int; v_umbral numeric;
begin
  if not (public.es_admin() or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador y los auditores ven los eventos.');
  end if;
  select umbral_kmh into v_umbral from public.eventos_bus_config where id = 1;

  select coalesce(jsonb_agg(x order by n_rap desc, n_exc desc, n_pue desc), '[]'::jsonb) into v_items
  from (
    select
      coalesce(sum(b.inicio) filter (where b.sobre_umbral), 0)    as n_rap,
      coalesce(sum(b.inicio) filter (where b.tipo = 'exceso'), 0) as n_exc,
      coalesce(sum(b.inicio) filter (where b.tipo = 'puerta'), 0) as n_pue,
      jsonb_build_object(
        'conductor', coalesce(b.conductor, '(sin viaje asociado)'),
        'cedula',    b.conductor_cedula,
        'codigo',    b.conductor_codigo,
        'excesos',   coalesce(sum(b.inicio) filter (where b.tipo = 'exceso'), 0),
        'rapidos',   coalesce(sum(b.inicio) filter (where b.sobre_umbral), 0),
        'puertas',   coalesce(sum(b.inicio) filter (where b.tipo = 'puerta'), 0),
        'lecturas',  count(1),
        'peor_exceso', max(b.exceso_kmh) filter (where b.tipo = 'exceso'),
        'vel_max',   max(b.velocidad),
        'dias',      count(distinct b.fecha),
        'moviles',   count(distinct b.movil),
        'ultimo',    to_char(max(b.fecha), 'YYYY-MM-DD')
      ) as x
    from (
      select e.*,
        (coalesce(extract(epoch from (e.ocurrido_en
           - lag(e.ocurrido_en) over (partition by e.mid, e.tipo, e.conductor order by e.ocurrido_en))),
          1e9) > 300)::int as inicio
      from public.eventos_bus e
      where e.fecha between p_desde and p_hasta
    ) b
    group by b.conductor, b.conductor_cedula, b.conductor_codigo
  ) s;

  select count(distinct fecha) into v_dias from public.eventos_bus where fecha between p_desde and p_hasta;
  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
                            'dias_con_datos', v_dias, 'items', v_items, 'umbral_kmh', v_umbral,
                            'por_episodios', true);
end $$;
revoke all on function public.eventos_bus_resumen(date, date) from public, anon;
grant execute on function public.eventos_bus_resumen(date, date) to authenticated;
