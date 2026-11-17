-- 193: el 🚨 Vigilante de ruta llega a las FILAS de los despachos para ayudar a los MONITORES (pedido 16/11/2026).
-- "si el vigilante encuentra algo que lo ponga en la fila del viaje y explique que paso ... y si el viaje fue completo
--  [y] no se tuvo contratiempo sugerir que este no se debe de verificar".
-- 1) vigilancia_viajes: como TERMINO cada viaje que tiene un caso (estado SONAR + atraso en el ultimo punto). La llena
--    el cron 'vigilante-viajes' cada 5 min con GET_ItinerariesHistory_v2 (solo lectura de SONAR): una consulta por
--    itinerario, solo con la franja de salida de los viajes que faltan.
-- 2) _vig_puede vuelve a la regla de sql/172: admin, o auditor en SUS rutas. Asi el monitor abre y audita el caso desde
--    la fila. La pantalla completa del vigilante (vigilancia_listar) SIGUE solo para administracion (sql/173).
-- 3) vigilancia_caso trae tambien como termino el viaje (y el del de adelante).
-- 4) vigilancia_por_viajes(regIds): los casos de las filas que se estan viendo (una consulta por carga de tabla).
set lock_timeout = '5s';

-- 1) indices para buscar los casos por el viaje ---------------------------------------------------------------------
create index if not exists vigilancia_casos_regid on public.vigilancia_casos (regid) where regid is not null;
create index if not exists vigilancia_casos_regid_rel on public.vigilancia_casos (regid_rel) where regid_rel is not null;

-- 2) como termino cada viaje con caso -------------------------------------------------------------------------------
create table if not exists public.vigilancia_viajes (
  regid         bigint primary key,      -- itlId / regId de SONAR
  it_id         bigint,
  estado        text not null,           -- EN_CURSO, COMPLETO, INCOMPLETO, CANCELADO, NO_ENCONTRADO
  atraso_fin    int,                     -- min de atraso en el ultimo punto al que llego (negativo = llego antes)
  atraso_max    int,                     -- el mayor atraso que tuvo en el viaje
  puntos        int,                     -- puntos con hora real
  ultimo_punto  int,                     -- el ultimo punto al que llego (desde 0 = la salida)
  inicio        timestamptz,
  fin           timestamptz,
  revisado      timestamptz not null default now(),
  intentos      int not null default 0
);
comment on table public.vigilancia_viajes is 'Vigilante (sql/193): como termino en SONAR cada viaje que tiene un caso.';
alter table public.vigilancia_viajes enable row level security;    -- nadie la lee directo: solo las funciones
revoke all on table public.vigilancia_viajes from public, anon, authenticated;

create or replace function public.vigilante_viajes(p_max_its int default 30)
returns jsonb
language plpgsql security definer set search_path to 'public', 'extensions'
as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_act text;
  v_t0 timestamptz := clock_timestamp();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  r record; v_doc xml; v_its int := 0; v_n int := 0; v_k int; v_err int := 0;
begin
  if not pg_try_advisory_xact_lock(724193) then
    return jsonb_build_object('ok', true, 'nota', 'otra corrida en curso');
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_act := rtrim(v_ns, '/') || '/ServiceSoap/GET_ItinerariesHistory_v2';

  create temp table if not exists _vv (regid bigint, estado text, atraso_fin int, atraso_max int, puntos int,
                                       ultimo_punto int, inicio timestamptz, fin timestamptz) on commit drop;

  -- los viajes de los casos de hoy y ayer (el del bus y, en adelantamientos, el de adelante) que aun no tienen final
  for r in
    with v as (
      select c.it_id, c.regid, c.inicio_viaje ini from public.vigilancia_casos c
       where c.fecha >= v_hoy - 1 and c.estado in ('ABIERTO', 'CERRADO') and c.regid is not null and c.it_id is not null
      union
      select c.it_id, c.regid_rel, coalesce(c.inicio_rel, c.inicio_viaje) from public.vigilancia_casos c
       where c.fecha >= v_hoy - 1 and c.estado in ('ABIERTO', 'CERRADO') and c.regid_rel is not null and c.it_id is not null),
    p as (
      select v.* from v left join public.vigilancia_viajes w on w.regid = v.regid
       where w.regid is null
          or (w.estado not in ('COMPLETO', 'INCOMPLETO', 'CANCELADO') and w.revisado < now() - interval '8 minutes' and w.intentos < 60))
    select p.it_id, min(p.ini) ini_min, max(p.ini) ini_max, array_agg(distinct p.regid) regids
      from p group by p.it_id order by min(p.ini) limit p_max_its
  loop
    exit when clock_timestamp() - v_t0 > interval '60 seconds';
    v_its := v_its + 1;
    begin
      truncate _vv;
      perform set_config('http.timeout_msec', '20000', true);
      -- SONAR filtra por la hora de SALIDA del viaje: se pide solo la franja de salida de los viajes que faltan
      select xmlparse(document h.content) into v_doc from extensions.http((
        'POST', rtrim(v_url, '/') || '/', array[extensions.http_header('SOAPAction', v_act)], 'text/xml; charset=utf-8',
        '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
        || '<GET_ItinerariesHistory_v2 xmlns="' || v_ns || '"><User>' || public._xmlesc(v_usr) || '</User><Password>'
        || public._xmlesc(v_pwd) || '</Password><Itinerary>' || r.it_id || '</Itinerary>'
        || '<UTC_datetime_init>' || to_char(coalesce(r.ini_min, now() - interval '1 day') at time zone 'UTC' - interval '3 minutes', 'YYYY-MM-DD HH24:MI:SS') || '</UTC_datetime_init>'
        || '<UTC_datetime_end>' || to_char(coalesce(r.ini_max, now()) at time zone 'UTC' + interval '3 minutes', 'YYYY-MM-DD HH24:MI:SS') || '</UTC_datetime_end>'
        || '</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>')::extensions.http_request) h;

      insert into _vv
      with t as (
        select x.regid::bigint regid, x.running, x.close, x.canceled, public._utc_ts(x.ini) ini, public._utc_ts(x.fin) fin, x.pts
          from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n), '//n:ItLog' passing v_doc
                 columns regid text path 'n:regId', running text path 'n:running', close text path 'n:close',
                         canceled text path 'n:canceled', ini text path 'n:inittime', fin text path 'n:endtime',
                         pts xml path 'n:ItPointsLog') x
         where x.regid ~ '^[0-9]{1,18}$' and x.regid::bigint = any(r.regids)),
      p as (
        select t.regid, y.idx, nullif(y.diff, '')::int diff
          from t, xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n), '/n:ItPointsLog/n:ItPointLog' passing t.pts
                 columns idx int path 'n:p_index', diff text path 'n:p_difference', realt text path 'n:p_realtime') y
         where public._utc_ts(y.realt) is not null)
      select t.regid,
             case when t.running = 'Y' then 'EN_CURSO'
                  when t.close = 'Y' and t.canceled = 'Y' then 'INCOMPLETO'      -- regla de SONAR (despachos-regla-estados)
                  when t.close = 'Y' then 'COMPLETO'
                  when t.canceled = 'Y' then 'CANCELADO'
                  else 'EN_CURSO' end,
             (select p.diff from p where p.regid = t.regid and p.diff is not null order by p.idx desc limit 1),
             (select max(p.diff) from p where p.regid = t.regid),
             (select count(*) from p where p.regid = t.regid),
             (select max(p.idx) from p where p.regid = t.regid),
             t.ini, t.fin
        from t;

      insert into public.vigilancia_viajes as w (regid, it_id, estado, atraso_fin, atraso_max, puntos, ultimo_punto, inicio, fin, revisado, intentos)
      select v.regid, r.it_id, v.estado, v.atraso_fin, v.atraso_max, v.puntos, v.ultimo_punto, v.inicio, v.fin, now(), 1 from _vv v
      on conflict (regid) do update set estado = excluded.estado, atraso_fin = excluded.atraso_fin, atraso_max = excluded.atraso_max,
        puntos = excluded.puntos, ultimo_punto = excluded.ultimo_punto, inicio = excluded.inicio, fin = excluded.fin,
        revisado = now(), intentos = w.intentos + 1;
      get diagnostics v_k = row_count; v_n := v_n + v_k;

      -- los que SONAR no devolvio: se anotan (y se vuelven a preguntar mas tarde, con tope de intentos)
      insert into public.vigilancia_viajes as w (regid, it_id, estado, revisado, intentos)
      select x, r.it_id, 'NO_ENCONTRADO', now(), 1 from unnest(r.regids) x
       where not exists (select 1 from _vv v where v.regid = x)
      on conflict (regid) do update set revisado = now(), intentos = w.intentos + 1;
    exception when others then
      v_err := v_err + 1;   -- un itinerario que falle no tumba a los demas
    end;
  end loop;
  return jsonb_build_object('ok', true, 'itinerarios', v_its, 'viajes', v_n, 'errores', v_err,
                            'seg', round(extract(epoch from clock_timestamp() - v_t0)::numeric, 1));
end $fn$;
revoke all on function public.vigilante_viajes(int) from public, anon, authenticated;
-- techo propio (sql/120: un cron sin techo hereda 120 s y, si se corta, revierte todo)
alter function public.vigilante_viajes(int) set statement_timeout = '100s';

-- cada 5 min (minuto 3, 8, 13...: no choca con los */2 ni los */10), en las horas del vigilante + 1 h despues de medianoche
select cron.schedule('vigilante-viajes', '3-58/5 0-5,8-23 * * *', 'select public.vigilante_viajes()');

-- 3) permiso: admin todo; auditor (monitor), sus rutas (la regla de sql/172) ---------------------------------------
create or replace function public._vig_puede(p_ruta text, p_ruta_mapa text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select (select public.es_admin())
      or ((select public.es_auditor())
          and (lower(btrim(coalesce(p_ruta, ''))) = any (public.mis_ruta_nombres())
               or lower(btrim(coalesce(p_ruta_mapa, ''))) = any (public.mis_ruta_nombres())));
$$;
revoke all on function public._vig_puede(text, text) from public, anon, authenticated;

-- 4) el detalle del caso trae tambien como termino cada viaje -------------------------------------------------------
create or replace function public._vig_viaje_json(p_regid bigint)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object('estado', w.estado, 'atraso_fin', w.atraso_fin, 'atraso_max', w.atraso_max,
           'puntos', w.puntos, 'ultimo_punto', w.ultimo_punto,
           'inicio', to_char(w.inicio at time zone 'America/Bogota', 'HH24:MI'),
           'fin', to_char(w.fin at time zone 'America/Bogota', 'HH24:MI'),
           'revisado', to_char(w.revisado at time zone 'America/Bogota', 'HH24:MI'))
    from public.vigilancia_viajes w where w.regid = p_regid;
$$;
revoke all on function public._vig_viaje_json(bigint) from public, anon, authenticated;

create or replace function public.vigilancia_caso(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare c public.vigilancia_casos;
begin
  select * into c from public.vigilancia_casos where id = p_id and estado in ('ABIERTO', 'CERRADO');
  if c.id is null or not public._vig_puede(c.ruta, c.ruta_mapa) then
    return jsonb_build_object('ok', false, 'error', 'No se encontró el caso.');
  end if;
  return jsonb_build_object('ok', true,
    'caso', to_jsonb(c) - 'ruta_mapa' - 'it_id'
            || jsonb_build_object(
                 'desde_h', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'),
                 'hasta_h', to_char(coalesce(c.hasta, c.visto_en) at time zone 'America/Bogota', 'HH24:MI'),
                 'sale', to_char(c.inicio_viaje at time zone 'America/Bogota', 'HH24:MI'),
                 'sale_rel', to_char(c.inicio_rel at time zone 'America/Bogota', 'HH24:MI'),
                 'auditado_h', to_char(c.auditado_en at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI'),
                 'minutos', round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60)),
    'despachos', (select coalesce(jsonb_agg(jsonb_build_object('tabla', d.tabla, 'id', d.id)), '[]'::jsonb)
                    from public._vig_despachos(c.regid) d),
    'despachos_rel', (select coalesce(jsonb_agg(jsonb_build_object('tabla', d.tabla, 'id', d.id)), '[]'::jsonb)
                        from public._vig_despachos(c.regid_rel) d),
    'viaje', public._vig_viaje_json(c.regid),
    'viaje_rel', public._vig_viaje_json(c.regid_rel),
    'mid', (select u.mid from public.ubicaciones u where btrim(u.movil) = c.movil limit 1),
    'mid_rel', (select u.mid from public.ubicaciones u where btrim(u.movil) = c.movil_rel limit 1));
end $$;
revoke all on function public.vigilancia_caso(bigint) from public, anon;
grant execute on function public.vigilancia_caso(bigint) to authenticated;

-- 5) los casos de las filas que se estan viendo --------------------------------------------------------------------
create or replace function public.vigilancia_por_viajes(p_regids text[])
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_ids bigint[];
begin
  if not ((select public.es_admin()) or (select public.es_auditor())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y monitores.');
  end if;
  select array_agg(distinct x::bigint) into v_ids from unnest(coalesce(p_regids, '{}')) x where x ~ '^[0-9]{1,18}$';
  if v_ids is null then return jsonb_build_object('ok', true, 'casos', '[]'::jsonb); end if;
  if cardinality(v_ids) > 5000 then return jsonb_build_object('ok', false, 'error', 'Demasiados viajes.'); end if;
  return jsonb_build_object('ok', true, 'casos', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'fecha', c.fecha, 'tipo', c.tipo, 'estado', c.estado, 'ruta', c.ruta,
        'movil', c.movil, 'movil_rel', c.movil_rel, 'regid', c.regid::text, 'regid_rel', c.regid_rel::text,
        'causa', c.causa,
        'desde', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'),
        'hasta', to_char(coalesce(c.hasta, c.visto_en) at time zone 'America/Bogota', 'HH24:MI'),
        'minutos', round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60),
        'sale', to_char(c.inicio_viaje at time zone 'America/Bogota', 'HH24:MI'),
        'sale_rel', to_char(c.inicio_rel at time zone 'America/Bogota', 'HH24:MI'),
        'par_total', c.par_total, 'punto_desde', c.punto_desde, 'punto_hasta', c.punto_hasta, 'max_dist', c.max_dist,
        'decision', c.decision, 'responsable', c.responsable, 'medida', c.medida,
        'viaje', public._vig_viaje_json(c.regid),
        'viaje_rel', public._vig_viaje_json(c.regid_rel),
        -- APAGADO en un "sitio de espera": misma ruta y punto con 4+ buses en 3+ dias de la ultima semana (vigClasificar)
        'espera', case when c.tipo = 'APAGADO' and c.punto_desde is not null then (
            select count(distinct x.movil) >= 4 and count(distinct x.fecha) >= 3
              from public.vigilancia_casos x
             where x.tipo = 'APAGADO' and x.ruta = c.ruta and x.punto_desde = c.punto_desde
               and x.fecha between c.fecha - 6 and c.fecha and x.estado in ('ABIERTO', 'CERRADO')) end)
        order by c.desde), '[]'::jsonb)
      from public.vigilancia_casos c
     where (c.regid = any(v_ids) or c.regid_rel = any(v_ids))
       and c.estado in ('ABIERTO', 'CERRADO')
       and public._vig_puede(c.ruta, c.ruta_mapa)));
end $$;
revoke all on function public.vigilancia_por_viajes(text[]) from public, anon;
grant execute on function public.vigilancia_por_viajes(text[]) to authenticated;
