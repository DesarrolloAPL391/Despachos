-- ============================================================================================
-- 82) SINIESTROS/SEGURIDAD VIAL: afinar QUÉ se guarda como conducta de riesgo
--
-- La primera prueba de sql/81 trajo 1.086 eventos en 5 móviles de un solo día. Al mirarlos, el
-- filtro estaba cogiendo cosas que no son conducta de riesgo:
--   · "Apertura / Cierre de puerta delantera|trasera": pasa en CADA parada, son cientos al día.
--     Lo que importa es rodar con la puerta abierta, no abrirla en el paradero.
--   · "Reporte por distancia" con 24 km/h donde RoadSpeed decía 20: es el ping periódico de
--     posición, no un exceso marcado por SONAR. Comparar Speed > RoadSpeed en CUALQUIER evento
--     llenaba la tabla de falsos excesos de 2 y 4 km/h.
--
-- Ahora se guarda solo:
--   · "…puerta abierta…"  → conducir con la puerta abierta,
--   · "…exceso…"          → el exceso que marca SONAR, con la velocidad y el límite de la vía,
--   · cualquier lectura por encima del umbral de la empresa (eventos_bus_config.umbral_kmh = 60).
--
-- Se aplica sobre una base donde ya se ejecutó sql/81. Borra lo que se cargó con el criterio
-- viejo (era ruido) y deja el barrido listo para volver a llenar con el criterio bueno.
-- ============================================================================================

-- 1) Fuera lo cargado con el criterio viejo (y el control, para que se vuelva a traer) --------
truncate table public.eventos_bus;
delete from public.eventos_bus_sync;

-- 2) El núcleo, con el criterio corregido -----------------------------------------------------
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
