-- 38: Pasajeros por móvil y día (solo admin), en vivo desde SONAR (GET_PassengersCounter).
-- El conteo real está en el detalle por puerta: DoorIn = subieron, DoorOut = bajaron.
-- El rango del día Colombia se envía en UTC (Colombia + 5h). Devuelve totales + por hora.

create or replace function public.pasajeros_movil(p_movil text, p_fecha date)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text;
  v_mid text; v_ini text; v_fin text; v_resp extensions.http_response; v_doc xml;
  v_status text; v_sub int; v_baj int; v_blq int; v_n int; v_porhora jsonb; v_porpuerta jsonb;
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

  -- Detalle por puerta, con la hora del PassengersLog padre (../.. sube 2 niveles)
  create temp table _dd on commit drop as
  select coalesce(din,0) din, coalesce(dout,0) dout, coalesce(dblock,0) dblock, door,
         (to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') - interval '5 hours') ts_co
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing v_doc
    columns
      door   int  path 'n:Door',
      din    int  path 'n:DoorIn',
      dout   int  path 'n:DoorOut',
      dblock int  path 'n:DoorBlocking',
      gps    text path '../../n:gps_UTC'
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

  return jsonb_build_object(
    'ok', true, 'movil', trim(p_movil), 'mid', v_mid, 'fecha', p_fecha,
    'status', coalesce(v_status,'OK'), 'registros', v_n,
    'subidas', v_sub, 'bajadas', v_baj, 'bloqueos', v_blq,
    'por_hora', coalesce(v_porhora, '[]'::jsonb),
    'por_puerta', coalesce(v_porpuerta, '{}'::jsonb)
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $$;

grant execute on function public.pasajeros_movil(text, date) to authenticated;
