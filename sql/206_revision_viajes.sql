-- 206: ✅ Revisión de viajes para los monitores (auditores).
-- Pedido (25/11/2026): "crear una función para revisar automáticamente los viajes que cumplan el completo; los que tienen
-- la novedad con el vigilante y el incompleto, los monitores deben colocar qué pasó con la novedad que interpretó SONAR o
-- el vigilante". Decisiones del usuario:
--   * Completo en SONAR y sin caso del vigilante → se revisa solo. Si lo único del vigilante es "probable ruido" (la misma
--     regla de la pantalla: vigRuido), también se revisa solo, con la razón anotada.
--   * Incompleto, cancelado, sin cerrar en SONAR o con un caso del vigilante que no es ruido → el monitor escribe qué pasó:
--     motivo (lista), si es falta del conductor (CONFIRMADO / JUSTIFICADO / FALSA_ALARMA, las mismas del vigilante) y una
--     nota obligatoria. La misma respuesta cierra los casos del vigilante de ese viaje (vigilancia_auditar).
--   * De cada viaje para revisar se trae de SONAR (cron, GET_ItinerariesHistory_v2) qué puntos marcó y cuáles no.
-- Todo vive en despachos_sonar (el viaje REAL de SONAR, también los despachados directo en SONAR). La revisión solo se
-- escribe por las funciones de aquí: un trigger no deja que nadie la cambie a mano (Auditoría SONAR).
-- Ensayo: scratchpad/audauto/p_206.sql (en rollback). DESHACER al final.

set lock_timeout = '5s';

-- 1) Columnas de la revisión ------------------------------------------------------------------------------------------
alter table public.despachos_sonar add column if not exists revision text;        -- AUTO | PENDIENTE | REVISADO (null = en curso)
alter table public.despachos_sonar add column if not exists revision_por text[];  -- INCOMPLETO, CANCELADO, SIN_CERRAR, VIGILANTE
alter table public.despachos_sonar add column if not exists revision_auto text;   -- por qué se revisó solo
alter table public.despachos_sonar add column if not exists motivo text;          -- qué pasó (lista de _rev_motivos)
alter table public.despachos_sonar add column if not exists decision text;        -- CONFIRMADO | JUSTIFICADO | FALSA_ALARMA
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'dsonar_revision_valida') then
    alter table public.despachos_sonar add constraint dsonar_revision_valida
      check (revision is null or revision in ('AUTO', 'PENDIENTE', 'REVISADO')) not valid;
    alter table public.despachos_sonar validate constraint dsonar_revision_valida;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'dsonar_decision_valida') then
    alter table public.despachos_sonar add constraint dsonar_decision_valida
      check (decision is null or decision in ('CONFIRMADO', 'JUSTIFICADO', 'FALSA_ALARMA')) not valid;
    alter table public.despachos_sonar validate constraint dsonar_decision_valida;
  end if;
end $$;
create index if not exists ix_dsonar_revision on public.despachos_sonar (fecha, revision);
comment on column public.despachos_sonar.revision is
  'Revisión del viaje (sql/206): AUTO = completo sin novedad; PENDIENTE = el monitor debe decir qué pasó; REVISADO = ya respondido. Solo la escriben las funciones de sql/206.';

-- 2) Lo que SONAR dice de cada punto del viaje (lo llena el cron revision_detalle_sonar) ---------------------------------
create table if not exists public.viajes_sonar_detalle (
  regid bigint primary key,                 -- = despachos_sonar.itl_id
  it_id bigint,                             -- itinerario de SONAR
  estado text not null,                     -- COMPLETO | INCOMPLETO | CANCELADO | EN_CURSO | NO_ENCONTRADO | SIN_ITINERARIO
  inicio timestamptz,
  fin timestamptz,
  puntos_total int,                         -- puntos del itinerario (itinerario_puntos)
  marcados int[],                           -- índices (desde 0) de los puntos que SONAR marcó
  tarde int[],                              -- marcados tarde (p_violation R)
  antes int[],                              -- marcados antes de la hora (p_violation A)
  atraso_fin int,                           -- minutos (p_difference) en el último punto marcado
  atraso_max int,
  salio_ruta boolean,                       -- leaveroute = Y
  cancelo_usuario boolean,                  -- userCanceled = Y
  revisado timestamptz not null default now(),
  intentos int not null default 1
);
alter table public.viajes_sonar_detalle enable row level security;   -- sin políticas: se lee por revision_viajes_dia
revoke all on public.viajes_sonar_detalle from anon, authenticated;

-- 3) Permiso: admin todo; el monitor, los viajes de SUS rutas (la misma regla de la RLS de despachos_sonar) --------------
create or replace function public._rev_puede(p_ruta text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select (select public.es_admin())
      or ((select public.es_auditor())
          and lower(btrim(coalesce(p_ruta, ''))) in (select lower(btrim(r.nombre)) from public.rutas r where r.id = any (public.rutas_auditor())));
$$;
revoke all on function public._rev_puede(text) from public, anon, authenticated;

-- Qué pasó: la lista del monitor y la decisión que propone cada motivo (el monitor la puede cambiar).
create or replace function public._rev_motivos()
returns jsonb
language sql immutable
as $$
  select '{
    "VARADO": "JUSTIFICADO", "SINIESTRO": "JUSTIFICADO", "CONGESTION": "JUSTIFICADO", "DESVIO_AUTORIZADO": "JUSTIFICADO",
    "CAMBIO_RUTA": "JUSTIFICADO", "REQUERIMIENTO": "JUSTIFICADO", "DESPACHO_ERRADO": "JUSTIFICADO",
    "NO_SALIO": "CONFIRMADO", "RECORTE": "CONFIRMADO", "ABANDONO": "CONFIRMADO", "ADELANTO": "CONFIRMADO",
    "PERDIDA_TIEMPO": "CONFIRMADO", "FALLA_GPS": "FALSA_ALARMA", "CIERRE_SONAR": "FALSA_ALARMA", "OTRO": null
  }'::jsonb;
$$;

-- 4) "Probable ruido" de un caso del vigilante: la MISMA regla de vigRuido (app.js) con el sitio de espera de
--    vigilancia_por_viajes (sql/193). null = vale la pena revisarlo.
create or replace function public._vig_ruido(c public.vigilancia_casos)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select case
    when c.tipo = 'FUERA_RUTA' then
      case when c.punto_desde is null then 'SIN_PUNTO' when c.punto_desde = 0 then 'SALIDA' when k.fin then 'TERMINO' end
    when c.tipo = 'APAGADO' then
      case when c.punto_desde is not null and (
             select count(distinct x.movil) >= 4 and count(distinct x.fecha) >= 3
               from public.vigilancia_casos x
              where x.tipo = 'APAGADO' and x.ruta = c.ruta and x.punto_desde = c.punto_desde
                and x.fecha between c.fecha - 6 and c.fecha and x.estado in ('ABIERTO', 'CERRADO')) then 'ESPERA' end
    else
      case when c.causa = 'ADELANTE_SIN_GPS' then 'SIN_GPS'
           when k.sale is not null and k.sale_rel is not null and k.sale - k.sale_rel < 5 then 'JUNTOS'
           when coalesce(k.minutos, 0) < 10 then 'CORTO'
           when k.fin then 'FINAL' end
  end
  from (select coalesce(c.par_total, 0) <> 0 and c.punto_desde is not null and c.punto_desde >= c.par_total - 3 as fin,
               (extract(hour from c.inicio_viaje at time zone 'America/Bogota') * 60
                 + extract(minute from c.inicio_viaje at time zone 'America/Bogota'))::int as sale,
               (extract(hour from c.inicio_rel at time zone 'America/Bogota') * 60
                 + extract(minute from c.inicio_rel at time zone 'America/Bogota'))::int as sale_rel,
               round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60) as minutos) k;
$$;
revoke all on function public._vig_ruido(public.vigilancia_casos) from public, anon, authenticated;

-- Casos del vigilante que tocan un viaje: los del bus y, en un adelantamiento que el vigilante achaca al de adelante
-- (causa ADELANTE_*), también el viaje del de adelante.
create or replace function public._rev_casos(p_regid bigint)
returns setof public.vigilancia_casos
language sql stable security definer set search_path to 'public'
as $$
  select c.* from public.vigilancia_casos c
   where c.regid = p_regid and c.estado in ('ABIERTO', 'CERRADO')
  union
  select c.* from public.vigilancia_casos c
   where c.regid_rel = p_regid and c.estado in ('ABIERTO', 'CERRADO') and c.tipo = 'ADELANTAMIENTO' and c.causa like 'ADELANTE%';
$$;
revoke all on function public._rev_casos(bigint) from public, anon, authenticated;

-- 5) Nadie cambia la revisión a mano: solo las funciones de aquí (app.revision) o la base misma (cron, sin sesión) ---------
create or replace function public.trg_dsonar_revision()
returns trigger
language plpgsql
as $$
begin
  if auth.uid() is null or coalesce(current_setting('app.revision', true), '') = 'si' then return new; end if;
  if new.auditado is distinct from old.auditado or new.auditor_email is distinct from old.auditor_email
     or new.auditado_en is distinct from old.auditado_en or new.revision is distinct from old.revision
     or new.revision_por is distinct from old.revision_por or new.revision_auto is distinct from old.revision_auto
     or new.motivo is distinct from old.motivo or new.decision is distinct from old.decision then
    raise exception 'La revisión del viaje se hace en ✅ Revisión de viajes: ahí se escribe qué pasó.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists trg_dsonar_revision on public.despachos_sonar;
create trigger trg_dsonar_revision before update on public.despachos_sonar
  for each row execute function public.trg_dsonar_revision();

-- 6) La revisión automática (cron cada 10 min: hoy y ayer; el admin la puede correr para otro día) -----------------------
create or replace function public.revision_viajes_auto(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_ahora timestamp := (now() at time zone 'America/Bogota');
  v_desde date := coalesce(p_desde, (now() at time zone 'America/Bogota')::date - 1);
  v_hasta date := coalesce(p_hasta, (now() at time zone 'America/Bogota')::date);
  n_auto int := 0; n_pend int := 0; n_caso int := 0; n_curso int := 0; n_manual int := 0;
begin
  if auth.uid() is not null and not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración.');
  end if;
  if v_hasta < v_desde or v_hasta - v_desde > 31 then
    return jsonb_build_object('ok', false, 'error', 'Rango de fechas no válido (máximo 31 días).');
  end if;
  perform set_config('app.revision', 'si', true);

  -- casos del vigilante de los viajes por revisar, con su "probable ruido"
  create temp table if not exists _rv_k (itl_id bigint, caso bigint, ruido text, decision text, auditado_por text,
                                         auditado_en timestamptz, nota text) on commit drop;
  truncate _rv_k;
  insert into _rv_k
  select t.itl_id, c.id, public._vig_ruido(c), c.decision, c.auditado_por, c.auditado_en, c.nota
    from public.despachos_sonar t
    join public.vigilancia_casos c on c.regid = t.itl_id and c.estado in ('ABIERTO', 'CERRADO')
   where t.fecha between v_desde and v_hasta and t.revision is distinct from 'REVISADO'
  union
  select t.itl_id, c.id, public._vig_ruido(c), c.decision, c.auditado_por, c.auditado_en, c.nota
    from public.despachos_sonar t
    join public.vigilancia_casos c on c.regid_rel = t.itl_id and c.estado in ('ABIERTO', 'CERRADO')
                                  and c.tipo = 'ADELANTAMIENTO' and c.causa like 'ADELANTE%'
   where t.fecha between v_desde and v_hasta and t.revision is distinct from 'REVISADO';

  create temp table if not exists _rv (itl_id bigint primary key, nueva text, por text[], auto_txt text, caso_dec text,
                                       caso_por text, caso_en timestamptz, caso_nota text) on commit drop;
  truncate _rv;
  insert into _rv
  select x.itl_id,
         case when x.manual then 'MANUAL'
              when x.estado = 'Completo' and cardinality(x.por) = 0 then 'AUTO'
              when x.estado = 'Completo' and x.por = array['VIGILANTE'] and x.sin_decidir = 0 then 'CASO'
              when cardinality(x.por) > 0 then 'PENDIENTE'
         end,
         x.por,
         case when x.ruidos is null then 'Completo en SONAR y sin novedad del vigilante.'
              else 'Completo en SONAR; lo que vio el vigilante es probable ruido ('
                   || (select string_agg(case q
                         when 'SIN_PUNTO' then 'el bus no iba haciendo la ruta'
                         when 'SALIDA' then 'en la salida, antes de arrancar'
                         when 'TERMINO' then 'ya había terminado el recorrido'
                         when 'ESPERA' then 'sitio de espera de muchos buses'
                         when 'JUNTOS' then 'salieron casi juntos'
                         when 'CORTO' then 'duró menos de 10 min'
                         when 'FINAL' then 'llegando al final'
                         when 'SIN_GPS' then 'el de adelante no tenía GPS'
                         else lower(q) end, '; ' order by q)
                       from unnest(string_to_array(x.ruidos, ',')) q) || ').' end,
         (select k.decision from _rv_k k where k.itl_id = x.itl_id and k.ruido is null and k.decision is not null
           order by case k.decision when 'CONFIRMADO' then 1 when 'JUSTIFICADO' then 2 else 3 end limit 1),
         (select k.auditado_por from _rv_k k where k.itl_id = x.itl_id and k.ruido is null and k.decision is not null
           order by k.auditado_en desc nulls last limit 1),
         (select max(k.auditado_en) from _rv_k k where k.itl_id = x.itl_id and k.ruido is null and k.decision is not null),
         (select string_agg(k.nota, ' · ' order by k.auditado_en) from _rv_k k
           where k.itl_id = x.itl_id and k.ruido is null and k.decision is not null and coalesce(k.nota, '') <> '')
    from (
      select t.itl_id, t.estado,
             (t.revision is null and t.auditado) as manual,     -- auditado a mano antes de sql/206: se respeta
             array_remove(array[
               case when t.estado = 'Incompleto' then 'INCOMPLETO' end,
               case when t.estado = 'Cancelado' then 'CANCELADO' end,
               case when t.estado = 'En progreso'
                     and (t.fecha < v_hoy or t.fecha + coalesce(t.hora_inicio, time '00:00') < v_ahora - interval '4 hours')
                    then 'SIN_CERRAR' end,
               case when exists (select 1 from _rv_k k where k.itl_id = t.itl_id and k.ruido is null) then 'VIGILANTE' end
             ], null) as por,
             (select count(*) from _rv_k k where k.itl_id = t.itl_id and k.ruido is null and k.decision is null) as sin_decidir,
             (select string_agg(distinct k.ruido, ',') from _rv_k k where k.itl_id = t.itl_id and k.ruido is not null) as ruidos
        from public.despachos_sonar t
       where t.fecha between v_desde and v_hasta and t.revision is distinct from 'REVISADO') x;

  -- a) auditado a mano antes de sql/206
  update public.despachos_sonar d set revision = 'REVISADO', revision_por = coalesce(d.revision_por, '{}')
    from _rv v where v.itl_id = d.itl_id and v.nueva = 'MANUAL' and d.revision is null and d.auditado;
  get diagnostics n_manual = row_count;

  -- b) completo y sin novedad (o solo ruido del vigilante): se revisa solo
  update public.despachos_sonar d
     set revision = 'AUTO', revision_por = '{}', motivo = null, decision = null, revision_auto = v.auto_txt,
         auditado = true, auditor_email = 'revisión automática',
         auditado_en = case when d.revision = 'AUTO' then d.auditado_en else now() end
    from _rv v
   where v.itl_id = d.itl_id and v.nueva = 'AUTO' and d.revision is distinct from 'REVISADO'
     and (d.revision is distinct from 'AUTO' or d.revision_auto is distinct from v.auto_txt);
  get diagnostics n_auto = row_count;

  -- c) completo cuya única novedad son casos del vigilante YA respondidos (en la fila, en el vigilante o desde otro viaje)
  update public.despachos_sonar d
     set revision = 'REVISADO', revision_por = v.por, revision_auto = null, motivo = 'CASO_VIGILANTE', decision = v.caso_dec,
         observacion = coalesce(nullif(btrim(d.observacion), ''), v.caso_nota),
         auditado = true, auditor_email = coalesce(nullif(v.caso_por, ''), 'caso del vigilante'), auditado_en = coalesce(v.caso_en, now())
    from _rv v
   where v.itl_id = d.itl_id and v.nueva = 'CASO' and d.revision is distinct from 'REVISADO';
  get diagnostics n_caso = row_count;

  -- d) para el monitor
  update public.despachos_sonar d
     set revision = 'PENDIENTE', revision_por = v.por, revision_auto = null,
         auditado = false, auditor_email = null, auditado_en = null
    from _rv v
   where v.itl_id = d.itl_id and v.nueva = 'PENDIENTE' and d.revision is distinct from 'REVISADO'
     and (d.revision is distinct from 'PENDIENTE' or d.revision_por is distinct from v.por);
  get diagnostics n_pend = row_count;

  -- e) todavía en curso (o volvió a estarlo): sin revisión
  update public.despachos_sonar d
     set revision = null, revision_por = null, revision_auto = null, auditado = false, auditor_email = null, auditado_en = null
    from _rv v
   where v.itl_id = d.itl_id and v.nueva is null and d.revision in ('AUTO', 'PENDIENTE');
  get diagnostics n_curso = row_count;

  return jsonb_build_object('ok', true, 'desde', v_desde, 'hasta', v_hasta, 'auto', n_auto, 'pendientes', n_pend,
                            'por_caso', n_caso, 'en_curso', n_curso, 'manual', n_manual);
end $fn$;
revoke all on function public.revision_viajes_auto(date, date) from public, anon;
grant execute on function public.revision_viajes_auto(date, date) to authenticated;   -- adentro: solo admin
alter function public.revision_viajes_auto(date, date) set statement_timeout = '60s';

-- 7) Lo que dijo SONAR de cada punto, para los viajes por revisar (cron cada 5 min) --------------------------------------
--    Una llamada GET_ItinerariesHistory_v2 por itinerario y franja de 2 horas de salida (SONAR filtra por la hora de
--    SALIDA, comprobado en sql/193). Los puntos que no marcó NO vienen: se sacan contra itinerario_puntos.
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
       where ds.revision = 'PENDIENTE' and ds.fecha >= v_hoy - 7 and ds.hora_inicio is not null
         and (w.regid is null
              or (w.estado not in ('COMPLETO', 'INCOMPLETO', 'CANCELADO', 'SIN_ITINERARIO')
                  and w.revisado < now() - interval '10 minutes' and w.intentos < 20)))
    select p.it_id, date_trunc('hour', p.ini) - make_interval(hours => extract(hour from p.ini)::int % 2) as bloque,
           min(p.ini) as ini_min, max(p.ini) as ini_max, array_agg(p.regid) as regids
      from p group by 1, 2 order by min(p.ini) limit p_max
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

-- 8) La pantalla: los viajes de un día con lo que dijo SONAR y lo que vio el vigilante -----------------------------------
--    p_grupo: PENDIENTE | REVISADO | AUTO | SIN (en curso) | TODOS. El resumen siempre cuenta el día entero.
create or replace function public.revision_viajes_dia(p_fecha date, p_grupo text default 'PENDIENTE')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_grupo text := upper(coalesce(p_grupo, 'PENDIENTE'));
  v_admin boolean := (select public.es_admin());
  v_rutas text[];
  v_res jsonb; v_viajes jsonb;
begin
  if not (v_admin or (select public.es_auditor())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y monitores.');
  end if;
  -- las rutas del monitor una sola vez (la misma regla de _rev_puede)
  if not v_admin then
    select coalesce(array_agg(lower(btrim(r.nombre))), '{}') into v_rutas from public.rutas r where r.id = any (public.rutas_auditor());
  end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Elige la fecha.'); end if;
  if v_grupo not in ('PENDIENTE', 'REVISADO', 'AUTO', 'SIN', 'TODOS') then
    return jsonb_build_object('ok', false, 'error', 'Grupo no válido.');
  end if;

  select jsonb_build_object(
           'total', count(*),
           'auto', count(*) filter (where d.revision = 'AUTO'),
           'pendiente', count(*) filter (where d.revision = 'PENDIENTE'),
           'revisado', count(*) filter (where d.revision = 'REVISADO'),
           'sin', count(*) filter (where d.revision is null),
           'incompleto', count(*) filter (where d.revision = 'PENDIENTE' and 'INCOMPLETO' = any (d.revision_por)),
           'vigilante', count(*) filter (where d.revision = 'PENDIENTE' and 'VIGILANTE' = any (d.revision_por)),
           'sin_cerrar', count(*) filter (where d.revision = 'PENDIENTE' and 'SIN_CERRAR' = any (d.revision_por)),
           'cancelado', count(*) filter (where d.revision = 'PENDIENTE' and 'CANCELADO' = any (d.revision_por)),
           'confirmados', count(*) filter (where d.revision = 'REVISADO' and d.decision = 'CONFIRMADO'),
           'auto_ruido', count(*) filter (where d.revision = 'AUTO' and d.revision_auto like '%probable ruido%'))
    into v_res
    from public.despachos_sonar d
   where d.fecha = p_fecha and (v_admin or lower(btrim(coalesce(d.ruta, ''))) = any (v_rutas));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.itl_id::text, 'fecha', d.fecha, 'hora', left(d.hora_inicio::text, 5), 'ruta', d.ruta, 'movil', d.movil,
           'placa', d.placa, 'conductor', d.conductor, 'mid', d.mid, 'estado', d.estado,
           'revision', d.revision, 'por', coalesce(to_jsonb(d.revision_por), '[]'::jsonb), 'auto', d.revision_auto,
           'motivo', d.motivo, 'decision', d.decision, 'nota', d.observacion,
           'quien', case when d.revision = 'REVISADO' then d.auditor_email end,
           'cuando', case when d.revision = 'REVISADO' then to_char(d.auditado_en at time zone 'America/Bogota', 'DD/MM HH24:MI') end,
           'det', case when w.regid is not null then jsonb_build_object(
               'estado', w.estado,
               'inicio', to_char(w.inicio at time zone 'America/Bogota', 'HH24:MI'),
               'fin', to_char(w.fin at time zone 'America/Bogota', 'HH24:MI'),
               'seg', round(extract(epoch from w.fin - w.inicio)),
               'total', w.puntos_total, 'marcados', cardinality(coalesce(w.marcados, '{}')),
               'faltan', (select coalesce(jsonb_agg(jsonb_build_object('i', ip.point_index, 'n', ip.geofence_name) order by ip.point_index), '[]'::jsonb)
                            from public.itinerario_puntos ip
                           where ip.it_id = w.it_id and not (ip.point_index = any (coalesce(w.marcados, '{}')))),
               'ultimo', (select jsonb_build_object('i', ip.point_index, 'n', ip.geofence_name)
                            from public.itinerario_puntos ip
                           where ip.it_id = w.it_id and ip.point_index = (select max(m) from unnest(w.marcados) m)),
               'tarde', cardinality(coalesce(w.tarde, '{}')), 'antes', cardinality(coalesce(w.antes, '{}')),
               'atraso_fin', w.atraso_fin, 'atraso_max', w.atraso_max,
               'salio_ruta', w.salio_ruta, 'cancelo_usuario', w.cancelo_usuario,
               'revisado', to_char(w.revisado at time zone 'America/Bogota', 'HH24:MI')) end,
           'casos', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', c.id, 'fecha', c.fecha, 'tipo', c.tipo, 'estado', c.estado, 'ruta', c.ruta,
                 'movil', c.movil, 'movil_rel', c.movil_rel, 'regid', c.regid::text, 'regid_rel', c.regid_rel::text,
                 'rol', case when c.regid = d.itl_id then 'PROPIO' else 'ADELANTE' end,
                 'causa', c.causa,
                 'desde', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'),
                 'hasta', to_char(coalesce(c.hasta, c.visto_en) at time zone 'America/Bogota', 'HH24:MI'),
                 'minutos', round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60),
                 'sale', to_char(c.inicio_viaje at time zone 'America/Bogota', 'HH24:MI'),
                 'sale_rel', to_char(c.inicio_rel at time zone 'America/Bogota', 'HH24:MI'),
                 'par_total', c.par_total, 'punto_desde', c.punto_desde, 'punto_hasta', c.punto_hasta, 'max_dist', c.max_dist,
                 'decision', c.decision, 'responsable', c.responsable, 'nota', c.nota, 'auditado_por', c.auditado_por,
                 'ruido', public._vig_ruido(c)) order by c.desde), '[]'::jsonb)
               from public._rev_casos(d.itl_id) c)
         ) order by d.hora_inicio, d.ruta, d.movil), '[]'::jsonb)
    into v_viajes
    from public.despachos_sonar d
    left join public.viajes_sonar_detalle w on w.regid = d.itl_id
   where d.fecha = p_fecha and (v_admin or lower(btrim(coalesce(d.ruta, ''))) = any (v_rutas))
     and (v_grupo = 'TODOS' or (v_grupo = 'SIN' and d.revision is null) or d.revision = v_grupo);

  return jsonb_build_object('ok', true, 'fecha', p_fecha, 'grupo', v_grupo, 'resumen', v_res, 'viajes', v_viajes,
                            'motivos', public._rev_motivos(), 'admin', (select public.es_admin()));
end $fn$;
revoke all on function public.revision_viajes_dia(date, text) from public, anon;
grant execute on function public.revision_viajes_dia(date, text) to authenticated;

-- 9) El monitor responde qué pasó. Cierra también los casos del vigilante del viaje (vigilancia_auditar), todo o nada. ---
--    p_casos: [{"id": <caso>, "decision": "CONFIRMADO|JUSTIFICADO|FALSA_ALARMA", "responsable": "ADELANTE|ATRAS"}]
create or replace function public.revisar_viaje(p_itl_id bigint, p_motivo text, p_decision text, p_nota text,
                                                p_casos jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  d public.despachos_sonar; c public.vigilancia_casos; e jsonb; r jsonb;
  v_motivo text := upper(btrim(coalesce(p_motivo, '')));
  v_dec text := upper(btrim(coalesce(p_decision, '')));
  v_nota text := btrim(coalesce(p_nota, ''));
  v_admin boolean := (select public.es_admin());
  v_n int := 0;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  select * into d from public.despachos_sonar where itl_id = p_itl_id for update;
  if d.itl_id is null or not public._rev_puede(d.ruta) then
    return jsonb_build_object('ok', false, 'error', 'No se encontró el viaje.');
  end if;
  if d.revision is distinct from 'PENDIENTE' and not (v_admin and d.revision = 'REVISADO') then
    return jsonb_build_object('ok', false, 'error', case
      when d.revision = 'REVISADO' then 'Este viaje ya lo revisó ' || coalesce(d.auditor_email, 'otra persona') || '.'
      when d.revision = 'AUTO' then 'Este viaje se revisó solo: terminó completo y sin novedad.'
      else 'Este viaje todavía está en curso: se revisa cuando SONAR lo cierre.' end);
  end if;
  if not (public._rev_motivos() ? v_motivo) then
    return jsonb_build_object('ok', false, 'error', 'Elige qué pasó.');
  end if;
  if v_dec not in ('CONFIRMADO', 'JUSTIFICADO', 'FALSA_ALARMA') then
    return jsonb_build_object('ok', false, 'error', 'Di si es falta del conductor, si se justifica o si no pasó.');
  end if;
  if char_length(v_nota) < 10 then
    return jsonb_build_object('ok', false, 'error', 'Escribe qué pasó (mínimo 10 letras).');
  end if;
  if jsonb_typeof(coalesce(p_casos, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'Respuesta de los casos no válida.');
  end if;

  perform set_config('app.revision', 'si', true);
  begin
    for c in select * from public._rev_casos(d.itl_id) order by desde loop
      e := null;
      select x.value into e from jsonb_array_elements(coalesce(p_casos, '[]'::jsonb)) as x where (x.value ->> 'id') = c.id::text limit 1;
      -- un caso ya respondido solo lo cambia el admin; los que no son ruido hay que responderlos todos
      if c.decision is not null and not v_admin then continue; end if;
      if e is null then
        if c.decision is null and public._vig_ruido(c) is null then
          raise exception 'Falta responder el caso del vigilante de las %.', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI')
            using errcode = 'P0001';
        end if;
        continue;
      end if;
      r := public.vigilancia_auditar(c.id, e ->> 'decision', e ->> 'responsable', null, v_nota);
      if not coalesce((r ->> 'ok')::boolean, false) then
        raise exception 'Caso del vigilante de las %: %', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'), r ->> 'error'
          using errcode = 'P0001';
      end if;
      v_n := v_n + 1;
    end loop;

    update public.despachos_sonar
       set revision = 'REVISADO', motivo = v_motivo, decision = v_dec, observacion = v_nota, revision_auto = null,
           auditado = true, auditor_email = lower(coalesce(auth.email(), '')), auditado_en = now()
     where itl_id = d.itl_id;
  exception when sqlstate 'P0001' then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  return jsonb_build_object('ok', true, 'casos', v_n);
end $fn$;
revoke all on function public.revisar_viaje(bigint, text, text, text, jsonb) from public, anon;
grant execute on function public.revisar_viaje(bigint, text, text, text, jsonb) to authenticated;

-- 10) Crons (sql/120: con techo propio arriba) ---------------------------------------------------------------------------
select cron.unschedule('revision-viajes-auto') where exists (select 1 from cron.job where jobname = 'revision-viajes-auto');
select cron.schedule('revision-viajes-auto', '7-57/10 * * * *', $cron$select public.revision_viajes_auto()$cron$);
select cron.unschedule('revision-detalle-sonar') where exists (select 1 from cron.job where jobname = 'revision-detalle-sonar');
select cron.schedule('revision-detalle-sonar', '1-56/5 * * * *', $cron$select public.revision_detalle_sonar()$cron$);

notify pgrst, 'reload schema';

-- DESHACER (si hiciera falta):
--   select cron.unschedule('revision-viajes-auto'); select cron.unschedule('revision-detalle-sonar');
--   drop trigger if exists trg_dsonar_revision on public.despachos_sonar;
--   drop function if exists public.revisar_viaje(bigint, text, text, text, jsonb), public.revision_viajes_dia(date, text),
--     public.revision_detalle_sonar(int), public.revision_viajes_auto(date, date), public.trg_dsonar_revision(),
--     public._rev_casos(bigint), public._vig_ruido(public.vigilancia_casos), public._rev_motivos(), public._rev_puede(text);
--   drop table if exists public.viajes_sonar_detalle;
--   update public.despachos_sonar set auditado = false, auditor_email = null, auditado_en = null where revision is not null;
--   alter table public.despachos_sonar drop column revision, drop column revision_por, drop column revision_auto,
--     drop column motivo, drop column decision;   (la observación del monitor queda en observacion)
