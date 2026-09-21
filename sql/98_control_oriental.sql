-- ============================================================================================
-- 98) Control Av. Oriental — el mismo modelo del Control Laureles, con un solo punto
--
-- QUÉ ES: el puesto físico sobre la Avenida Oriental. El controlador tiene la lista de los buses
-- que van a pasar hoy, con su hora, y a cada uno le escanea el QR al llegar. De ahí sale el
-- cumplimiento: cuántos pasaron, a qué hora y si el carro era el que se esperaba.
--
-- DIFERENCIA CON LAURELES: allá hay dos geocercas (entrada y salida) y por eso se puede medir
-- cuánto se demora el bus en el tramo. Aquí hay UN solo punto de paso, así que no hay
-- permanencia: se mide paso, puntualidad y escaneo. Si algún día se crea un segundo punto,
-- esto se amplía como está hecho allá.
--
-- LA GEOCERCA SE BUSCA POR PATRÓN, no por nombre exacto: 10 itinerarios la tienen escrita
-- "CONTROL AV. ORIENTAL" y uno (Santafé Directo) la tiene como "CONTROL AV ORIENTAL 130A".
-- Con búsqueda exacta esa ruta se quedaría por fuera del tablero y el controlador nunca sabría
-- que ese bus tenía que pasar.
--
-- OJO con las rutas de MADRUGADA: tienen la geocerca, pero no se despachan a SONAR (solo se
-- marcan como realizadas), así que no generan viajes y no van a aparecer aquí.
-- ============================================================================================

-- 1) Los chequeos del QR -------------------------------------------------------------------------
create table if not exists public.oriental_checkin (
  regid          bigint primary key,             -- itlId/regId del viaje en SONAR (único por viaje)
  fecha          date        not null,
  ruta           text,
  movil          text,
  placa_esperada text,
  placa_leida    text,
  ok             boolean     not null,            -- ¿la placa leída coincidió con la esperada?
  user_id        uuid        not null,
  user_email     text,
  user_nombre    text,
  scanned_at     timestamptz not null default now()
);
create index if not exists oriental_checkin_fecha_idx on public.oriental_checkin(fecha);

alter table public.oriental_checkin enable row level security;
-- Sin políticas: solo se llega por las funciones SECURITY DEFINER, como en Laureles.
revoke all on table public.oriental_checkin from anon, authenticated;

comment on table public.oriental_checkin is
  'Chequeos QR del puesto Control Av. Oriental. Quien escaneo, cuando, y si la placa coincidio.';

-- 2) Registrar un chequeo --------------------------------------------------------------------------
--    Quién escanea sale del JWT (no se puede falsear) y solo se permite el día de hoy.
create or replace function public.registrar_checkin_oriental(
  p_regid bigint, p_fecha date, p_ruta text, p_movil text,
  p_placa_esperada text, p_placa_leida text, p_ok boolean)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_email text; v_nombre text; v_hoy date;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'No autenticado.');
  end if;
  v_hoy := (now() at time zone 'America/Bogota')::date;
  if p_fecha is distinct from v_hoy then
    return jsonb_build_object('ok', false, 'error', 'Solo se puede chequear el día de hoy.');
  end if;

  select u.email, p.nombre into v_email, v_nombre
  from auth.users u
  left join public.perfiles p on lower(p.email) = lower(u.email)
  where u.id = auth.uid();

  insert into public.oriental_checkin
    (regid, fecha, ruta, movil, placa_esperada, placa_leida, ok, user_id, user_email, user_nombre, scanned_at)
  values
    (p_regid, p_fecha, p_ruta, p_movil, p_placa_esperada, p_placa_leida, p_ok, auth.uid(), v_email, v_nombre, now())
  on conflict (regid) do update set
    fecha = excluded.fecha, ruta = excluded.ruta, movil = excluded.movil,
    placa_esperada = excluded.placa_esperada, placa_leida = excluded.placa_leida,
    ok = excluded.ok, user_id = excluded.user_id, user_email = excluded.user_email,
    user_nombre = excluded.user_nombre, scanned_at = now();

  return jsonb_build_object('ok', true,
    'por',  coalesce(v_nombre, v_email),
    'hora', to_char((now() at time zone 'America/Bogota'), 'HH24:MI'));
end $fn$;
revoke all on function public.registrar_checkin_oriental(bigint, date, text, text, text, text, boolean) from public, anon;
grant execute on function public.registrar_checkin_oriental(bigint, date, text, text, text, text, boolean) to authenticated;

-- 3) El tablero del día ----------------------------------------------------------------------------
create or replace function public._control_oriental_core(p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_action text;
  v_body text; v_resp text; v_xml xml; v_ini text; v_fin text;
  v_itid bigint; v_ruta text; v_idx int; v_out jsonb;
  -- Tolerante a propósito: "CONTROL AV. ORIENTAL" y "CONTROL AV ORIENTAL 130A" son el mismo punto.
  c_pat constant text := 'control\s+av\.?\s+oriental';
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  if p_fecha is null then p_fecha := (now() at time zone 'America/Bogota')::date; end if;

  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_ItinerariesHistory_v2';
  v_ini := to_char((p_fecha::timestamp     at time zone 'America/Bogota') at time zone 'UTC','YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(((p_fecha+1)::timestamp at time zone 'America/Bogota') at time zone 'UTC','YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec','12000',true);

  create temp table if not exists _co(regid bigint, mid text, ruta text, init_utc timestamptz, running text,
    canceled text, real_utc timestamptz, diff int, exp_utc timestamptz) on commit drop;
  truncate _co;

  -- El índice del punto cambia por ruta (1 en casi todas, 4 en la 134A, 6 en la 134, 8 en la 134Y):
  -- por eso se resuelve por NOMBRE en cada itinerario, nunca por número.
  for v_itid, v_ruta, v_idx in
    select p.it_id, r.ruta,
      (select min(point_index) from public.itinerario_puntos
        where it_id = p.it_id and geofence_name ~* c_pat)
    from (select distinct it_id from public.itinerario_puntos where geofence_name ~* c_pat) p
    join public.itinerario_rutas r on r.it_id = p.it_id
  loop
    v_body := '<?xml version="1.0" encoding="utf-8"?>'
      || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      || '<GET_ItinerariesHistory_v2 xmlns="' || v_ns || '">'
      || '<User>'||v_usr||'</User><Password>'||v_pwd||'</Password>'
      || '<Itinerary>'||v_itid||'</Itinerary>'
      || '<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
      || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>';
    begin
      select content into v_resp from extensions.http((
        'POST', rtrim(v_url,'/')||'/', array[extensions.http_header('SOAPAction', v_action)],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_xml := v_resp::xml;
    exception when others then continue; end;   -- un itinerario que falle no tumba el tablero

    insert into _co
    select regid, mid, v_ruta, init_utc, running, canceled, real_utc, diff, exp_utc
    from (
      select
        (xpath('/x:ItLog/x:regId/text()',    it, array[array['x', v_ns]]))[1]::text::bigint as regid,
        (xpath('/x:ItLog/x:mId/text()',      it, array[array['x', v_ns]]))[1]::text as mid,
        public._utc_ts((xpath('/x:ItLog/x:inittime/text()', it, array[array['x', v_ns]]))[1]::text) as init_utc,
        (xpath('/x:ItLog/x:running/text()',  it, array[array['x', v_ns]]))[1]::text as running,
        (xpath('/x:ItLog/x:canceled/text()', it, array[array['x', v_ns]]))[1]::text as canceled,
        (xpath('/x:ItPointLog/x:p_index/text()', p, array[array['x', v_ns]]))[1]::text::int as idx,
        public._utc_ts((xpath('/x:ItPointLog/x:p_realtime/text()',     p, array[array['x', v_ns]]))[1]::text) as real_utc,
        nullif((xpath('/x:ItPointLog/x:p_difference/text()', p, array[array['x', v_ns]]))[1]::text,'')::int as diff,
        public._utc_ts((xpath('/x:ItPointLog/x:p_expectedtime/text()', p, array[array['x', v_ns]]))[1]::text) as exp_utc
      from unnest(xpath('//x:ItLog', v_xml, array[array['x', v_ns]])) it,
           unnest(xpath('/x:ItLog/x:ItPointsLog/x:ItPointLog', it, array[array['x', v_ns]])) p
    ) q
    where idx = v_idx;
  end loop;

  -- Si el bus todavía no ha registrado el paso, se muestra la hora PROGRAMADA: el desfase típico
  -- entre el inicio del viaje y este punto, por ruta (la moda, que ignora los casos raros).
  with off as (
    select ruta, mode() within group (order by extract(epoch from (exp_utc - init_utc))::int) as sec
    from _co where exp_utc is not null and init_utc is not null group by ruta
  ),
  trips as ( select distinct regid, mid, ruta, init_utc, running, canceled from _co ),
  paso as (
    select t.regid,
      case when m.real_utc is not null then
        jsonb_build_object('h', to_char(m.real_utc at time zone 'America/Bogota','HH24:MI:SS'), 'd', m.diff)
      when o.sec is not null and t.init_utc is not null then
        jsonb_build_object('h', to_char((t.init_utc + (o.sec || ' seconds')::interval) at time zone 'America/Bogota','HH24:MI'), 'e', true)
      else null end as cell
    from trips t
    left join _co m on m.regid = t.regid
    left join off o on o.ruta = t.ruta
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'ruta', t.ruta,
      'movil', (select vv.movil from public.vehiculosgps vv where vv.tracker_id::text = t.mid limit 1),
      'placa', (select vv.placa from public.vehiculosgps vv where vv.tracker_id::text = t.mid limit 1),
      'hora', to_char(t.init_utc at time zone 'America/Bogota','HH24:MI'),
      'regid', t.regid, 'running', t.running, 'canceled', t.canceled,
      'paso', p.cell,
      'chk', (select jsonb_build_object(
                'ok', oc.ok,
                'por', coalesce(oc.user_nombre, oc.user_email),
                'hora', to_char(oc.scanned_at at time zone 'America/Bogota','HH24:MI'),
                'leida', oc.placa_leida)
              from public.oriental_checkin oc where oc.regid = t.regid))
      order by coalesce(p.cell->>'h', to_char(t.init_utc at time zone 'America/Bogota','HH24:MI:SS'))
    ), '[]'::jsonb)
    into v_out
  from trips t left join paso p on p.regid = t.regid;

  return jsonb_build_object('ok', true, 'fecha', p_fecha,
    'hoy', (now() at time zone 'America/Bogota')::date,
    'punto', 'CONTROL AV. ORIENTAL',
    'viajes', v_out);
end $fn$;
revoke all on function public._control_oriental_core(date) from public, anon, authenticated;

-- Envoltura con control de sesión (la que llama el cliente).
create or replace function public.control_oriental(p_fecha date)
returns jsonb language plpgsql security definer set search_path = public as $fn$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  return public._control_oriental_core(p_fecha);
end $fn$;
revoke all on function public.control_oriental(date) from public, anon;
grant execute on function public.control_oriental(date) to authenticated;

-- 4) Comprobación rápida: qué rutas quedan cubiertas por el patrón
--    select r.ruta, p.point_index, p.geofence_name
--      from public.itinerario_puntos p
--      join public.itinerario_rutas r on r.it_id = p.it_id
--     where p.geofence_name ~* 'control\s+av\.?\s+oriental'
--     order by r.ruta;
