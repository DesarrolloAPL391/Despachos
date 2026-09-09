-- ============================================================================
-- 65_sync_sonar_completo.sql  (v235)
-- Trae de SONAR los viajes de TODOS los móviles, no solo los despachados en la app.
--
-- Problema: la auditoría (despachos_sonar) solo traía viajes completos/incompletos
-- de los vehículos despachados DESDE LA APP, porque:
--   - el cron `refrescar-estados-sonar` (cada 10 min) solo consulta móviles con
--     `sonar_regid` (los despachados en la app);
--   - el barrido completo `sync_despachos_sonar` (todos los móviles) NUNCA se
--     automatizó y no tenía botón en la UI, así que nadie lo corría.
-- Medido 02–09/09: cada día aparecían ~210–225 móviles de 338 → faltaban ~110
-- móviles/día (los que se despachan directo en SONAR).
--
-- Fix: (1) núcleo sin guard de rol que barre TODOS los trackers de una fecha
-- (lo corre pg_cron), (2) `sync_despachos_sonar` (admin) reusa el núcleo para la
-- UI, (3) cron nocturno que barre el día anterior COMPLETO.
--
-- Solo LECTURA de SONAR (GET_DispatchedVehicles). No modifica SONAR.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) NÚCLEO: barre los móviles PENDIENTES de una fecha (los que aún no están en
--    despachos_sonar_sync). Sin guard de rol → solo lo corre pg_cron/postgres o
--    el wrapper admin. Va por lotes: si p_limite abarca todo, barre el día entero.
-- ---------------------------------------------------------------------------
create or replace function public.sync_despachos_sonar_core(p_fecha date, p_limite int default 500)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sapps text; v_action text;
  v_mid text; v_body text; v_resp text; v_xml xml;
  v_ini text; v_fin text;
  v_n int; v_tot int := 0; v_mov int := 0; v_pend int;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  v_sapps  := rtrim(v_url, '/') || '/sapps.asmx';
  v_action := rtrim(v_ns, '/') || '/GET_DispatchedVehicles';
  v_ini := to_char(p_fecha, 'YYYY-MM-DD') || ' 00:00:00';        -- hora de Colombia
  v_fin := to_char(p_fecha + 1, 'YYYY-MM-DD') || ' 00:00:00';

  -- timeout acotado por llamada: un móvil colgado no bloquea el barrido entero.
  perform set_config('http.timeout_msec', '25000', true);

  for v_mid in
    select distinct g.tracker_id
    from public.vehiculosgps g
    where coalesce(g.tracker_id, '') <> ''
      and not exists (select 1 from public.despachos_sonar_sync s
                      where s.fecha = p_fecha and s.mid = g.tracker_id)
    order by g.tracker_id
    limit greatest(p_limite, 1)
  loop
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
        p_fecha,
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
      v_n := 0;  -- un móvil que falle no puede tumbar el lote
    end;

    insert into public.despachos_sonar_sync (fecha, mid, viajes)
      values (p_fecha, v_mid, v_n)
      on conflict (fecha, mid) do update set viajes = excluded.viajes, sincronizado_en = now();
    v_tot := v_tot + v_n; v_mov := v_mov + 1;
  end loop;

  select count(*) into v_pend
    from public.vehiculosgps g
    where coalesce(g.tracker_id, '') <> ''
      and not exists (select 1 from public.despachos_sonar_sync s
                      where s.fecha = p_fecha and s.mid = g.tracker_id);

  return jsonb_build_object('ok', true, 'fecha', p_fecha, 'moviles', v_mov,
                            'viajes', v_tot, 'pendientes', v_pend);
end $$;

revoke all on function public.sync_despachos_sonar_core(date, int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) Wrapper admin para la UI: reusa el núcleo (una sola copia de la lógica SOAP).
-- ---------------------------------------------------------------------------
create or replace function public.sync_despachos_sonar(p_fecha date, p_limite int default 25)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador puede sincronizar.');
  end if;
  return public.sync_despachos_sonar_core(p_fecha, p_limite);
end $$;

revoke all on function public.sync_despachos_sonar(date, int) from public, anon;
grant execute on function public.sync_despachos_sonar(date, int) to authenticated;

-- ---------------------------------------------------------------------------
-- 2b) Reset del control de sync de una fecha: borra las marcas de despachos_sonar_sync
--     para que el barrido vuelva a consultar TODOS los móviles de ese día (útil para
--     el día de hoy, que sigue cambiando). Admin. No borra despachos_sonar (los viajes),
--     solo el control; el upsert refresca lo que cambió.
-- ---------------------------------------------------------------------------
create or replace function public.sync_despachos_sonar_reset(p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_n int;
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador puede sincronizar.');
  end if;
  delete from public.despachos_sonar_sync where fecha = p_fecha;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'fecha', p_fecha, 'reseteados', v_n);
end $$;

revoke all on function public.sync_despachos_sonar_reset(date) from public, anon;
grant execute on function public.sync_despachos_sonar_reset(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) Barrido nocturno del día ANTERIOR completo. Un solo call barre todos los
--    móviles pendientes (p_limite alto). Como se salta los ya sincronizados,
--    si se corta a medias, la siguiente corrida continúa.
-- ---------------------------------------------------------------------------
create or replace function public.sync_despachos_sonar_nocturno()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ayer date := (now() at time zone 'America/Bogota')::date - 1;
begin
  return public.sync_despachos_sonar_core(v_ayer, 500);
end $$;

revoke all on function public.sync_despachos_sonar_nocturno() from public, anon, authenticated;

-- Job de pg_cron: 06:10 UTC = 01:10 hora Colombia. El día ya cerró → auditoría 100%.
select cron.schedule('sync-sonar-nocturno', '10 6 * * *',
                     'select public.sync_despachos_sonar_nocturno();');
