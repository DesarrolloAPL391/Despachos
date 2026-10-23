-- 135_gps_pegados.sql
-- "los GPS se quedan pegados... le hacen un cambio y no encuentran su id correcto ni posicion;
--  en SONAR sale una cosa y en la aplicacion otra" (22/10/2026).
--
-- CAUSA (medida, no supuesta): cuando a un bus le cambian el GPS, SONAR le da un mId NUEVO.
-- sql/31 ya hizo que sync_moviles borrara el mapeo viejo de `vehiculosgps`... pero NADIE borraba
-- la fila vieja de `ubicaciones`. Esa fila se queda con la ultima posicion que reporto el GPS
-- retirado y ya nunca se actualiza: el bus aparece DOS VECES en el mapa, uno vivo y uno muerto.
-- Por eso "en SONAR sale una cosa y en la app otra".
--
-- Encontrados hoy: 6 moviles duplicados (5030, 5522, 5526, 5579, 5620, 8151) y 1 GPS suelto
-- (EQS665, sin movil). El de 8151 estaba congelado desde el 2000-01-01 y el de 5030 desde junio.
--
-- ARREGLO: la regla es "si SONAR ya no conoce ese GPS, no se pinta en el mapa". sync_moviles
-- ya trae la lista completa de la flota; ahora, con la MISMA guardia que ya usaba (>100 moviles
-- en la respuesta, para no borrar por una respuesta parcial de SONAR), limpia tambien
-- `ubicaciones`. Asi no hay que acordarse de nada cuando vuelvan a cambiar un GPS.

create or replace function public.sync_moviles()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'vault'
as $function$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text; v_env text;
  v_resp extensions.http_response; v_doc xml; v_gps int; v_veh int;
  v_stale int := 0; v_ubic int := 0;
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

    -- Y LA POSICIÓN DE ESOS GPS (sql/135). Sin esto, el punto del GPS retirado se queda
    -- clavado en el mapa para siempre y el bus se ve en dos sitios a la vez.
    delete from ubicaciones u
    where not exists (select 1 from _ml m where nullif(trim(m.mid),'') = u.mid);
    get diagnostics v_ubic = row_count;
  end if;

  return jsonb_build_object('ok', true, 'moviles', (select count(*) from _ml),
    'vehiculosgps', v_gps, 'vehiculos', v_veh,
    'obsoletos_removidos', v_stale, 'ubicaciones_fantasma_removidas', v_ubic);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

-- ---------------------------------------------------------------------------
-- Vista de control para el admin: que no haya que descubrir esto de casualidad otra vez.
-- Dice que moviles estan duplicados, cuales llevan rato sin reportar y cuales tienen un GPS
-- que SONAR ya no conoce.
-- ---------------------------------------------------------------------------
create or replace function public.gps_salud()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case when not (select public.es_admin() or public.es_auditor())
              then jsonb_build_object('ok', false, 'error', 'Solo administracion.')
  else jsonb_build_object(
    'ok', true,
    'total', (select count(*) from public.ubicaciones),
    'frescos_15min', (select count(*) from public.ubicaciones where gps_gmt > now() - interval '15 minutes'),
    'pegados_2h',    (select count(*) from public.ubicaciones where gps_gmt <= now() - interval '2 hours'),
    'fantasmas',     (select count(*) from public.ubicaciones u
                       where not exists (select 1 from public.vehiculosgps v where v.tracker_id = u.mid)),
    'duplicados',    (select count(*) from (select movil from public.ubicaciones
                        where coalesce(movil,'') <> '' group by movil having count(*) > 1) t),
    'detalle', (select coalesce(jsonb_agg(jsonb_build_object(
                  'movil', u.movil, 'placa', u.placa, 'mid', u.mid,
                  'ultimo', to_char(u.gps_gmt at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI'),
                  'problema', case
                    when not exists (select 1 from public.vehiculosgps v where v.tracker_id = u.mid)
                      then 'GPS que SONAR ya no reconoce'
                    else 'sin reportar hace mas de 2 horas' end
                ) order by u.gps_gmt), '[]'::jsonb)
                  from public.ubicaciones u
                 where u.gps_gmt <= now() - interval '2 hours'
                    or not exists (select 1 from public.vehiculosgps v where v.tracker_id = u.mid)))
  end;
$function$;

revoke all on function public.gps_salud() from public, anon;
grant execute on function public.gps_salud() to authenticated;

-- Comprobacion (solo lectura; la limpieza se hace al correr sync_moviles)
select 'fantasmas AHORA (antes de sincronizar)' as dato,
       (select count(*)::text from public.ubicaciones u
         where not exists (select 1 from public.vehiculosgps v where v.tracker_id = u.mid)) as valor
union all
select 'moviles duplicados en el mapa',
       (select count(*)::text from (select movil from public.ubicaciones
          where coalesce(movil,'') <> '' group by movil having count(*) > 1) t)
union all
select 'sync_moviles ya limpia ubicaciones',
       case when position('ubicaciones_fantasma_removidas' in
                 pg_get_functiondef('public.sync_moviles()'::regprocedure)) > 0
            then 'si' else 'NO' end;
