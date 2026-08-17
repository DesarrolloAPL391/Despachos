-- 39: "¿Dónde se monta la gente?" — paradas por móvil/día desde SONAR (p_station) + mapa.
-- SONAR (GET_PassengersCounter) trae en cada evento p_station = dirección geocodificada
-- (texto) donde ocurrió la subida/bajada, pero NO trae lat/lon. Para el mapa se geocodifica
-- la dirección en el cliente (TomTom) y se guarda en geo_cache para no repetir.
--
-- Cambios:
--   * geo_cache: caché dirección -> lat/lon (compartida por todos, la llena el admin).
--   * geo_cache_set(dir, lat, lon): guarda un geocode (solo admin).
--   * pasajeros_movil: ahora ADEMÁS devuelve 'paradas' (agrupadas por p_station, top 40 por
--     subidas) con lat/lon si ya están en caché.

-- ---- Caché de geocodificación (dirección -> coordenadas) ----
create table if not exists public.geo_cache (
  direccion text primary key,
  lat  double precision,
  lon  double precision,
  fuente text,
  creado timestamptz not null default now()
);
alter table public.geo_cache enable row level security;
drop policy if exists geo_cache_leer on public.geo_cache;
create policy geo_cache_leer on public.geo_cache for select to authenticated using (true);
-- Escritura solo por el RPC SECURITY DEFINER (que exige es_admin); sin política de insert/update.

create or replace function public.geo_cache_set(p_dir text, p_lat double precision, p_lon double precision)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo un administrador puede guardar geocodificaciones.'; end if;
  if nullif(trim(p_dir),'') is null or p_lat is null or p_lon is null then return; end if;
  insert into public.geo_cache (direccion, lat, lon, fuente)
  values (trim(p_dir), p_lat, p_lon, 'tomtom')
  on conflict (direccion) do update set lat = excluded.lat, lon = excluded.lon, fuente = excluded.fuente, creado = now();
end $$;
grant execute on function public.geo_cache_set(text, double precision, double precision) to authenticated;

-- ---- pasajeros_movil: igual que antes + 'paradas' (con coords de caché) ----
create or replace function public.pasajeros_movil(p_movil text, p_fecha date)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text;
  v_mid text; v_ini text; v_fin text; v_resp extensions.http_response; v_doc xml;
  v_status text; v_sub int; v_baj int; v_blq int; v_n int; v_porhora jsonb; v_porpuerta jsonb; v_paradas jsonb;
begin
  if not public.es_admin() then raise exception 'Solo un administrador puede consultar pasajeros.'; end if;
  if nullif(trim(p_movil),'') is null then return jsonb_build_object('ok', false, 'error', 'Móvil vacío.'); end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Fecha vacía.'); end if;

  select tracker_id into v_mid from public.vehiculosgps where movil = trim(p_movil) limit 1;
  if v_mid is null then return jsonb_build_object('ok', false, 'error', 'El móvil '||trim(p_movil)||' no tiene Id GPS en SONAR.'); end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_PassengersCounter';

  -- Día Colombia [00:00, 23:59:59] convertido a UTC (+5h): [fecha 05:00, fecha+1 04:59:59]
  v_ini := to_char(p_fecha::timestamp + interval '5 hours', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(p_fecha::timestamp + interval '1 day 5 hours' - interval '1 second', 'YYYY-MM-DD HH24:MI:SS');

  perform set_config('http.timeout_msec','6500',true);
  select * into v_resp from extensions.http((
    'POST', rtrim(v_url,'/')||'/',
    array[extensions.http_header('SOAPAction', v_action)],
    'text/xml; charset=utf-8',
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    ||'<GET_PassengersCounter xmlns="'||v_ns||'">'
    ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
    ||'<mId>'||public._xmlesc(v_mid)||'</mId>'
    ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    ||'</GET_PassengersCounter></soap:Body></soap:Envelope>'
  )::extensions.http_request);
  if v_resp.status <> 200 then return jsonb_build_object('ok', false, 'error', 'SONAR HTTP '||v_resp.status); end if;

  v_doc := xmlparse(document v_resp.content);
  v_status := (regexp_match(v_resp.content, '(?i)<status>([^<]*)</status>'))[1];

  -- Detalle por puerta + hora + dirección (p_station) del PassengersLog padre (../.. sube 2 niveles).
  -- La dirección se saca del JSON de p_station por regex (robusto ante JSON raro).
  create temp table _dd on commit drop as
  select coalesce(din,0) din, coalesce(dout,0) dout, coalesce(dblock,0) dblock, door,
         (to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') - interval '5 hours') ts_co,
         nullif((regexp_match(station, '"label"\s*:\s*"([^"]*)"'))[1], '') estacion
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing v_doc
    columns
      door    int  path 'n:Door',
      din     int  path 'n:DoorIn',
      dout    int  path 'n:DoorOut',
      dblock  int  path 'n:DoorBlocking',
      gps     text path '../../n:gps_UTC',
      station text path '../../n:p_station'
  );

  select count(*), coalesce(sum(din),0), coalesce(sum(dout),0), coalesce(sum(dblock),0)
    into v_n, v_sub, v_baj, v_blq from _dd;

  select jsonb_agg(jsonb_build_object('hora', h, 'subidas', s, 'bajadas', b) order by h)
    into v_porhora
    from (select extract(hour from ts_co)::int h, sum(din) s, sum(dout) b
          from _dd where ts_co is not null group by 1) t;

  select jsonb_object_agg(door::text, s)
    into v_porpuerta
    from (select door, sum(din) s from _dd where door is not null group by door) t;

  -- Paradas: agrupadas por dirección, top 40 por subidas, con coords de caché si existen.
  select jsonb_agg(x order by (x->>'subidas')::int desc)
    into v_paradas
    from (
      select jsonb_build_object(
        'parada', d.estacion, 'subidas', sum(d.din), 'bajadas', sum(d.dout),
        'lat', g.lat, 'lon', g.lon
      ) x, sum(d.din) sub
      from _dd d left join public.geo_cache g on g.direccion = d.estacion
      where d.estacion is not null
      group by d.estacion, g.lat, g.lon
      order by sum(d.din) desc
      limit 40
    ) q;

  return jsonb_build_object(
    'ok', true, 'movil', trim(p_movil), 'mid', v_mid, 'fecha', p_fecha,
    'status', coalesce(v_status,'OK'), 'registros', v_n,
    'subidas', v_sub, 'bajadas', v_baj, 'bloqueos', v_blq,
    'por_hora', coalesce(v_porhora, '[]'::jsonb),
    'por_puerta', coalesce(v_porpuerta, '{}'::jsonb),
    'paradas', coalesce(v_paradas, '[]'::jsonb)
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

grant execute on function public.pasajeros_movil(text, date) to authenticated;
