-- ===================================================================================
-- 172: VIGILANTE DE RUTA · ADELANTAMIENTOS, APAGADOS EN RUTA Y ABANDONOS (KMZ)
-- ===================================================================================
-- Pedido del 05/11/2026: "cada despacho tiene un vehículo que va detrás que lo sigue; necesitamos
-- un vigilante que ayude a verificar si el carro que va adelante se lo adelantó el de atrás o si es
-- que el de adelante se varó porque está apagado, y los abandonos de ruta con los KMZ. Con eso
-- tomaríamos medidas sobre el cumplimiento: investigar, auditar y gestionar".
--
-- DECISIONES DEL USUARIO (AskUserQuestion, 05/11/2026):
--   * Todas las rutas que tienen trazo KMZ (rutas_recorrido, sql/35).
--   * Investigan, auditan y gestionan los AUDITORES (sus rutas, misma regla del mapa) y el admin.
--   * Al CONFIRMAR un caso se marca el despacho de ese viaje con los campos que ya existen.
--
-- DE DÓNDE SALE (nada llama a SONAR: solo tablas que ya refrescan otros crons):
--   moviles_operacion  los buses con viaje en curso, su itinerario, la hora en que salieron y el
--                      punto de control por el que van (par_idx, cron de sql/21 cada 2 min).
--   ubicaciones        la última posición, la velocidad y el MOTOR (Encendido/Apagado), cada minuto.
--   rutas_recorrido    el trazo autorizado (KMZ) para medir qué tan lejos va el bus de su ruta.
-- El de atrás es el que salió después en el MISMO itinerario (el siguiente despacho de la tabla).
--
-- LOS TRES CASOS (umbrales iniciales; se calibran con lo que vaya saliendo, como en sql/137):
--   ADELANTAMIENTO  el de atrás va en un punto de control MAYOR que el de adelante, 4 min seguidos.
--                   La causa probable sale del estado del de adelante en ese momento:
--                   ADELANTE_APAGADO (motor apagado: ¿se varó?), ADELANTE_FUERA_RUTA (se salió del
--                   trazo), ADELANTE_SIN_GPS, ADELANTE_SIN_AVANCE (sigue en el punto 0, la salida) o
--                   ATRAS_ADELANTO (el de adelante iba normal: el de atrás se lo adelantó).
--                   Si SONAR no tiene el punto del de adelante (par_idx vacío) no se abre nada: sin
--                   ese dato no se sabe quién va adelante (el 05/11 era la mitad de los "casos").
--   APAGADO         motor apagado 10 min seguidos con el viaje abierto y ya pasado el primer punto
--                   (antes del primer punto es la espera de la salida).
--   FUERA_RUTA      a más de 300 m del trazo KMZ, 6 min seguidos, con GPS fresco (≤ 5 min).
-- Un caso nace como CANDIDATO; si dura el umbral pasa a ABIERTO (lo que ve el auditor) y se CIERRA
-- solo cuando deja de verse 6 minutos. Los candidatos que no maduran se borran: un desvío de un
-- minuto no llena la pantalla.
--
-- AL CONFIRMAR (vigilancia_auditar), en el despacho del viaje (Despachos o la tabla de puesto, por
-- sonar_regid = regId de SONAR):
--   FUERA_RUTA                       → abandono_ruta = true
--   APAGADO                          → perdida_deliberada_tiempo = true
--   ADELANTAMIENTO, culpa adelante   → perdida_deliberada_tiempo = true en el viaje del de adelante
--   ADELANTAMIENTO, culpa atrás      → novedad 'ADELANTADO' en el viaje del de atrás (si no tenía otra)
-- Se guarda qué se marcó; si el auditor cambia la decisión, se deshace lo que el vigilante puso.
-- Si el viaje no tiene despacho en la app (se despachó directo en SONAR), el caso queda auditado
-- sin marcar nada y se dice.
-- ===================================================================================

-- 1) Los casos ------------------------------------------------------------------------------------
create table if not exists public.vigilancia_casos (
  id            bigserial primary key,
  fecha         date not null default (now() at time zone 'America/Bogota')::date,
  tipo          text not null check (tipo in ('ADELANTAMIENTO', 'APAGADO', 'FUERA_RUTA')),
  estado        text not null default 'CANDIDATO' check (estado in ('CANDIDATO', 'ABIERTO', 'CERRADO')),
  ruta          text,             -- como la nombra SONAR
  ruta_mapa     text,             -- como la etiqueta ubicaciones (para el permiso del auditor)
  kmz           text,             -- código del trazo en rutas_recorrido
  it_id         bigint,
  movil         text not null,    -- el bus del caso (en ADELANTAMIENTO, el de atrás)
  regid         bigint,           -- su viaje en SONAR
  inicio_viaje  timestamptz,
  movil_rel     text,             -- en ADELANTAMIENTO, el de adelante
  regid_rel     bigint,
  inicio_rel    timestamptz,
  causa         text,
  causas        text[] not null default '{}',   -- todas las que se vieron mientras duró
  desde         timestamptz not null default now(),
  visto_en      timestamptz not null default now(),
  hasta         timestamptz,
  lecturas      int not null default 1,
  par_total     int,
  punto_desde   int,
  punto_hasta   int,
  max_dist      int,
  evidencia     jsonb not null default '[]'::jsonb,  -- una lectura cada 2 min (máx. 150)
  decision      text check (decision in ('CONFIRMADO', 'JUSTIFICADO', 'FALSA_ALARMA')),
  responsable   text check (responsable in ('ADELANTE', 'ATRAS', 'NINGUNO')),
  medida        text,
  nota          text,
  auditado_por  text,
  auditado_en   timestamptz,
  marcado       jsonb not null default '[]'::jsonb   -- [{tabla, id, campo}] lo que el vigilante marcó
);
comment on table public.vigilancia_casos is 'Vigilante de ruta (sql/172): adelantamientos, apagados en ruta y salidas del trazo KMZ.';

-- Un solo caso vivo por situación: sin esto el cron abriría uno cada 2 minutos.
create unique index if not exists vigilancia_un_caso_vivo
  on public.vigilancia_casos (tipo, movil, coalesce(regid, 0), coalesce(movil_rel, ''))
  where estado in ('CANDIDATO', 'ABIERTO');
create index if not exists vigilancia_casos_fecha on public.vigilancia_casos (fecha, estado);

-- Nadie lee la tabla directo: todo pasa por las funciones de abajo, que validan el rol.
alter table public.vigilancia_casos enable row level security;

-- 2) Ayudantes ------------------------------------------------------------------------------------
-- El trazo KMZ de una ruta de SONAR: por código exacto ('135I' → '135i'), por el primer pedazo del
-- nombre ('287 AB-26' → '287') o, solo si no es un código (no empieza por número), por el nombre del
-- trazo ('Circular Sur' → 'CIRCULAR SUR IZQUIERDA 302'). Sin esa condición '133ii' tomaba el trazo
-- de la '133iiA', que es otra variante, y la mostraba fuera de ruta.
create or replace function public._vig_kmz(p_ruta text)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(
    (select codigo from public.rutas_recorrido where lower(codigo) = lower(btrim(p_ruta)) limit 1),
    (select codigo from public.rutas_recorrido where lower(codigo) = lower(split_part(btrim(p_ruta), ' ', 1)) limit 1),
    (select codigo from public.rutas_recorrido
      where btrim(coalesce(p_ruta, '')) !~ '^\d' and length(btrim(p_ruta)) >= 5
        and nombre ilike '%' || btrim(p_ruta) || '%'
      order by codigo limit 1));
$$;
revoke all on function public._vig_kmz(text) from public, anon, authenticated;

-- Distancia en metros de un punto al segmento A-B, en plano local (a escala de ciudad sobra).
create or replace function public._vig_dist_seg(p_la float8, p_lo float8, a_la float8, a_lo float8, b_la float8, b_lo float8)
returns float8
language sql immutable
as $$
  select 6371000 * radians(sqrt(
      power((p_lo - a_lo) * cos(radians(p_la)) - t * (b_lo - a_lo) * cos(radians(p_la)), 2)
    + power((p_la - a_la) - t * (b_la - a_la), 2)))
    from (select coalesce(greatest(0, least(1,
            ((p_lo - a_lo) * (b_lo - a_lo) * power(cos(radians(p_la)), 2) + (p_la - a_la) * (b_la - a_la))
            / nullif(power((b_lo - a_lo) * cos(radians(p_la)), 2) + power(b_la - a_la, 2), 0))), 0) t) x;
$$;
revoke all on function public._vig_dist_seg(float8, float8, float8, float8, float8, float8) from public, anon, authenticated;

-- Los despachos de la app que son ese viaje de SONAR (Despachos y todas las tablas de puesto).
create or replace function public._vig_despachos(p_regid bigint)
returns table (tabla text, id text)
language plpgsql stable security definer set search_path to 'public'
as $$
declare t text;
begin
  if p_regid is null then return; end if;
  for t in
    select c.table_name from information_schema.columns c
      join information_schema.tables tb on tb.table_schema = c.table_schema and tb.table_name = c.table_name
     where c.table_schema = 'public' and tb.table_type = 'BASE TABLE' and c.column_name = 'sonar_regid'
       and exists (select 1 from information_schema.columns c2 where c2.table_schema = 'public'
                    and c2.table_name = c.table_name and c2.column_name = 'abandono_ruta')
     order by 1
  loop
    return query execute format('select %L::text, id::text from public.%I where sonar_regid = $1', t, t)
      using p_regid::text;
  end loop;
end $$;
revoke all on function public._vig_despachos(bigint) from public, anon, authenticated;

-- ¿Este usuario puede ver/auditar el caso? Admin todo; auditor, sus rutas (misma regla del mapa).
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

-- 3) El vigilante. Lo corre el cron cada 2 minutos; no lo llama nadie desde la app. ----------------
create or replace function public.vigilante_ruta(
  p_min_apagado int default 10, p_min_fuera int default 6, p_min_adelanto int default 4, p_dist int default 300)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_op int; v_cerrados int; v_borrados int; v_nuevos int; v_abiertos int;
  v_t text := to_char(now() at time zone 'America/Bogota', 'HH24:MI');
begin
  if not pg_try_advisory_xact_lock(724172) then
    return jsonb_build_object('ok', true, 'nota', 'otra corrida en curso');
  end if;

  -- Los buses en viaje (lo que dice SONAR) con su última posición y su motor.
  drop table if exists _vop;
  create temp table _vop on commit drop as
  select btrim(m.movil) movil, m.ruta, u.ruta ruta_mapa, public._vig_kmz(m.ruta) kmz, m.it_id, m.regid, m.inicio,
         m.par_idx idx, m.par_total, m.atraso, m.ultima_parada parada,
         u.latitude lat, u.longitude lon, u.speed vel, u.motor, (u.gps_gmt at time zone 'UTC') gps,
         null::int dist
    from public.moviles_operacion m
    left join public.ubicaciones u on btrim(coalesce(u.movil, '')) = btrim(m.movil)
   where btrim(coalesce(m.movil, '')) <> '' and m.inicio is not null
     and (m.inicio at time zone 'America/Bogota')::date = (now() at time zone 'America/Bogota')::date
     and m.inicio > now() - interval '4 hours';
  get diagnostics v_op = row_count;

  -- Guardia: si SONAR respondió mal y vino casi vacío, no se abre ni se cierra nada.
  if v_op < 5 then
    return jsonb_build_object('ok', true, 'en_viaje', v_op, 'nota', 'muy pocos buses en viaje: no se vigila');
  end if;

  -- Qué tan lejos va cada bus de su trazo KMZ (solo con GPS fresco).
  update _vop o set dist = s.d
    from (select o2.movil, round(min(public._vig_dist_seg(o2.lat, o2.lon,
                   (p.v->>0)::float8, (p.v->>1)::float8, (p.n->>0)::float8, (p.n->>1)::float8)))::int d
            from _vop o2
            join lateral (select e.v, lead(e.v) over (order by e.i) n
                            from public.rutas_recorrido r, jsonb_array_elements(r.puntos) with ordinality e(v, i)
                           where r.codigo = o2.kmz) p on p.n is not null
           where o2.kmz is not null and o2.lat is not null and o2.gps > now() - interval '5 minutes'
           group by o2.movil) s
   where s.movil = o.movil;

  -- Lo que se ve en esta pasada.
  drop table if exists _vc;
  create temp table _vc on commit drop as
  with l as (
    select o.*, lag(o.movil) over w r_movil, lag(o.regid) over w r_regid, lag(o.inicio) over w r_inicio,
           lag(o.idx) over w r_idx, lag(o.motor) over w r_motor, lag(o.dist) over w r_dist,
           lag(o.vel) over w r_vel, lag(o.atraso) over w r_atraso, lag(o.gps) over w r_gps,
           lag(o.lat) over w r_lat, lag(o.lon) over w r_lon
      from _vop o
     where coalesce(o.it_id, 0) <> 0
    window w as (partition by o.it_id order by o.inicio, o.movil))
  select 'APAGADO'::text tipo, o.movil, o.regid, null::text movil_rel, null::bigint regid_rel,
         null::timestamptz inicio_rel, null::text causa, o.idx, o.dist,
         jsonb_build_object('t', v_t, 'lat', o.lat, 'lon', o.lon, 'idx', o.idx, 'vel', o.vel, 'motor', o.motor,
                            'dist', o.dist, 'atraso', o.atraso, 'parada', o.parada) lectura
    from _vop o
   where o.motor = 'Apagado' and coalesce(o.idx, 0) >= 1 and o.gps > now() - interval '30 minutes'
  union all
  select 'FUERA_RUTA', o.movil, o.regid, null, null, null, null, o.idx, o.dist,
         jsonb_build_object('t', v_t, 'lat', o.lat, 'lon', o.lon, 'idx', o.idx, 'vel', o.vel, 'motor', o.motor,
                            'dist', o.dist, 'atraso', o.atraso, 'parada', o.parada)
    from _vop o
   where o.dist > p_dist
  union all
  select 'ADELANTAMIENTO', l.movil, l.regid, l.r_movil, l.r_regid, l.r_inicio,
         case when l.r_motor = 'Apagado' then 'ADELANTE_APAGADO'
              when l.r_dist > p_dist then 'ADELANTE_FUERA_RUTA'
              when l.r_gps is null or l.r_gps < now() - interval '20 minutes' then 'ADELANTE_SIN_GPS'
              when l.r_idx = 0 then 'ADELANTE_SIN_AVANCE'
              else 'ATRAS_ADELANTO' end,
         l.idx, l.dist,
         jsonb_build_object('t', v_t, 'lat', l.lat, 'lon', l.lon, 'idx', l.idx, 'vel', l.vel, 'motor', l.motor,
                            'dist', l.dist, 'atraso', l.atraso, 'parada', l.parada,
                            'r_lat', l.r_lat, 'r_lon', l.r_lon, 'r_idx', l.r_idx, 'r_vel', l.r_vel,
                            'r_motor', l.r_motor, 'r_dist', l.r_dist, 'r_atraso', l.r_atraso)
    from l
   where l.r_movil is not null and l.idx is not null and l.r_idx is not null and l.idx > l.r_idx
     and l.inicio > l.r_inicio;

  -- Se cierra lo que dejó de verse hace más de 5 minutos (un reporte perdido no parte el caso).
  with c as (
    update public.vigilancia_casos set estado = 'CERRADO', hasta = visto_en
     where estado = 'ABIERTO' and visto_en <= now() - interval '5 minutes' returning 1)
  select count(*) into v_cerrados from c;
  with b as (
    delete from public.vigilancia_casos
     where estado = 'CANDIDATO' and visto_en <= now() - interval '5 minutes' returning 1)
  select count(*) into v_borrados from b;

  -- Lo que sigue: una lectura más de evidencia.
  update public.vigilancia_casos c
     set visto_en = now(), lecturas = c.lecturas + 1,
         evidencia = case when jsonb_array_length(c.evidencia) >= 150 then c.evidencia
                          else c.evidencia || jsonb_build_array(x.lectura) end,
         punto_hasta = coalesce(x.idx, c.punto_hasta),
         max_dist = greatest(c.max_dist, x.dist),
         causa = case when c.estado = 'CANDIDATO' then x.causa else c.causa end,
         causas = case when x.causa is null or x.causa = any (c.causas) then c.causas else c.causas || x.causa end
    from _vc x
   where c.estado in ('CANDIDATO', 'ABIERTO') and c.tipo = x.tipo and c.movil = x.movil
     and coalesce(c.regid, 0) = coalesce(x.regid, 0) and coalesce(c.movil_rel, '') = coalesce(x.movil_rel, '');

  -- Lo nuevo nace como candidato.
  with n as (
    insert into public.vigilancia_casos
      (tipo, ruta, ruta_mapa, kmz, it_id, movil, regid, inicio_viaje, movil_rel, regid_rel, inicio_rel,
       causa, causas, par_total, punto_desde, punto_hasta, max_dist, evidencia)
    select x.tipo, o.ruta, o.ruta_mapa, o.kmz, o.it_id, x.movil, x.regid, o.inicio, x.movil_rel, x.regid_rel,
           x.inicio_rel, x.causa, case when x.causa is null then '{}'::text[] else array[x.causa] end,
           o.par_total, x.idx, x.idx, x.dist, jsonb_build_array(x.lectura)
      from _vc x join _vop o on o.movil = x.movil
     where not exists (select 1 from public.vigilancia_casos c
                        where c.estado in ('CANDIDATO', 'ABIERTO') and c.tipo = x.tipo and c.movil = x.movil
                          and coalesce(c.regid, 0) = coalesce(x.regid, 0)
                          and coalesce(c.movil_rel, '') = coalesce(x.movil_rel, ''))
    on conflict do nothing
    returning 1)
  select count(*) into v_nuevos from n;

  -- Lo que ya duró el umbral pasa a ABIERTO: es lo que ve el auditor.
  with a as (
    update public.vigilancia_casos set estado = 'ABIERTO'
     where estado = 'CANDIDATO'
       and visto_en - desde >= make_interval(mins => case tipo when 'APAGADO' then p_min_apagado
                                                               when 'FUERA_RUTA' then p_min_fuera
                                                               else p_min_adelanto end)
    returning 1)
  select count(*) into v_abiertos from a;

  return jsonb_build_object('ok', true, 'en_viaje', v_op, 'vistos', (select count(*) from _vc),
    'nuevos_candidatos', v_nuevos, 'abiertos_ahora', v_abiertos, 'cerrados', v_cerrados,
    'candidatos_descartados', v_borrados,
    'abiertos', (select count(*) from public.vigilancia_casos where estado = 'ABIERTO'));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $fn$;
revoke all on function public.vigilante_ruta(int, int, int, int) from public, anon, authenticated;
-- Techo propio: corre cada 2 minutos (sql/120: un cron sin techo hereda 120 s y lo revierte todo).
alter function public.vigilante_ruta(int, int, int, int) set statement_timeout = '90s';

-- 4) Lo que ve la app -----------------------------------------------------------------------------
-- Los casos de un rango de fechas (sin la evidencia, que va en el detalle).
create or replace function public.vigilancia_listar(p_desde date, p_hasta date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not ((select public.es_admin()) or (select public.es_auditor())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y control.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 62 then
    return jsonb_build_object('ok', false, 'error', 'Elige un rango de máximo dos meses.');
  end if;
  return jsonb_build_object('ok', true, 'casos', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'fecha', c.fecha, 'tipo', c.tipo, 'estado', c.estado, 'ruta', c.ruta, 'kmz', c.kmz,
        'movil', c.movil, 'movil_rel', c.movil_rel, 'causa', c.causa, 'causas', c.causas,
        'desde', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'),
        'hasta', to_char(coalesce(c.hasta, c.visto_en) at time zone 'America/Bogota', 'HH24:MI'),
        'minutos', round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60),
        'sale', to_char(c.inicio_viaje at time zone 'America/Bogota', 'HH24:MI'),
        'sale_rel', to_char(c.inicio_rel at time zone 'America/Bogota', 'HH24:MI'),
        'par_total', c.par_total, 'punto_desde', c.punto_desde, 'punto_hasta', c.punto_hasta,
        'max_dist', c.max_dist, 'decision', c.decision, 'responsable', c.responsable, 'medida', c.medida,
        'auditado_por', c.auditado_por, 'marcado', jsonb_array_length(c.marcado))
        order by c.desde desc), '[]'::jsonb)
      from public.vigilancia_casos c
     where c.fecha between p_desde and p_hasta and c.estado in ('ABIERTO', 'CERRADO')
       and public._vig_puede(c.ruta, c.ruta_mapa)));
end $$;
revoke all on function public.vigilancia_listar(date, date) from public, anon;
grant execute on function public.vigilancia_listar(date, date) to authenticated;

-- Un caso con su evidencia y los despachos de la app que son esos viajes.
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
                 'auditado_h', to_char(c.auditado_en at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI')),
    'despachos', (select coalesce(jsonb_agg(jsonb_build_object('tabla', d.tabla, 'id', d.id)), '[]'::jsonb)
                    from public._vig_despachos(c.regid) d),
    'despachos_rel', (select coalesce(jsonb_agg(jsonb_build_object('tabla', d.tabla, 'id', d.id)), '[]'::jsonb)
                        from public._vig_despachos(c.regid_rel) d),
    'mid', (select u.mid from public.ubicaciones u where btrim(u.movil) = c.movil limit 1),
    'mid_rel', (select u.mid from public.ubicaciones u where btrim(u.movil) = c.movil_rel limit 1));
end $$;
revoke all on function public.vigilancia_caso(bigint) from public, anon;
grant execute on function public.vigilancia_caso(bigint) to authenticated;

-- 5) Auditar: la decisión, el responsable, la medida, y la marca en el despacho --------------------
create or replace function public.vigilancia_auditar(
  p_id bigint, p_decision text, p_responsable text default null, p_medida text default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  c public.vigilancia_casos; m jsonb; d record; v_n int; v_marcas jsonb := '[]'::jsonb;
  v_dec text := upper(btrim(coalesce(p_decision, '')));
  v_resp text := nullif(upper(btrim(coalesce(p_responsable, ''))), '');
  v_regid bigint; v_campo text; v_valor text;
begin
  select * into c from public.vigilancia_casos where id = p_id and estado in ('ABIERTO', 'CERRADO') for update;
  if c.id is null or not public._vig_puede(c.ruta, c.ruta_mapa) then
    return jsonb_build_object('ok', false, 'error', 'No se encontró el caso.');
  end if;
  if v_dec not in ('CONFIRMADO', 'JUSTIFICADO', 'FALSA_ALARMA') then
    return jsonb_build_object('ok', false, 'error', 'Elige la decisión.');
  end if;
  if v_dec = 'CONFIRMADO' and c.tipo = 'ADELANTAMIENTO' and coalesce(v_resp, '') not in ('ADELANTE', 'ATRAS') then
    return jsonb_build_object('ok', false, 'error', 'Di quién incumplió: el de adelante o el de atrás.');
  end if;
  if v_dec <> 'CONFIRMADO' then v_resp := 'NINGUNO'; end if;
  if v_dec = 'CONFIRMADO' and c.tipo <> 'ADELANTAMIENTO' then v_resp := null; end if;   -- es el mismo bus del caso
  if v_dec <> 'CONFIRMADO' and coalesce(btrim(p_nota), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se justifica o por qué es falsa alarma.');
  end if;

  -- Primero se deshace lo que el vigilante había marcado (si la decisión cambia): cada campo vuelve
  -- al valor que tenía antes, y solo si nadie lo cambió después.
  for m in select * from jsonb_array_elements(c.marcado) loop
    if m->>'campo' = 'estado' then
      execute format('update public.%I set estado = $2 where id::text = $1 and estado = %L', m->>'tabla', 'ADELANTADO')
        using m->>'id', m->>'antes';
    else
      execute format('update public.%I set %I = $2::boolean where id::text = $1 and %I is true', m->>'tabla', m->>'campo', m->>'campo')
        using m->>'id', m->>'antes';
    end if;
  end loop;

  -- Lo que se marca al confirmar.
  if v_dec = 'CONFIRMADO' then
    if c.tipo = 'FUERA_RUTA' then v_regid := c.regid; v_campo := 'abandono_ruta';
    elsif c.tipo = 'APAGADO' then v_regid := c.regid; v_campo := 'perdida_deliberada_tiempo';
    elsif v_resp = 'ADELANTE' then v_regid := c.regid_rel; v_campo := 'perdida_deliberada_tiempo';
    else v_regid := c.regid; v_campo := 'estado';
    end if;
    for d in select * from public._vig_despachos(v_regid) loop
      execute format('select %I::text from public.%I where id::text = $1', v_campo, d.tabla) into v_valor using d.id;
      if v_campo = 'estado' then
        execute format('update public.%I set estado = %L where id::text = $1 and coalesce(btrim(estado), %L) = %L',
                       d.tabla, 'ADELANTADO', '', '') using d.id;
      else
        execute format('update public.%I set %I = true where id::text = $1 and %I is not true', d.tabla, v_campo, v_campo)
          using d.id;
      end if;
      get diagnostics v_n = row_count;
      if v_n > 0 then
        v_marcas := v_marcas || jsonb_build_array(jsonb_build_object('tabla', d.tabla, 'id', d.id, 'campo', v_campo, 'antes', v_valor));
      end if;
    end loop;
  end if;

  update public.vigilancia_casos
     set decision = v_dec, responsable = v_resp, medida = nullif(btrim(coalesce(p_medida, '')), ''),
         nota = nullif(btrim(coalesce(p_nota, '')), ''), auditado_por = lower(coalesce(auth.email(), '')),
         auditado_en = now(), marcado = v_marcas
   where id = c.id;

  return jsonb_build_object('ok', true, 'marcados', jsonb_array_length(v_marcas),
    'sin_despacho', v_dec = 'CONFIRMADO' and not exists (select 1 from public._vig_despachos(v_regid)));
end $$;
revoke all on function public.vigilancia_auditar(bigint, text, text, text, text) from public, anon;
grant execute on function public.vigilancia_auditar(bigint, text, text, text, text) to authenticated;

-- 6) Cada 2 minutos, en las mismas horas que refresca moviles_operacion (UTC: 3 a. m. a 11:59 p. m. de Colombia)
select cron.unschedule('vigilante-ruta') where exists (select 1 from cron.job where jobname = 'vigilante-ruta');
select cron.schedule('vigilante-ruta', '*/2 0-4,8-23 * * *', $cron$select public.vigilante_ruta()$cron$);
