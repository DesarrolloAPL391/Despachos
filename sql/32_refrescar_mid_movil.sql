-- ============================================================================
-- 32_refrescar_mid_movil.sql
-- AUTO-SANACIÓN del mId en el momento del despacho.
--
-- Cuando a un móvil le cambian el GPS, SONAR le asigna un mId NUEVO y el despacho
-- con el mId viejo FALLA. En vez de esperar al sync nocturno o al botón manual, la
-- app llama a esta función al detectar el fallo: refresca desde SONAR el mId real de
-- ESE móvil (GET_MobileList, flota 990), corrige `vehiculosgps` y limpia el mId viejo.
-- Luego el cliente reintenta el despacho UNA vez con el mId nuevo (seguro: antes de
-- reintentar ya se verificó con GET_ItinerariesHistory que el viaje NO se creó).
--
-- Es la versión PUNTUAL de sync_moviles() (una sola móvil) para que quepa dentro del
-- statement_timeout=8s del rol authenticated: http.timeout_msec=6500 (como despachar_sonar).
-- vehiculosgps no tiene FKs -> borrar el mapeo viejo es seguro.
-- ============================================================================

create or replace function public.refrescar_mid_movil(p_movil text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text; v_env text;
  v_resp extensions.http_response; v_doc xml; v_mid text; v_placa text; v_stale int := 0;
begin
  if nullif(trim(p_movil),'') is null then
    return jsonb_build_object('ok', false, 'error', 'móvil vacío');
  end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_MobileList';

  v_env := '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><GET_MobileList xmlns="'||v_ns||'">'
    ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password><FleetId>990</FleetId>'
    ||'</GET_MobileList></soap:Body></soap:Envelope>';

  -- 6.5s: por debajo del statement_timeout=8s del rol authenticated (igual que despachar_sonar)
  perform set_config('http.timeout_msec','6500',true);

  select * into v_resp from extensions.http((
    'POST', v_url,
    array[extensions.http_header('SOAPAction','"'||v_action||'"')],
    'text/xml; charset=utf-8', v_env
  )::extensions.http_request);
  if v_resp.status <> 200 then
    return jsonb_build_object('ok', false, 'error', 'SONAR HTTP '||v_resp.status);
  end if;
  v_doc := xmlparse(document v_resp.content);

  -- mId actual de ESTE móvil (mDescription == p_movil)
  select nullif(trim(mid),''), nullif(trim(placa),'')
    into v_mid, v_placa
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:Mobile' passing v_doc
    columns
      mid    text path 'n:mId',
      movil  text path 'n:mDescription',
      placa  text path 'n:mPlaca'
  )
  where nullif(trim(movil),'') = trim(p_movil)
  limit 1;

  if v_mid is null then
    return jsonb_build_object('ok', false, 'error', 'móvil no está en SONAR', 'movil', trim(p_movil));
  end if;

  -- corrige el mapeo del móvil (mId nuevo)
  insert into vehiculosgps(tracker_id, movil, placa)
  values (v_mid, trim(p_movil), v_placa)
  on conflict (tracker_id) do update
    set movil = excluded.movil, placa = coalesce(excluded.placa, vehiculosgps.placa);

  -- borra los mapeos VIEJOS de este móvil (mId que SONAR ya no reporta)
  delete from vehiculosgps where movil = trim(p_movil) and tracker_id <> v_mid;
  get diagnostics v_stale = row_count;

  return jsonb_build_object('ok', true, 'movil', trim(p_movil), 'mid', v_mid, 'obsoletos_removidos', v_stale);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

grant execute on function public.refrescar_mid_movil(text) to authenticated;
