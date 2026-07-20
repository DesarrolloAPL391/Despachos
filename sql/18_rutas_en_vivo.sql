-- ============================================================================
-- 18_rutas_en_vivo.sql  (v154 / v155)
-- Semáforo de rutas EN VIVO: qué rutas tienen bus rodando AHORA y cuántos.
--
-- GET_MobileOperationInfo (flota 990) devuelve TODOS los móviles con su itinerario
-- actual. itDescription de SONAR == nombre de ruta de la app (130, 132i, 135, 190...).
--
-- OJO DE RENDIMIENTO: esa llamada SOAP tarda ~17 s (SONAR procesa 338 móviles). El rol
-- `authenticated` tiene statement_timeout=8s, así que el cliente NO puede llamarla en
-- vivo. Patrón (igual a 17_refrescar_estados_sonar): un pg_cron refresca un CACHÉ cada
-- minuto (corre como postgres, sin tope) y el cliente lee el caché al instante.
--
-- El servicio principal (ServiceSoap) exige el segmento /ServiceSoap/ en el SOAPAction,
-- distinto del endpoint sapps.asmx. Namespace de elementos = SONAR_NAMESPACE del vault.
-- ============================================================================

-- 1) Caché: último snapshot de la operación de la flota (una fila por móvil).
create table if not exists public.moviles_operacion (
  mid         text primary key,
  movil       text,
  placa       text,
  conductor   text,
  it_id       bigint,
  ruta        text,
  inicio      timestamptz,   -- itInittime: cuándo arrancó la ruta (SONAR lo da en UTC)
  ultimo_gps  timestamptz,   -- lastGPSDate: último reporte GPS (UTC)
  lat         double precision,
  lon         double precision,
  actualizado timestamptz not null default now()
);
-- columnas nuevas si la tabla ya existía de una versión anterior
alter table public.moviles_operacion add column if not exists inicio     timestamptz;
alter table public.moviles_operacion add column if not exists ultimo_gps timestamptz;
alter table public.moviles_operacion enable row level security;  -- sin políticas: solo vía SECURITY DEFINER

-- Convierte un texto de fecha de SONAR (UTC) a timestamptz. SONAR a veces manda
-- "0000-00-00 00:00:00" (placeholder nulo) que NO es fecha válida → devuelve null.
create or replace function public._utc_ts(t text)
returns timestamptz language sql immutable set search_path = public as $$
  select case when $1 ~ '^(19|20)[0-9][0-9]-' then ($1::timestamp at time zone 'UTC') else null end
$$;

-- 2) NÚCLEO (sin guard de rol; solo lo corre pg_cron/postgres): llama SONAR y refresca el caché.
create or replace function public.refrescar_moviles_operacion_core()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_ts timestamptz := now(); v_n int := 0;
begin
  -- evita que dos corridas se solapen si SONAR se demora (el lock se suelta al terminar la txn)
  if not pg_try_advisory_xact_lock(724001) then
    return jsonb_build_object('ok', true, 'nota', 'otra corrida en curso');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

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

  -- upsert de todos los móviles reportados; los que ya no aparecen se borran (actualizado viejo)
  with parsed as (
    select
      (xpath('/x:MobileOperationInfo/x:mId/text()',           n, array[array['x', v_ns]]))[1]::text as mid,
      (xpath('/x:MobileOperationInfo/x:description/text()',   n, array[array['x', v_ns]]))[1]::text as movil,
      (xpath('/x:MobileOperationInfo/x:plate/text()',         n, array[array['x', v_ns]]))[1]::text as placa,
      (xpath('/x:MobileOperationInfo/x:driverName/text()',    n, array[array['x', v_ns]]))[1]::text as conductor,
      nullif((xpath('/x:MobileOperationInfo/x:itId/text()',   n, array[array['x', v_ns]]))[1]::text, '')::bigint as it_id,
      (xpath('/x:MobileOperationInfo/x:itDescription/text()', n, array[array['x', v_ns]]))[1]::text as ruta,
      -- SONAR entrega itInittime y lastGPSDate en UTC → guardar como timestamptz UTC (ignora "0000-..." )
      public._utc_ts((xpath('/x:MobileOperationInfo/x:itInittime/text()',  n, array[array['x', v_ns]]))[1]::text) as inicio,
      public._utc_ts((xpath('/x:MobileOperationInfo/x:lastGPSDate/text()', n, array[array['x', v_ns]]))[1]::text) as ultimo_gps,
      nullif((xpath('/x:MobileOperationInfo/x:latitude/text()',  n, array[array['x', v_ns]]))[1]::text, '')::double precision as lat,
      nullif((xpath('/x:MobileOperationInfo/x:longitude/text()', n, array[array['x', v_ns]]))[1]::text, '')::double precision as lon
    from unnest(xpath('//x:MobileOperationInfo', v_xml, array[array['x', v_ns]])) as n
  )
  insert into public.moviles_operacion (mid, movil, placa, conductor, it_id, ruta, inicio, ultimo_gps, lat, lon, actualizado)
  select mid, movil, placa, conductor, it_id, ruta, inicio, ultimo_gps, lat, lon, v_ts from parsed where mid is not null
  on conflict (mid) do update set
    movil = excluded.movil, placa = excluded.placa, conductor = excluded.conductor,
    it_id = excluded.it_id, ruta = excluded.ruta, inicio = excluded.inicio, ultimo_gps = excluded.ultimo_gps,
    lat = excluded.lat, lon = excluded.lon, actualizado = excluded.actualizado;
  get diagnostics v_n = row_count;

  delete from public.moviles_operacion where actualizado < v_ts;  -- móviles que ya no reporta

  return jsonb_build_object('ok', true, 'moviles', (select count(*) from public.moviles_operacion), 'ts', v_ts);
end $fn$;

revoke all on function public.refrescar_moviles_operacion_core() from public, anon, authenticated;

-- 3) LECTOR para el cliente (rápido, <50ms): agrupa el caché por ruta. Exige sesión.
create or replace function public.rutas_en_vivo()
returns jsonb
language sql
security definer
set search_path = public
as $fn$
  select case
    when auth.uid() is null then jsonb_build_object('ok', false, 'error', 'No autenticado.')
    else (
      select jsonb_build_object(
        'ok', true,
        'hora', to_char((select max(actualizado) from public.moviles_operacion) at time zone 'America/Bogota', 'HH24:MI:SS'),
        'edad_seg', coalesce(extract(epoch from (now() - (select max(actualizado) from public.moviles_operacion)))::int, 999999),
        'total',   (select count(*) from public.moviles_operacion),
        'en_ruta', (select count(*) from public.moviles_operacion where coalesce(it_id, 0) <> 0),
        'libres',  (select count(*) from public.moviles_operacion where coalesce(it_id, 0) = 0),
        'rutas', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'it_id', it_id, 'ruta', ruta, 'n', n, 'moviles', moviles) order by ruta)
          from (
            select it_id, ruta, count(*) as n,
                   jsonb_agg(jsonb_build_object(
                     'movil', movil, 'placa', placa, 'conductor', conductor, 'mid', mid,
                     'en_ruta_seg', case when inicio     is not null then extract(epoch from (now() - inicio))::int end,
                     'gps_seg',     case when ultimo_gps is not null then extract(epoch from (now() - ultimo_gps))::int end
                   ) order by movil) as moviles
            from public.moviles_operacion
            where coalesce(it_id, 0) <> 0
            group by it_id, ruta
          ) g), '[]'::jsonb)
      )
    )
  end
$fn$;

revoke all on function public.rutas_en_vivo() from public, anon;
grant execute on function public.rutas_en_vivo() to authenticated;

-- 4) Job de pg_cron: cada minuto refresca el caché (idempotente si ya existía).
select cron.schedule('refrescar-moviles-operacion', '* * * * *',
                     'select public.refrescar_moviles_operacion_core();');

-- 5) Semilla: llena el caché ya mismo (no esperar al primer minuto del cron).
select public.refrescar_moviles_operacion_core();

-- limpia funciones de prueba de la sesión de desarrollo
drop function if exists public._probe_rutas_vivo();
drop function if exists public._probe2();
drop function if exists public._probe_timing();
drop function if exists public._probe_campos();
