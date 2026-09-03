-- 53_pasajeros_dia.sql
-- Almacena los pasajeros (subidas/bajadas) por MÓVIL y DÍA, bajados de SONAR
-- (GET_PassengersCounter). Alimenta el "Top de movilización" por semana/mes.
-- No existía histórico de pasajeros: hasta ahora solo se consultaba en vivo por móvil.

create table if not exists public.pasajeros_dia (
  movil       text not null,
  fecha       date not null,
  subidas     int  not null default 0,
  bajadas     int  not null default 0,
  mid         text,
  actualizado timestamptz not null default now(),
  primary key (movil, fecha)
);
alter table public.pasajeros_dia enable row level security;

-- Lectura: admin ve todo; afiliado solo sus móviles. (El top va por RPC SECURITY DEFINER,
-- pero dejamos la RLS coherente por si se consulta la tabla directo.)
drop policy if exists pax_dia_sel on public.pasajeros_dia;
create policy pax_dia_sel on public.pasajeros_dia for select to authenticated
  using (public.es_admin() or (public.es_afiliado() and trim(movil) = any(public.mis_moviles_afiliado())));

-- Baja de SONAR los pasajeros de UN móvil en UN día (Colombia) y devuelve totales.
-- SECURITY DEFINER; pensada para el cron/backfill (no está atada al statement_timeout del navegador).
create or replace function public._pax_dia_movil(p_movil text, p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions','vault'
as $function$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text;
  v_mid text; v_ini text; v_fin text; v_resp extensions.http_response; v_doc xml;
  v_sub int; v_baj int;
begin
  select tracker_id into v_mid from public.vehiculosgps where movil = trim(p_movil) limit 1;
  if v_mid is null then return jsonb_build_object('ok', false, 'error', 'sin mid'); end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'falta SONAR_URL'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_PassengersCounter';

  -- Día Colombia [00:00, 23:59:59] en UTC (+5h)
  v_ini := to_char(p_fecha::timestamp + interval '5 hours', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(p_fecha::timestamp + interval '1 day 5 hours' - interval '1 second', 'YYYY-MM-DD HH24:MI:SS');

  perform set_config('http.timeout_msec','8000',true);
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
  if v_resp.status <> 200 then return jsonb_build_object('ok', false, 'error', 'HTTP '||v_resp.status); end if;

  v_doc := xmlparse(document v_resp.content);
  select coalesce(sum(din),0), coalesce(sum(dout),0) into v_sub, v_baj
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing v_doc
    columns din int path 'n:DoorIn', dout int path 'n:DoorOut');

  return jsonb_build_object('ok', true, 'mid', v_mid, 'subidas', coalesce(v_sub,0), 'bajadas', coalesce(v_baj,0));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

-- Sincroniza por LOTES: toma (móvil, día) que operaron en los últimos p_dias días (sin hoy),
-- tienen GPS y aún no están en pasajeros_dia, y baja sus pasajeros de SONAR. Idempotente:
-- se puede llamar muchas veces (cron/backfill) hasta que 'faltan' llegue a 0.
create or replace function public.sync_pasajeros_dia(p_dias int default 3, p_limit int default 30)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions','vault'
as $function$
declare
  r record; v_res jsonb; v_ok int := 0; v_fail int := 0; v_faltan int;
begin
  perform set_config('statement_timeout','0',true); -- cron/backfill: sin límite (hace varias llamadas http)
  for r in
    select distinct v.numero as movil, d.fecha
    from public.despachos d
    join public.vehiculos v    on v.id = d.vehiculo_id
    join public.vehiculosgps g on trim(g.movil) = trim(v.numero)
    where d.fecha between (current_date - p_dias) and (current_date - 1)
      and (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null)
      and g.tracker_id is not null
      and not exists (select 1 from public.pasajeros_dia pd where pd.movil = v.numero and pd.fecha = d.fecha)
    order by d.fecha desc, v.numero
    limit p_limit
  loop
    v_res := public._pax_dia_movil(r.movil, r.fecha);
    if coalesce((v_res->>'ok')::boolean, false) then
      insert into public.pasajeros_dia (movil, fecha, subidas, bajadas, mid, actualizado)
      values (r.movil, r.fecha, (v_res->>'subidas')::int, (v_res->>'bajadas')::int, v_res->>'mid', now())
      on conflict (movil, fecha) do update
        set subidas = excluded.subidas, bajadas = excluded.bajadas, mid = excluded.mid, actualizado = now();
      v_ok := v_ok + 1;
    else
      v_fail := v_fail + 1;
    end if;
  end loop;
  select count(*) into v_faltan
    from (select distinct v.numero movil, d.fecha
          from public.despachos d
          join public.vehiculos v    on v.id = d.vehiculo_id
          join public.vehiculosgps g on trim(g.movil) = trim(v.numero)
          where d.fecha between (current_date - p_dias) and (current_date - 1)
            and (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null)
            and g.tracker_id is not null
            and not exists (select 1 from public.pasajeros_dia pd where pd.movil = v.numero and pd.fecha = d.fecha)) q;
  return jsonb_build_object('ok', true, 'procesados', v_ok, 'fallidos', v_fail, 'faltan', v_faltan);
end $function$;

-- Top de movilización por MÓVIL (pasajeros = subidas) en un periodo. Admin ve toda la flota;
-- el afiliado solo SUS móviles. Periodo: 'dia' (ayer), 'mes' (últimos 30) o 'rango' con
-- p_desde/p_hasta. Devuelve también el nº de VIAJES realizados por carro (_despachos_realizados).
drop function if exists public.top_movilizacion(text);

create or replace function public.top_movilizacion(p_periodo text default 'mes', p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_per text; v_desde date; v_hasta date; v_afil boolean; v_ids text[];
begin
  if not (public.es_admin() or public.es_afiliado()) then
    raise exception 'No autorizado.';
  end if;
  v_per := lower(coalesce(p_periodo, 'mes'));
  if v_per = 'rango' and p_desde is not null and p_hasta is not null then
    v_desde := p_desde;
    v_hasta := least(p_hasta, current_date - 1);
    if v_desde > v_hasta then v_desde := v_hasta; end if;
    if v_hasta - v_desde > 92 then v_desde := v_hasta - 92; end if;
  elsif v_per = 'dia' then
    v_hasta := current_date - 1; v_desde := current_date - 1;
  elsif v_per = 'semana' then
    v_hasta := current_date - 1; v_desde := current_date - 7;
  else
    v_per := 'mes'; v_hasta := current_date - 1; v_desde := current_date - 30;
  end if;
  v_afil := public.es_afiliado() and not public.es_admin();
  v_ids  := case when v_afil then public.mis_moviles_afiliado() else null end;

  return (
    with base as (  -- pasajeros por carro en el periodo (afiliado: solo sus móviles)
      select trim(pd.movil) as movil,
             sum(pd.subidas)::int as subidas, sum(pd.bajadas)::int as bajadas,
             count(distinct pd.fecha)::int as dias
      from public.pasajeros_dia pd
      where pd.fecha between v_desde and v_hasta
        and (v_ids is null or trim(pd.movil) = any(v_ids))
      group by trim(pd.movil)
    ),
    vc as (  -- viajes realizados por carro en el periodo (todas las rutas/fuentes)
      select dr.movil, count(*)::int as viajes
      from public._despachos_realizados(v_desde, v_hasta) dr
      group by dr.movil
    )
    select jsonb_build_object(
      'ok', true, 'periodo', v_per, 'desde', v_desde, 'hasta', v_hasta,
      'resumen', jsonb_build_object(
        'moviles',        (select count(*) from base),
        'subidas_total',  (select coalesce(sum(subidas), 0) from base),
        'viajes_total',   (select coalesce(sum(vc.viajes), 0) from vc where vc.movil in (select movil from base)),
        'dias_con_datos', (select count(distinct fecha) from public.pasajeros_dia
                            where fecha between v_desde and v_hasta
                              and (v_ids is null or trim(movil) = any(v_ids)))),
      'carros', (
        select coalesce(jsonb_agg(x order by x.subidas desc), '[]'::jsonb) from (
          select b.movil,
                 (select v.placa from public.vehiculos v where trim(v.numero) = b.movil limit 1) as placa,
                 b.subidas, b.bajadas, b.dias,
                 round(b.subidas::numeric / nullif(b.dias,0), 0) as prom_dia,
                 coalesce(vc.viajes, 0) as viajes
          from base b
          left join vc on vc.movil = b.movil
        ) x)
    )
  );
end $function$;

revoke all on function public.sync_pasajeros_dia(int,int) from public;
revoke all on function public.top_movilizacion(text,date,date) from public;
grant execute on function public.top_movilizacion(text,date,date) to authenticated;
