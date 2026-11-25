-- 207: el detalle de SONAR de ✅ Revisión de viajes alcanza el atraso.
-- El 25/11/2026 se clasificaron los viajes desde el 18/11 (OK del usuario): 2.917 pendientes más. Cambios a sql/206:
--   * la cola de revision_detalle_sonar mira 14 días (antes 7) y trae primero lo MÁS RECIENTE (lo que el monitor revisa hoy);
--   * el cron pide hasta 60 grupos (itinerario + franja de 2 h) por corrida; igual sale a los 60 s y tiene techo de 100 s.
-- Es solo la función y el cron: no toca datos. DESHACER: volver a correr la sección 7 y el cron de sql/206.

create or replace function public.revision_detalle_sonar(p_max int default 25)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions'
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_act text;
  v_t0 timestamptz := clock_timestamp();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  r record; v_doc xml; v_its int := 0; v_n int := 0; v_k int; v_err int := 0; v_sin int := 0;
begin
  if not pg_try_advisory_xact_lock(724206) then
    return jsonb_build_object('ok', true, 'nota', 'otra corrida en curso');
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_act := rtrim(v_ns, '/') || '/ServiceSoap/GET_ItinerariesHistory_v2';

  create temp table if not exists _rd (regid bigint, estado text, ini timestamptz, fin timestamptz, marcados int[], tarde int[],
                                       antes int[], atraso_fin int, atraso_max int, salio boolean, cancelo boolean) on commit drop;

  for r in
    with p as (
      select ds.itl_id as regid, ((ds.fecha + ds.hora_inicio) at time zone 'America/Bogota') as ini,
             coalesce(
               (select i.itid::bigint from public.itinerarios i
                 where lower(btrim(i.nombre)) = lower(btrim(ds.ruta)) and i.itid ~ '^[0-9]{1,18}$' order by i.id limit 1),
               (select c.it_id from public.vigilancia_casos c
                 where lower(btrim(c.ruta)) = lower(btrim(ds.ruta)) and c.it_id is not null
                 group by c.it_id order by count(*) desc limit 1)) as it_id
        from public.despachos_sonar ds
        left join public.viajes_sonar_detalle w on w.regid = ds.itl_id
       where ds.revision = 'PENDIENTE' and ds.fecha >= v_hoy - 14 and ds.hora_inicio is not null
         and (w.regid is null
              or (w.estado not in ('COMPLETO', 'INCOMPLETO', 'CANCELADO', 'SIN_ITINERARIO')
                  and w.revisado < now() - interval '10 minutes' and w.intentos < 20)))
    select p.it_id, date_trunc('hour', p.ini) - make_interval(hours => extract(hour from p.ini)::int % 2) as bloque,
           min(p.ini) as ini_min, max(p.ini) as ini_max, array_agg(p.regid) as regids
      from p group by 1, 2 order by max(p.ini) desc limit p_max   -- lo más reciente primero (sql/207)
  loop
    if r.it_id is null then
      insert into public.viajes_sonar_detalle as w (regid, estado, revisado, intentos)
      select x, 'SIN_ITINERARIO', now(), 1 from unnest(r.regids) x
      on conflict (regid) do update set estado = 'SIN_ITINERARIO', revisado = now(), intentos = w.intentos + 1;
      v_sin := v_sin + cardinality(r.regids);
      continue;
    end if;
    exit when clock_timestamp() - v_t0 > interval '60 seconds';
    v_its := v_its + 1;
    begin
      truncate _rd;
      perform set_config('http.timeout_msec', '20000', true);
      select xmlparse(document h.content) into v_doc from extensions.http((
        'POST', rtrim(v_url, '/') || '/', array[extensions.http_header('SOAPAction', v_act)], 'text/xml; charset=utf-8',
        '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
        || '<GET_ItinerariesHistory_v2 xmlns="' || v_ns || '"><User>' || public._xmlesc(v_usr) || '</User><Password>'
        || public._xmlesc(v_pwd) || '</Password><Itinerary>' || r.it_id || '</Itinerary>'
        || '<UTC_datetime_init>' || to_char(r.ini_min at time zone 'UTC' - interval '3 minutes', 'YYYY-MM-DD HH24:MI:SS') || '</UTC_datetime_init>'
        || '<UTC_datetime_end>' || to_char(r.ini_max at time zone 'UTC' + interval '3 minutes', 'YYYY-MM-DD HH24:MI:SS') || '</UTC_datetime_end>'
        || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>')::extensions.http_request) h;

      insert into _rd
      with t as (
        select x.regid::bigint as regid, x.running, x.close, x.canceled, x.fuera, x.ucan,
               public._utc_ts(x.ini) as ini, public._utc_ts(x.fin) as fin, x.pts
          from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n), '//n:ItLog' passing v_doc
                 columns regid text path 'n:regId', running text path 'n:running', close text path 'n:close',
                         canceled text path 'n:canceled', fuera text path 'n:leaveroute', ucan text path 'n:userCanceled',
                         ini text path 'n:inittime', fin text path 'n:endtime', pts xml path 'n:ItPointsLog') x
         where x.regid ~ '^[0-9]{1,18}$' and x.regid::bigint = any(r.regids)),
      p as (
        select t.regid, y.idx, nullif(y.diff, '')::int as diff, upper(coalesce(y.viol, '')) as viol
          from t, xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n), '/n:ItPointsLog/n:ItPointLog' passing t.pts
                 columns idx int path 'n:p_index', diff text path 'n:p_difference', viol text path 'n:p_violation',
                         realt text path 'n:p_realtime') y
         where public._utc_ts(y.realt) is not null)
      select t.regid,
             case when t.running = 'Y' then 'EN_CURSO'
                  when t.close = 'Y' and t.canceled = 'Y' then 'INCOMPLETO'      -- regla de SONAR (despachos-regla-estados)
                  when t.close = 'Y' then 'COMPLETO'
                  when t.canceled = 'Y' then 'CANCELADO'
                  else 'EN_CURSO' end,
             t.ini, t.fin,
             (select array_agg(distinct p.idx order by p.idx) from p where p.regid = t.regid),
             (select array_agg(distinct p.idx order by p.idx) from p where p.regid = t.regid and p.viol = 'R'),
             (select array_agg(distinct p.idx order by p.idx) from p where p.regid = t.regid and p.viol = 'A'),
             (select p.diff from p where p.regid = t.regid and p.diff is not null order by p.idx desc limit 1),
             (select max(p.diff) from p where p.regid = t.regid),
             t.fuera = 'Y', t.ucan = 'Y'
        from t;

      insert into public.viajes_sonar_detalle as w (regid, it_id, estado, inicio, fin, puntos_total, marcados, tarde, antes,
                                                     atraso_fin, atraso_max, salio_ruta, cancelo_usuario, revisado, intentos)
      select v.regid, r.it_id, v.estado, v.ini, v.fin,
             (select nullif(count(*), 0) from public.itinerario_puntos ip where ip.it_id = r.it_id),
             coalesce(v.marcados, '{}'), coalesce(v.tarde, '{}'), coalesce(v.antes, '{}'), v.atraso_fin, v.atraso_max,
             v.salio, v.cancelo, now(), 1
        from _rd v
      on conflict (regid) do update set it_id = excluded.it_id, estado = excluded.estado, inicio = excluded.inicio,
        fin = excluded.fin, puntos_total = excluded.puntos_total, marcados = excluded.marcados, tarde = excluded.tarde,
        antes = excluded.antes, atraso_fin = excluded.atraso_fin, atraso_max = excluded.atraso_max,
        salio_ruta = excluded.salio_ruta, cancelo_usuario = excluded.cancelo_usuario, revisado = now(), intentos = w.intentos + 1;
      get diagnostics v_k = row_count; v_n := v_n + v_k;

      -- los que SONAR no devolvió se anotan y se vuelven a preguntar más tarde (con tope de intentos)
      insert into public.viajes_sonar_detalle as w (regid, it_id, estado, revisado, intentos)
      select x, r.it_id, 'NO_ENCONTRADO', now(), 1 from unnest(r.regids) x
       where not exists (select 1 from _rd v where v.regid = x)
      on conflict (regid) do update set revisado = now(), intentos = w.intentos + 1;
    exception when others then
      v_err := v_err + 1;   -- un itinerario que falle no tumba a los demás
    end;
  end loop;
  return jsonb_build_object('ok', true, 'consultas', v_its, 'viajes', v_n, 'sin_itinerario', v_sin, 'errores', v_err,
                            'seg', round(extract(epoch from clock_timestamp() - v_t0)::numeric, 1));
end $fn$;
revoke all on function public.revision_detalle_sonar(int) from public, anon, authenticated;
alter function public.revision_detalle_sonar(int) set statement_timeout = '100s';   -- sql/120: techo propio

select cron.unschedule('revision-detalle-sonar') where exists (select 1 from cron.job where jobname = 'revision-detalle-sonar');
select cron.schedule('revision-detalle-sonar', '1-56/5 * * * *', $cron$select public.revision_detalle_sonar(60)$cron$);
