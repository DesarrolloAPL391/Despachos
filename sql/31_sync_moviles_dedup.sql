-- ============================================================================
-- 31_sync_moviles_dedup.sql
-- FIX: cuando a un móvil le cambian el GPS, SONAR le asigna un mId NUEVO. El
-- sync anterior insertaba la fila nueva (on conflict tracker_id) pero DEJABA la
-- fila vieja apuntando al mismo móvil -> dos filas con el mismo `movil` y la app
-- podía despachar con el mId viejo (que SONAR ya no reconoce) -> errores.
-- Caso real: móvil 8189 pasó de AFKQ (viejo, ya no existe en SONAR) a A3VF.
--
-- Solución: tras el upsert, BORRAR de vehiculosgps las filas cuyo tracker YA NO
-- está en el reporte de SONAR, pero SOLO para móviles que sí vienen en el reporte
-- (protege ante respuestas parciales). vehiculosgps no tiene FKs -> borrar es seguro.
-- ============================================================================

create or replace function public.sync_moviles()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text; v_env text;
  v_resp extensions.http_response; v_doc xml; v_gps int; v_veh int; v_stale int := 0;
begin
  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  v_ns := coalesce(v_ns,'http://sonaravl.com/webservices/');
  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_MobileList';
  v_env := '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><GET_MobileList xmlns="'||v_ns||'">'
    ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password><FleetId>990</FleetId>'
    ||'</GET_MobileList></soap:Body></soap:Envelope>';
  select * into v_resp from extensions.http(('POST',v_url,array[extensions.http_header('SOAPAction','"'||v_action||'"')],'text/xml; charset=utf-8',v_env)::extensions.http_request);
  if v_resp.status <> 200 then return jsonb_build_object('ok',false,'error','SONAR HTTP '||v_resp.status); end if;
  v_doc := xmlparse(document v_resp.content);

  create temp table _ml on commit drop as
  select * from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:Mobile' passing v_doc
    columns
      mid    text path 'n:mId',
      movil  text path 'n:mDescription',
      placa  text path 'n:mPlaca',
      activo text path 'n:mActivo'
  );

  -- catálogo de vehículos (número + placa)
  with up as (
    insert into vehiculos(numero, placa)
    select distinct nullif(trim(movil),''), nullif(trim(placa),'')
    from _ml where nullif(trim(movil),'') is not null
    on conflict (numero) do update set placa = coalesce(excluded.placa, vehiculos.placa)
    returning 1
  ) select count(*) into v_veh from up;

  -- mapeo GPS (tracker = mId de SONAR)
  with up as (
    insert into vehiculosgps(tracker_id, movil, placa)
    select nullif(trim(mid),''), nullif(trim(movil),''), nullif(trim(placa),'')
    from _ml where nullif(trim(mid),'') is not null
    on conflict (tracker_id) do update set
      movil = excluded.movil, placa = coalesce(excluded.placa, vehiculosgps.placa)
    returning 1
  ) select count(*) into v_gps from up;

  -- LIMPIEZA de mapeos viejos: borra filas cuyo tracker ya no está en SONAR,
  -- solo para móviles que SÍ vienen en el reporte (evita borrar por respuesta parcial).
  if (select count(*) from _ml where nullif(trim(mid),'') is not null) > 100 then
    delete from vehiculosgps v
    where exists (select 1 from _ml m  where nullif(trim(m.movil),'') = v.movil)
      and not exists (select 1 from _ml m2 where nullif(trim(m2.mid),'') = v.tracker_id);
    get diagnostics v_stale = row_count;
  end if;

  return jsonb_build_object('ok', true, 'moviles', (select count(*) from _ml),
    'vehiculosgps', v_gps, 'vehiculos', v_veh, 'obsoletos_removidos', v_stale);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;
