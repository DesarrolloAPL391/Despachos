-- ============================================================================
-- 17_refrescar_estados_sonar.sql  (v145)
-- Automatiza traer el ESTADO REAL de SONAR de los despachos hechos DESDE la app.
--
-- La app ya despacha desde las tablas de puesto y guarda el regId (sonar_regid),
-- que ES el itlId de SONAR. Esta función recorre TODAS las tablas despachables,
-- toma los viajes de HOY cuyo estado real todavía no se trajo (o sigue "En
-- progreso"), y por cada móvil llama GET_DispatchedVehicles y hace upsert en
-- public.despachos_sonar. Así el Completo/Incompleto/Cancelado/En progreso queda
-- guardado SIN que nadie tenga que oprimir un botón.
--
-- Patrón igual al de conductores (sync_conductores_core): una función NÚCLEO sin
-- guard de rol (solo la corre pg_cron / postgres) + el job de cron. El botón por
-- fila (estado_sonar_en_vivo, sql/16) sigue existiendo para consulta puntual.
--
-- Solo LECTURA de SONAR (GET_DispatchedVehicles). No modifica SONAR.
-- ============================================================================

create or replace function public.refrescar_estados_sonar_core(p_fecha date default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
  v_url text; v_usr text; v_pwd text; v_ns text; v_sapps text; v_action text;
  v_union text; v_sql text; v_mids text[]; v_mid text;
  v_body text; v_resp text; v_xml xml; v_ini text; v_fin text;
  v_tot int := 0; v_mov int := 0; v_n int;
begin
  -- 1) UNION de (regId, vehiculo_id) de TODAS las tablas con columna sonar_regid,
  --    para el día pedido. Dinámico: si nace una tabla de puesto nueva, entra sola.
  select string_agg(
           format('select sonar_regid::bigint rid, vehiculo_id from public.%I '
                  || 'where sonar_regid is not null and fecha = %L', table_name, v_fecha),
           ' union all ')
    into v_union
  from information_schema.columns
  where table_schema = 'public' and column_name = 'sonar_regid';

  if v_union is null then
    return jsonb_build_object('ok', true, 'fecha', v_fecha, 'moviles', 0, 'viajes', 0, 'nota', 'sin tablas despachables');
  end if;

  -- 2) tracker_ids con al menos un viaje de la app HOY cuyo estado real FALTA
  --    (no está en despachos_sonar) o sigue "En progreso" (lrunning). Los ya
  --    cerrados (Completo/Incompleto/Cancelado) NO se vuelven a pedir → se limita solo.
  v_sql := format($f$
    select array_agg(distinct g.tracker_id)
    from ( %s ) a
    join public.vehiculos v      on v.id = a.vehiculo_id
    join public.vehiculosgps g   on g.movil = v.numero
    left join public.despachos_sonar ds on ds.itl_id = a.rid
    where coalesce(g.tracker_id, '') <> ''
      and (ds.itl_id is null or coalesce(ds.lrunning, false) = true)
  $f$, v_union);
  execute v_sql into v_mids;

  if v_mids is null or array_length(v_mids, 1) is null then
    return jsonb_build_object('ok', true, 'fecha', v_fecha, 'moviles', 0, 'viajes', 0);
  end if;

  -- 3) Credenciales del Vault + endpoint sapps.asmx (donde vive GET_DispatchedVehicles)
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  v_sapps  := rtrim(v_url, '/') || '/sapps.asmx';
  v_action := rtrim(v_ns, '/') || '/GET_DispatchedVehicles';
  v_ini := to_char(v_fecha, 'YYYY-MM-DD') || ' 00:00:00';        -- hora de Colombia
  v_fin := to_char(v_fecha + 1, 'YYYY-MM-DD') || ' 00:00:00';
  perform set_config('http.timeout_msec', '50000', true);

  -- 4) Una llamada por móvil (SONAR EXIGE el mId). Upsert de todos sus viajes del día.
  foreach v_mid in array v_mids loop
    v_body :=
      '<?xml version="1.0" encoding="utf-8"?>'
      || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      || '<GET_DispatchedVehicles xmlns="' || v_ns || '">'
      || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
      || '<fleetId>990</fleetId><mId>' || v_mid || '</mId>'
      || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
      || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
      || '</GET_DispatchedVehicles></soap:Body></soap:Envelope>';

    v_n := 0;
    begin
      select content into v_resp from extensions.http((
        'POST', v_sapps, array[extensions.http_header('SOAPAction', v_action)],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_xml := v_resp::xml;

      insert into public.despachos_sonar as d
        (itl_id, fecha, mid, movil, placa, ruta, conductor, hora_inicio, elapsed_seg,
         comentario, lclose, lrunning, lcanceled, lcanceledbyuser, sincronizado_en)
      select
        ((xpath('/x:ItDispatches/x:itlId/text()', n, array[array['x', v_ns]]))[1]::text)::bigint,
        v_fecha,
        (xpath('/x:ItDispatches/x:mId/text()',    n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:mDesc/text()',  n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:mPlaca/text()', n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:itDesc/text()', n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:drName/text()', n, array[array['x', v_ns]]))[1]::text,
        nullif((xpath('/x:ItDispatches/x:initTime/text()', n, array[array['x', v_ns]]))[1]::text, '')::time,
        nullif((xpath('/x:ItDispatches/x:elapsed/text()',  n, array[array['x', v_ns]]))[1]::text, '')::int,
        (xpath('/x:ItDispatches/x:comments/text()', n, array[array['x', v_ns]]))[1]::text,
        nullif((xpath('/x:ItDispatches/x:lclose/text()',          n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        nullif((xpath('/x:ItDispatches/x:lrunning/text()',        n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        nullif((xpath('/x:ItDispatches/x:lcanceled/text()',       n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        nullif((xpath('/x:ItDispatches/x:lcanceledbyuser/text()', n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        now()
      from unnest(xpath('//x:ItDispatches', v_xml, array[array['x', v_ns]])) as n
      on conflict (itl_id) do update set
        lclose = excluded.lclose, lrunning = excluded.lrunning,
        lcanceled = excluded.lcanceled, lcanceledbyuser = excluded.lcanceledbyuser,
        elapsed_seg = excluded.elapsed_seg, sincronizado_en = now();
      get diagnostics v_n = row_count;
    exception when others then
      v_n := 0;  -- un móvil que falle no puede tumbar el barrido
    end;
    v_tot := v_tot + v_n; v_mov := v_mov + 1;
  end loop;

  return jsonb_build_object('ok', true, 'fecha', v_fecha, 'moviles', v_mov, 'viajes', v_tot);
end $$;

-- Solo postgres / pg_cron la ejecutan (no la app). El botón por fila usa el otro RPC.
revoke all on function public.refrescar_estados_sonar_core(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Job de pg_cron: cada 10 minutos refresca los estados de los despachos de la app.
-- (idempotente: si ya existía con ese nombre, se reprograma)
-- ---------------------------------------------------------------------------
select cron.schedule('refrescar-estados-sonar', '*/10 * * * *',
                     'select public.refrescar_estados_sonar_core();');
