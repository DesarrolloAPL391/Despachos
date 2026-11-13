-- 174: calibración del 🚨 Vigilante de ruta con los casos del 05/11/2026 (14:16 a 15:20).
-- 1) APAGADO: no cuenta en los 2 últimos puntos del viaje. Ahí los buses esperan apagados el final:
--    130 en Parque Berrío (punto 19 de 20), 132ii y 134i en Parque Poblado, 133i en Pomona.
-- 2) ADELANTAMIENTO: el de atrás tiene que haber salido al menos 2 minutos después. Con salidas a 35 o 47
--    segundos (136ii) no se sabe quién iba adelante.
-- 3) Un caso se cierra cuando lleva 10 minutos sin verse (antes 5). Con 5, el mismo bus en el mismo viaje
--    se partía en dos casos cuando SONAR dejaba de reportar 6 minutos.
-- Los tres quedan como parámetros con su valor por defecto; el cron sigue llamando vigilante_ruta() sin nada.
-- Se borra y se vuelve a crear porque cambia la firma: dos versiones con todo por defecto harían ambigua la llamada del cron.

drop function if exists public.vigilante_ruta(int, int, int, int);

create function public.vigilante_ruta(
  p_min_apagado int default 10, p_min_fuera int default 6, p_min_adelanto int default 4, p_dist int default 300,
  p_min_salida int default 2, p_puntos_final int default 2, p_hueco int default 10)
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
     and not (o.par_total is not null and o.idx + 1 >= o.par_total - p_puntos_final)   -- 174: la espera del final
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
     and l.inicio >= l.r_inicio + make_interval(mins => p_min_salida);   -- 174: salidas casi juntas no dicen quién iba adelante

  -- Se cierra lo que dejó de verse hace más de p_hueco minutos (un reporte perdido no parte el caso).
  with c as (
    update public.vigilancia_casos set estado = 'CERRADO', hasta = visto_en
     where estado = 'ABIERTO' and visto_en <= now() - make_interval(mins => p_hueco) returning 1)
  select count(*) into v_cerrados from c;
  with b as (
    delete from public.vigilancia_casos
     where estado = 'CANDIDATO' and visto_en <= now() - make_interval(mins => p_hueco) returning 1)
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
revoke all on function public.vigilante_ruta(int, int, int, int, int, int, int) from public, anon, authenticated;

-- Techo propio: corre cada 2 minutos (sql/120: un cron sin techo hereda 120 s y lo revierte todo).
alter function public.vigilante_ruta(int, int, int, int, int, int, int) set statement_timeout = '90s';

-- Los casos del 05/11 que con estas reglas no habrían salido. Solo los que nadie ha auditado ni marcado.
delete from public.vigilancia_casos c
 where c.fecha = date '2026-11-05' and c.decision is null and jsonb_array_length(c.marcado) = 0
   and ((c.tipo = 'APAGADO' and c.par_total is not null and c.punto_desde + 1 >= c.par_total - 2)
     or (c.tipo = 'ADELANTAMIENTO' and c.inicio_viaje < c.inicio_rel + interval '2 minutes'));
