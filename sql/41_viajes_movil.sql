-- 41: Viajes despachados del día de un móvil (desde SONAR) + pasajeros por viaje.
-- SONAR exige el itinerario para dar los viajes de un móvil (GET_ItinerariesHistory_v2
-- con mId SOLO devuelve "El usuario no puede consultar el historial..."). El itinerario del
-- móvil lo sabe la app en moviles_operacion (it_id, refrescado por cron); respaldo: por ruta.
--
-- Este RPC hace 2 llamadas SONAR (conteo de pasajeros + historial del itinerario) y cruza
-- cada subida/bajada (por su hora GPS) en la ventana [inicio, fin] de cada viaje. Va SEPARADO
-- de pasajeros_movil y el cliente los llama en paralelo, para que cada uno tenga su presupuesto
-- de 8 s. Solo admin.

create or replace function public.viajes_movil(p_movil text, p_fecha date)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $$
declare
  v_user text; v_pass text; v_url text; v_ns text;
  v_mid text; v_itid bigint; v_ruta text; v_ini text; v_fin text;
  v_resp extensions.http_response; v_resp2 extensions.http_response;
  v_viajes jsonb; v_tot_sub int := 0; v_tot_baj int := 0; v_asig_sub int := 0; v_asig_baj int := 0;
  v_cands bigint[]; v_c bigint; v_t0 timestamptz;
begin
  if not (public.es_admin() or (public.es_afiliado() and trim(p_movil) = any(public.mis_moviles_afiliado()))) then
    raise exception 'No autorizado para consultar este móvil.'; end if;
  if nullif(trim(p_movil),'') is null then return jsonb_build_object('ok', false, 'error', 'Móvil vacío.'); end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Fecha vacía.'); end if;

  select tracker_id into v_mid from public.vehiculosgps where movil = trim(p_movil) limit 1;
  if v_mid is null then return jsonb_build_object('ok', false, 'error', 'El móvil '||trim(p_movil)||' no tiene Id GPS en SONAR.'); end if;

  -- Ruta/itinerario del móvil: primero lo que la app ya conoce (moviles_operacion), luego por ruta del parque.
  select it_id, ruta into v_itid, v_ruta
    from public.moviles_operacion where mid = v_mid and it_id is not null
    order by prog_actualizado desc nulls last limit 1;
  if v_ruta is null then
    select ir.ruta, ir.it_id into v_ruta, v_itid
      from public.parque_automotor pa
      join public.itinerario_rutas ir on position(lower(ir.ruta) in lower(coalesce(pa.ruta,''))) > 0
      where pa.numero_interno = trim(p_movil)
      order by length(ir.ruta) desc limit 1;
  end if;
  if v_ruta is null and v_itid is null then
    return jsonb_build_object('ok', true, 'movil', trim(p_movil), 'fecha', p_fecha,
      'viajes', '[]'::jsonb, 'nota', 'No se conoce el itinerario de este móvil (no está operando ni tiene ruta mapeada).');
  end if;

  -- Un móvil suele alternar itinerarios de su ruta (ej. "134" ida y "134Y" vuelta). Candidatos =
  -- itinerarios cuyo NOMBRE EXACTO sea uno de los tokens de la ruta del parque ("134-134Y" -> 134, 134Y),
  -- de la ruta de moviles_operacion, o el número base; más el it_id ya conocido. Tope 4.
  select array_agg(distinct ir.it_id) into v_cands
  from public.itinerario_rutas ir
  where lower(trim(ir.ruta)) = any (
    select distinct lower(trim(tok)) from (
      select unnest(regexp_split_to_array(
        coalesce((select ruta from public.parque_automotor where numero_interno = trim(p_movil) limit 1), ''),
        '[^0-9A-Za-z]+')) tok
      union all select v_ruta
      union all select substring(coalesce(v_ruta, '') from '^\d+')
    ) t where nullif(trim(tok), '') is not null
  )
  or ir.it_id = v_itid;
  if array_length(v_cands,1) is null then v_cands := array[v_itid]; end if;
  if array_length(v_cands,1) > 4 then v_cands := v_cands[1:4]; end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');

  v_ini := to_char(p_fecha::timestamp + interval '5 hours', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(p_fecha::timestamp + interval '1 day 5 hours' - interval '1 second', 'YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec','3500',true);

  -- 1) Conteo de pasajeros (para cruzar por viaje) -> _dd (din, dout, hora UTC)
  select * into v_resp from extensions.http((
    'POST', rtrim(v_url,'/')||'/',
    array[extensions.http_header('SOAPAction', rtrim(v_ns,'/')||'/ServiceSoap/GET_PassengersCounter')],
    'text/xml; charset=utf-8',
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    ||'<GET_PassengersCounter xmlns="'||v_ns||'"><User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
    ||'<mId>'||public._xmlesc(v_mid)||'</mId>'
    ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    ||'</GET_PassengersCounter></soap:Body></soap:Envelope>'
  )::extensions.http_request);
  create temp table _dd on commit drop as
  select coalesce(din,0) din, coalesce(dout,0) dout, to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') ts_utc
  from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing xmlparse(document v_resp.content)
    columns din int path 'n:DoorIn', dout int path 'n:DoorOut', gps text path '../../n:gps_UTC');
  select coalesce(sum(din),0), coalesce(sum(dout),0) into v_tot_sub, v_tot_baj from _dd;

  -- 2) Historial de CADA itinerario candidato (best-effort, con tope de tiempo) -> _trips
  create temp table _trips (regid text, ruta text, ini_ts timestamptz, fin_ts timestamptz,
                            corriendo bool, cerrado bool, cancelado bool) on commit drop;
  perform set_config('http.timeout_msec','2200',true);
  v_t0 := clock_timestamp();
  foreach v_c in array v_cands loop
    exit when extract(epoch from (clock_timestamp() - v_t0)) > 4.5;  -- no arriesgar el statement_timeout de 8s
    begin
      select * into v_resp2 from extensions.http((
        'POST', rtrim(v_url,'/')||'/',
        array[extensions.http_header('SOAPAction', rtrim(v_ns,'/')||'/ServiceSoap/GET_ItinerariesHistory_v2')],
        'text/xml; charset=utf-8',
        '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
        ||'<GET_ItinerariesHistory_v2 xmlns="'||v_ns||'"><User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
        ||'<mId>'||public._xmlesc(v_mid)||'</mId><Itinerary>'||v_c||'</Itinerary>'
        ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
        ||'</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>'
      )::extensions.http_request);
      if v_resp2.status = 200 then
        insert into _trips (regid, ruta, ini_ts, fin_ts, corriendo, cerrado, cancelado)
        select regid, (select ir.ruta from public.itinerario_rutas ir where ir.it_id = v_c limit 1),
               public._utc_ts(ini), public._utc_ts(fin), (run='Y'), (cls='Y'), (can='Y')
        from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n),
          '//n:ItLog' passing xmlparse(document v_resp2.content)
          columns regid text path 'n:regId', ini text path 'n:inittime', fin text path 'n:endtime',
            run text path 'n:running', cls text path 'n:close', can text path 'n:canceled')
        where public._utc_ts(ini) is not null;
      end if;
    exception when others then null;  -- un itinerario que falle no descarta los demás
    end;
  end loop;

  -- 3) Cruce: subidas/bajadas dentro de la ventana [inicio, fin] de cada viaje.
  --    Estado segun la regla OFICIAL de SONAR (memoria despachos-regla-estados): lo que separa
  --    "Cancelado" de "Incompleto" es si el viaje CERRO. Un viaje cerrado y ademas marcado como
  --    cancelado SI corrio y SI movilizo pasajeros -> es "Incompleto" (no "Cancelado"). Solo los
  --    "Cancelado" (marcado y sin cerrar) llevan 0 pasajeros.
  select jsonb_agg(x order by (x->>'ini_ord'))
    into v_viajes
    from (
      select jsonb_build_object(
        'reg', t.regid,
        'ruta', coalesce(t.ruta, v_ruta),
        'ini', to_char(t.ini_ts at time zone 'America/Bogota','HH24:MI'),
        'fin', case when t.fin_ts is not null then to_char(t.fin_ts at time zone 'America/Bogota','HH24:MI') else null end,
        'ini_ord', to_char(t.ini_ts,'YYYY-MM-DD HH24:MI:SS'),
        'dur_min', case when t.fin_ts is not null and t.fin_ts > t.ini_ts
                        then round(extract(epoch from (t.fin_ts - t.ini_ts))/60.0)::int else null end,
        'estado', est.estado,
        'subidas', case when est.estado = 'Cancelado' then 0 else coalesce(pax.s,0) end,
        'bajadas', case when est.estado = 'Cancelado' then 0 else coalesce(pax.b,0) end,
        -- Desglose de pasajeros del viaje en franjas de 15 min (para el detalle al hacer clic)
        'franjas', case when est.estado = 'Cancelado' then '[]'::jsonb else coalesce(fr.j,'[]'::jsonb) end
      ) x
      from _trips t
      cross join lateral (select case
          when t.corriendo            then 'En curso'
          when t.cerrado and t.cancelado then 'Incompleto'
          when t.cerrado              then 'Completo'
          when t.cancelado            then 'Cancelado'
          else 'Incompleto' end as estado) est
      cross join lateral (
        select coalesce(sum(d.din),0) s, coalesce(sum(d.dout),0) b
        from _dd d where d.ts_utc >= t.ini_ts and d.ts_utc <= coalesce(t.fin_ts, now())
      ) pax
      cross join lateral (
        select jsonb_agg(jsonb_build_object(
                 't', to_char(g.bucket at time zone 'America/Bogota','HH24:MI'),
                 's', g.s, 'b', g.b) order by g.bucket) j
        from (
          select date_trunc('hour', d.ts_utc)
                   + floor(extract(minute from d.ts_utc)/15) * interval '15 min' as bucket,
                 sum(d.din) s, sum(d.dout) b
          from _dd d
          where d.ts_utc >= t.ini_ts and d.ts_utc <= coalesce(t.fin_ts, now())
          group by 1
        ) g
      ) fr
    ) q;

  select coalesce(sum((x->>'subidas')::int),0), coalesce(sum((x->>'bajadas')::int),0)
    into v_asig_sub, v_asig_baj
    from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x;

  return jsonb_build_object(
    'ok', true, 'movil', trim(p_movil), 'fecha', p_fecha, 'ruta', v_ruta, 'itid', v_itid,
    'viajes', coalesce(v_viajes,'[]'::jsonb),
    'n_viajes',      coalesce(jsonb_array_length(v_viajes), 0),
    'n_completos',   (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'Completo'),
    'n_incompletos', (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'Incompleto'),
    'n_cancelados',  (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'Cancelado'),
    'n_encurso',     (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'En curso'),
    'total_subidas', v_tot_sub, 'total_bajadas', v_tot_baj,
    'sin_viaje_subidas', greatest(v_tot_sub - v_asig_sub, 0),
    'sin_viaje_bajadas', greatest(v_tot_baj - v_asig_baj, 0)
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

grant execute on function public.viajes_movil(text, date) to authenticated;
