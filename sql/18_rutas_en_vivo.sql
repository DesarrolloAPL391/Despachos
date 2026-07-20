-- ============================================================================
-- 18_rutas_en_vivo.sql  (v154)
-- Semáforo de rutas EN VIVO: qué rutas tienen bus rodando AHORA y cuántos.
--
-- Una sola llamada SOAP a GET_MobileOperationInfo (servicio principal, flota 990)
-- devuelve TODOS los móviles con su itinerario actual (itId/itDescription). Los
-- agrupamos por ruta: es la fuente de verdad que GET_hasItineraryMobilesActive
-- consulta (verificado: el booleano de ese método coincide 1 a 1 con esto), pero
-- en UNA llamada da el semáforo de todas las rutas + cuántos y cuáles móviles.
--
-- itDescription de SONAR == nombre de ruta de la app (130, 132i, 135, 190, ...).
-- Reutiliza el mismo patrón de vault + extensions.http de 16_estado_sonar_en_vivo.sql.
-- OJO: el servicio principal usa SOAPAction .../ServiceSoap/<Metodo> (con /ServiceSoap/),
-- distinto del endpoint sapps.asmx.
-- ============================================================================

create or replace function public.rutas_en_vivo()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'No autenticado.');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  -- El servicio principal (no sapps.asmx) exige el segmento /ServiceSoap/ en el SOAPAction.
  v_action := rtrim(v_ns, '/') || '/ServiceSoap/GET_MobileOperationInfo';
  perform set_config('http.timeout_msec', '50000', true);

  v_body :=
    '<?xml version="1.0" encoding="utf-8"?>'
    || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_MobileOperationInfo xmlns="' || v_ns || '">'
    || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
    || '</GET_MobileOperationInfo></soap:Body></soap:Envelope>';

  begin
    select content into v_resp from extensions.http((
      'POST', rtrim(v_url, '/') || '/', array[extensions.http_header('SOAPAction', v_action)],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
    v_xml := v_resp::xml;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'No se pudo consultar SONAR.');
  end;

  return (
    with m as (
      select
        (xpath('/x:MobileOperationInfo/x:description/text()',   n, array[array['x', v_ns]]))[1]::text as movil,
        (xpath('/x:MobileOperationInfo/x:plate/text()',         n, array[array['x', v_ns]]))[1]::text as placa,
        (xpath('/x:MobileOperationInfo/x:driverName/text()',    n, array[array['x', v_ns]]))[1]::text as conductor,
        nullif((xpath('/x:MobileOperationInfo/x:itId/text()',   n, array[array['x', v_ns]]))[1]::text, '')::bigint as it_id,
        (xpath('/x:MobileOperationInfo/x:itDescription/text()', n, array[array['x', v_ns]]))[1]::text as ruta,
        (xpath('/x:MobileOperationInfo/x:itInittime/text()',    n, array[array['x', v_ns]]))[1]::text as inicio
      from unnest(xpath('//x:MobileOperationInfo', v_xml, array[array['x', v_ns]])) as n
    )
    select jsonb_build_object(
      'ok', true,
      'hora', to_char(now() at time zone 'America/Bogota', 'HH24:MI:SS'),
      'total', (select count(*) from m),
      'en_ruta', (select count(*) from m where coalesce(it_id, 0) <> 0),
      'libres', (select count(*) from m where coalesce(it_id, 0) = 0),
      'rutas', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'it_id', it_id, 'ruta', ruta, 'n', n, 'moviles', moviles) order by ruta)
        from (
          select it_id, ruta, count(*) as n,
                 jsonb_agg(jsonb_build_object('movil', movil, 'placa', placa, 'conductor', conductor)
                           order by movil) as moviles
          from m
          where coalesce(it_id, 0) <> 0
          group by it_id, ruta
        ) g), '[]'::jsonb)
    )
  );
end $fn$;

revoke all on function public.rutas_en_vivo() from public, anon;
grant execute on function public.rutas_en_vivo() to authenticated;

-- limpia la función de prueba
drop function if exists public._probe_rutas_vivo();
