-- 158: Seguridad vial también usa el visor 🔎 Eventos del bus (en vivo desde SONAR).
--
-- Segundo paso de sql/157. El visor muestra, para un bus y un rango de horas, los excesos de
-- velocidad contra el límite de la vía, las puertas abiertas en marcha y los pasos por geocerca,
-- y dice quién iba al volante. También se abre desde la ficha del siniestro ("Eventos del bus ese
-- día"). Hasta ahora era solo de admin, auditores y el afiliado con sus carros.
--
-- Lo que necesita seguridad vial, y nada más:
--   * sonar_eventos_auditor: la puerta suma es_seguridad_vial() (cualquier móvil, como el auditor).
--     La función de abajo es copia exacta de la que hay en la base (04/11/2026), salvo la puerta.
--   * despachos_sonar: LEER los viajes reales, que es de donde sale el conductor del evento.
-- El Id GPS del bus sale de vehiculosgps, que ya lee cualquier cuenta, así que NO se abren las
-- posiciones en vivo de la flota (ubicaciones): la app arma la lista de buses desde vehiculosgps.

drop policy if exists dsonar_vial_sel on public.despachos_sonar;
create policy dsonar_vial_sel on public.despachos_sonar for select to authenticated
  using ((select public.es_seguridad_vial()));

CREATE OR REPLACE FUNCTION public.sonar_eventos_auditor(p_mid text, p_desde text, p_hasta text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sa text;
  v_body text; v_resp text; v_xml xml;
  v_ini text; v_fin text;
  v_status text;
  v_items jsonb;
begin
  -- Puerta: auditoría (velocidad, puertas, geocercas). Admin, auditor y seguridad vial (sql/158)
  -- ven cualquier móvil; el afiliado SOLO puede consultar un mid que sea de uno de SUS vehículos.
  if not (public.es_auditor() or public.es_admin() or public.es_seguridad_vial() or (
        public.es_afiliado() and exists (
          select 1 from public.ubicaciones u
          join public.vehiculos v on v.numero = u.movil
          where u.mid = p_mid and v.id = any(public.mis_vehiculo_ids_afiliado())))) then
    return jsonb_build_object('ok', false, 'error',
      case when public.es_afiliado() then 'Ese móvil no es uno de tus vehículos.'
           else 'Solo los auditores y seguridad vial pueden consultar los eventos del bus.' end);
  end if;
  if coalesce(p_mid, '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Ese móvil no tiene Id GPS en SONAR.');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  select regexp_replace(decrypted_secret, '/[^/]+$', '') into v_sa
    from vault.decrypted_secrets where name = 'SONAR_SOAPACTION';

  -- SONAR pide el rango en UTC; aquí se recibe en hora de Colombia.
  v_ini := to_char((p_desde::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char((p_hasta::timestamp at time zone 'America/Bogota') at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS');

  v_body :=
    '<?xml version="1.0" encoding="utf-8"?>'
    || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    || '<GET_TrackerEventsHistoryV2 xmlns="' || v_ns || '">'
    || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
    || '<mId>' || p_mid || '</mId><eventID></eventID>'
    || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
    || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
    || '</GET_TrackerEventsHistoryV2></soap:Body></soap:Envelope>';

  perform set_config('http.timeout_msec', '55000', true); -- el V2 tarda más que el V1

  begin
    select content into v_resp from extensions.http((
      'POST', v_url,
      array[extensions.http_header('SOAPAction', v_sa || '/GET_TrackerEventsHistoryV2')],
      'text/xml; charset=utf-8', v_body)::extensions.http_request);
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'SONAR no respondió: ' || sqlerrm);
  end;

  v_xml := v_resp::xml;
  v_status := (xpath('//x:status/text()', v_xml, array[array['x', v_ns]]))[1]::text;
  if coalesce(v_status, '') <> 'OK' then
    return jsonb_build_object('ok', false, 'error',
      coalesce((xpath('//x:description/text()', v_xml, array[array['x', v_ns]]))[1]::text, 'SONAR respondió ' || coalesce(v_status, '?')));
  end if;

  -- Un objeto por evento. La hora se devuelve YA en hora de Colombia.
  select coalesce(jsonb_agg(e order by e->>'hora'), '[]'::jsonb) into v_items
  from (
    select jsonb_build_object(
      'hora',      to_char(((xpath('/x:TrackerEventV2/x:GpsGMT/text()', n, array[array['x', v_ns]]))[1]::text)::timestamp
                            at time zone 'UTC' at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI:SS'),
      'evento',    (xpath('/x:TrackerEventV2/x:eventDescription/text()', n, array[array['x', v_ns]]))[1]::text,
      'direccion', (xpath('/x:TrackerEventV2/x:Address/text()', n, array[array['x', v_ns]]))[1]::text,
      'velocidad', nullif((xpath('/x:TrackerEventV2/x:Speed/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'limite',    nullif((xpath('/x:TrackerEventV2/x:RoadSpeed/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'lat',       nullif((xpath('/x:TrackerEventV2/x:Latitude/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'lon',       nullif((xpath('/x:TrackerEventV2/x:Longitude/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric,
      'odometro',  nullif((xpath('/x:TrackerEventV2/x:Odometer/text()', n, array[array['x', v_ns]]))[1]::text, '')::numeric
    ) as e
    from unnest(xpath('//x:TrackerEventV2', v_xml, array[array['x', v_ns]])) as n
  ) s;

  return jsonb_build_object('ok', true, 'items', v_items);
end $function$;
