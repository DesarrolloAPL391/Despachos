-- ===================================================================================
-- 123: `sonar_recorrido` ESTABA ABIERTA A INTERNET
-- ===================================================================================
-- QUE SE ENCONTRO (13/10/2026, revisando quien puede ver los recorridos):
--
--     sonar_recorrido       -> PUBLIC, authenticated, postgres, service_role
--     sonar_eventos_auditor -> authenticated, postgres, service_role
--     recorrido_bus         -> authenticated, postgres, service_role
--
-- `PUBLIC` incluye a `anon`. Y la funcion no comprobaba NADA por dentro: ni sesion, ni
-- rol, ni que el vehiculo fuera de quien pregunta. Solo que el mId no viniera vacio.
-- Como la llave anonima esta -por diseno- a la vista en el JavaScript del sitio,
-- cualquier persona en internet podia pedir el recorrido GPS completo de cualquier bus
-- de la flota sin tener cuenta.
--
-- No era un hallazgo nuevo: sql/13 lo dejo anotado al margen ("Ojo: `sonar_recorrido`
-- quedo ejecutable por anon; esta NO") y nunca se cerro.
--
-- QUE SE HACE:
--   1) Se le quita el permiso a `public`/`anon`: solo usuarios con sesion.
--   2) Se le agrega la puerta que le faltaba, con la MISMA regla del mapa.
--
-- POR QUE ESA REGLA Y NO UNA LISTA DE ROLES: la politica `ubicaciones_select` (sql/43)
-- ya decide quien ve cada movil en el mapa, y el boton de recorrido vive justamente en
-- la ficha del movil del mapa. Reusarla deja las dos cosas diciendo lo mismo y evita
-- que manana se separen. Nadie gana ni pierde alcance respecto de lo que ya veia.
--
-- NO SE TOCA UNA SOLA LINEA DE LA LOGICA: el cuerpo es el que estaba en produccion,
-- traido con pg_get_functiondef; lo unico que se agrega es el bloque de la puerta.
-- ===================================================================================

CREATE OR REPLACE FUNCTION public.sonar_recorrido(p_mid text, p_desde text, p_hasta text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare v_user text; v_pass text; v_url text; v_ns text; v_resp extensions.http_response; v_doc xml;
  v_ini text; v_fin text;
begin
  -- ---- PUERTA DE ACCESO (sql/123) ----------------------------------------------
  -- Antes esta funcion la podia llamar CUALQUIERA desde internet: tenia permiso para
  -- `public` (que incluye a `anon`) y no comprobaba nada. Con la llave anonima, que
  -- esta a la vista en el JavaScript del sitio, bastaba con acertar un mId para sacar
  -- el recorrido GPS de cualquier bus sin tener cuenta.
  --
  -- La regla que se aplica es LA MISMA del mapa (politica `ubicaciones_select`,
  -- sql/43): se puede ver el recorrido de un movil exactamente cuando se puede ver
  -- ese movil en el mapa. Asi nadie gana ni pierde alcance: el admin sigue viendo
  -- toda la flota, el auditor y el despachador los moviles de sus rutas, y el
  -- afiliado solo los suyos.
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'No autenticado.');
  end if;
  -- El admin pasa derecho, sin exigir que el movil este en `ubicaciones`: un equipo que
  -- todavia no ha reportado GPS no figura en esa tabla, y no tendria sentido que eso le
  -- impidiera al administrador consultar su historial.
  if not ( (select public.es_admin()) or exists (
    select 1 from public.ubicaciones u
     where u.mid = p_mid
       and ( lower(btrim(coalesce(u.ruta, ''))) = any (public.mis_ruta_nombres())
          or ((select public.es_afiliado()) and btrim(u.movil) = any (public.mis_moviles_afiliado())) )
  ) ) then
    return jsonb_build_object('ok', false, 'error',
      'Ese movil no esta entre los que puedes consultar.');
  end if;
  -- -------------------------------------------------------------------------------

  if p_mid is null or btrim(p_mid)='' then return jsonb_build_object('ok',false,'error','mId vacio'); end if;
  -- hora local Bogota (UTC-5) -> UTC para SONAR
  v_ini := to_char((p_desde::timestamp + interval '5 hours'),'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char((p_hasta::timestamp + interval '5 hours'),'YYYY-MM-DD HH24:MI:SS');
  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  v_ns := coalesce(v_ns,'http://sonaravl.com/webservices/');
  select * into v_resp from extensions.http(('POST',v_url,
    array[extensions.http_header('SOAPAction','"'||rtrim(v_ns,'/')||'/ServiceSoap/GET_TrackerEventsHistory"')],
    'text/xml; charset=utf-8',
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><GET_TrackerEventsHistory xmlns="'||v_ns||'">'
    ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password><mId>'||public._xmlesc(p_mid)||'</mId><eventID></eventID>'
    ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    ||'</GET_TrackerEventsHistory></soap:Body></soap:Envelope>')::extensions.http_request);
  if v_resp.status <> 200 then return jsonb_build_object('ok',false,'error','SONAR HTTP '||v_resp.status); end if;
  v_doc := xmlparse(document v_resp.content);
  return jsonb_build_object('ok',true,'mid',p_mid,'puntos',
    coalesce((select jsonb_agg(jsonb_build_object(
        'lat',lat,'lon',lon,'t',to_char((g::timestamp - interval '5 hours'),'HH24:MI'),
        'vel',vel,'dir',dir,'desc',des) order by g)
      from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n),
        '//n:TrackerEvent' passing v_doc
        columns lat float path 'n:Latitude', lon float path 'n:Longitude',
          g text path 'n:GpsGMT', vel int path 'n:Speed',
          dir text path 'n:Address', des text path 'n:eventDescription')
      where lat is not null and lon is not null and not (lat=0 and lon=0)),'[]'::jsonb));
exception when others then return jsonb_build_object('ok',false,'error',SQLERRM);
end $function$;

-- Que no la pueda disparar cualquiera desde internet: solo usuarios con sesion,
-- y por dentro la funcion ya exige poder ver ese movil.
revoke all on function public.sonar_recorrido(text, text, text) from public, anon;
grant execute on function public.sonar_recorrido(text, text, text) to authenticated;

-- ===================================================================================
-- PARA VERIFICAR (las tres deben quedar sin PUBLIC y validando por dentro):
--   select p.proname,
--          (select string_agg(distinct g.grantee, ', ' order by g.grantee)
--             from information_schema.routine_privileges g
--            where g.specific_name = p.proname||'_'||p.oid
--              and g.privilege_type = 'EXECUTE') as puede_ejecutar
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('sonar_recorrido','sonar_eventos_auditor','recorrido_bus')
--    order by 1;
--
-- Y que la pantalla siga funcionando: abrir el mapa, tocar un bus y darle
-- "Recorrido". Debe responder igual que antes.
-- ===================================================================================
