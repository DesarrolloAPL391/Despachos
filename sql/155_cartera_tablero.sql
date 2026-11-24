-- ============================================================================================
-- 155 · TABLERO DE LA CARTERA — todo lo que necesita la pantalla 💼 Cartera de conductores
--
-- "debemos de hacer algo bien específico que me muestre hasta un dashboard, algo bien
--  organizado" (01/11/2026). Una sola llamada trae:
--   · conductores: saldo de cada uno, la deuda por antigüedad, los buses, el último pago,
--     si paga a tiempo y con qué pruebas (colillas, extracto del banco);
--   · tramos: la deuda de todos por antigüedad (1-3, 4-7, 8-15, 16-30, más de 30 días);
--   · semanas: lo liquidado contra lo pagado, semana por semana;
--   · revisar: colillas que el banco no muestra o que llevan días sin confirmar.
-- Usa el mismo reparto de la cartera (sql/154): del día más viejo al más nuevo.
-- La antigüedad de una deuda se cuenta desde el día liquidado.
--
-- TOPE DE ALERTA: "que se pueda parametrizar… al conductor se le acumula x cantidad de dinero
-- salta la alerta, porque eso es dinero que está en juego" (01/11/2026). El administrador define
-- en el tablero cuánto es mucho (un monto, unos días debiendo, o los dos); el conductor que lo
-- pase queda marcado, sale arriba del tablero y en el menú con número rojo.
--
-- PAGA A TIEMPO: "saber que consigne de acuerdo a lo que se le exige y las pruebas… el que más
-- paga a tiempo y el que no paga a tiempo, como un top 10" (01/11/2026).
--   · Cada día liquidado queda pagado el día del pago que lo termina de cubrir (con el reparto).
--   · A TIEMPO = pagado a más tardar N días después del día liquidado (N = plazo, lo define el
--     administrador; vacío = 1, el día siguiente). Pagar antes también es a tiempo.
--   · TARDE = pagado después del plazo, o sin pagar y el plazo ya pasó.
--   · Un día sin pagar que todavía está dentro del plazo no cuenta ni para bien ni para mal.
--   · Como el reparto paga lo más viejo primero, el que se atrasa sigue atrasado hasta ponerse
--     al día: su plata del día tapa la deuda vieja.
-- ============================================================================================

-- ---------------------------------------------------------------------------------------------
-- 0) Las reglas, en la misma fila de la configuración de la cartera (vacío = sin alerta)
-- ---------------------------------------------------------------------------------------------
alter table public.liq_cartera_config
  add column if not exists alerta_monto        numeric,      -- alerta cuando deba esto o más
  add column if not exists alerta_dias         int,          -- o cuando su deuda más vieja pase de estos días
  add column if not exists plazo_dias          int,          -- días que tiene para consignar (vacío = 1)
  add column if not exists reglas_cambiado_por text,
  add column if not exists reglas_cambiado_en  timestamptz;

create or replace function public.cartera_reglas_guardar(p_monto numeric, p_dias int, p_plazo int)
returns jsonb
language plpgsql volatile security definer set search_path to 'public'
as $function$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  if p_monto is not null and (p_monto <= 0 or p_monto >= 1e9) then
    return jsonb_build_object('ok', false, 'error', 'El monto debe ser mayor que cero.');
  end if;
  if p_dias is not null and (p_dias < 1 or p_dias > 365) then
    return jsonb_build_object('ok', false, 'error', 'Los días van de 1 a 365.');
  end if;
  if p_plazo is not null and (p_plazo < 0 or p_plazo > 30) then
    return jsonb_build_object('ok', false, 'error', 'El plazo va de 0 (el mismo día) a 30 días.');
  end if;
  update public.liq_cartera_config
     set alerta_monto = round(p_monto), alerta_dias = p_dias, plazo_dias = p_plazo,
         reglas_cambiado_por = coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'), reglas_cambiado_en = now()
   where id;
  return jsonb_build_object('ok', true, 'monto', round(p_monto), 'dias', p_dias, 'plazo', coalesce(p_plazo, 1));
end $function$;
revoke all on function public.cartera_reglas_guardar(numeric, int, int) from public, anon;
grant execute on function public.cartera_reglas_guardar(numeric, int, int) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1) Cada día liquidado: cuánto se le pagó, qué día quedó pagado, con qué prueba y si fue a
--    tiempo. Lo usan el tablero (para todos) y el detalle (para uno): una sola regla.
--    prueba: BANCO = todo lo que lo pagó está en el extracto · POR_CONFIRMAR = alguna colilla
--    sin extracto todavía · NO_APARECE = alguna colilla que el banco no muestra.
--    a_tiempo: null = sin pagar pero todavía dentro del plazo (no cuenta).
-- ---------------------------------------------------------------------------------------------
create or replace function public._cartera_cumple(p_desde date, p_hoy date, p_plazo int, p_ced text default null)
returns table (cedula text, ref text, fecha date, movil text, ruta text, valor bigint, pagado bigint,
               pagado_el date, prueba text, dias int, a_tiempo boolean)
language sql stable security definer set search_path to 'public'
as $function$
  with m as (select * from public._cartera_movs(p_desde, p_ced)),
  c as (select * from m where m.clase = 'cargo'),
  a as (select * from m where m.clase <> 'cargo'),
  -- Los abonos van por fecha, así que el último que lo cubre es el de la fecha mayor
  p as (select c.cedula, c.ref, sum(least(c.fin, a.fin) - greatest(c.ini, a.ini))::bigint as pagado,
               max(a.fecha) as ult, bool_or(a.estado = 'NO_APARECE') as no_aparece,
               bool_or(a.estado not in ('BANCO', 'CONFIRMADA')) as sin_conf
          from c join a on a.cedula = c.cedula and a.ini < c.fin and a.fin > c.ini
         group by c.cedula, c.ref),
  y as (select c.cedula, c.ref, c.fecha, c.movil, c.ruta, c.valor, coalesce(p.pagado, 0) as pagado,
               case when coalesce(p.pagado, 0) >= c.valor then p.ult end as pagado_el,
               case when p.no_aparece then 'NO_APARECE' when p.sin_conf then 'POR_CONFIRMAR'
                    when p.pagado > 0 then 'BANCO' end as prueba
          from c left join p on p.cedula = c.cedula and p.ref = c.ref)
  select y.cedula, y.ref, y.fecha, y.movil, y.ruta, y.valor, y.pagado, y.pagado_el, y.prueba,
         -- Días que tardó en pagarlo (o que lleva sin pagarlo); pagar antes cuenta como 0
         greatest(coalesce(y.pagado_el, p_hoy) - y.fecha, 0),
         case when y.pagado_el is not null then y.pagado_el - y.fecha <= p_plazo
              when p_hoy - y.fecha > p_plazo then false end
    from y
$function$;
revoke all on function public._cartera_cumple(date, date, int, text) from public, anon, authenticated;

-- El nombre de una cédula: su última liquidación; si no tiene, SONAR o el Perfil
create or replace function public._cartera_nombre(p_ced text)
returns text
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select l.conductor from public.liquidaciones l where l.conductor_cedula = p_ced order by l.fecha desc limit 1),
    (select s.nombre from public.conductores_sonar s where s.cedula = p_ced limit 1),
    (select p.nombre from public.perfilsociodemografico p where p.cedula = p_ced limit 1))
$function$;
revoke all on function public._cartera_nombre(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2) El tablero
-- ---------------------------------------------------------------------------------------------
create or replace function public.cartera_tablero()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_desde date := public._cartera_desde();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_cfg public.liq_cartera_config;
  v_plazo int;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  select * into v_cfg from public.liq_cartera_config where id;
  v_plazo := coalesce(v_cfg.plazo_dias, 1);
  if v_desde is null then
    return jsonb_build_object('ok', false, 'error', 'La cartera todavía no arranca: falta el día de arranque.');
  end if;
  return (
    with k as (select * from public._cartera_cumple(v_desde, v_hoy, v_plazo)),
    a as (select * from public._cartera_movs(v_desde) m where m.clase <> 'cargo'),
    -- Lo que se debe, con su tramo de antigüedad
    pe as (select k.cedula, k.fecha, k.movil, k.valor - k.pagado as pend,
                  case when v_hoy - k.fecha <= 3 then 1 when v_hoy - k.fecha <= 7 then 2
                       when v_hoy - k.fecha <= 15 then 3 when v_hoy - k.fecha <= 30 then 4 else 5 end as tramo
             from k where k.pagado < k.valor),
    t as (select k.cedula, sum(k.valor)::bigint as tc, count(*) as n_liq, string_agg(distinct k.movil, ', ') as buses,
                 count(*) filter (where k.a_tiempo is not null) as evaluados,
                 count(*) filter (where k.a_tiempo) as a_tiempo,
                 count(*) filter (where k.a_tiempo = false and k.pagado_el is null) as vencidos,
                 round(avg(k.dias) filter (where k.a_tiempo is not null), 1) as prom_dias
            from k group by k.cedula),
    -- Las pruebas de lo que pagó: colillas (con foto), cuántas confirmó el banco y lo que solo
    -- está en el extracto
    u as (select a.cedula, sum(a.valor)::bigint as ta, max(a.fecha) as ult,
                 coalesce(sum(a.valor) filter (where a.estado = 'POR_CONFIRMAR'), 0)::bigint as por_conf,
                 count(*) filter (where a.estado = 'NO_APARECE') as no_aparece,
                 count(*) filter (where a.clase = 'colilla') as colillas,
                 count(*) filter (where a.estado = 'CONFIRMADA') as confirmadas,
                 count(*) filter (where a.clase = 'banco') as en_extracto
            from a group by a.cedula),
    ed as (select pe.cedula, pe.tramo, sum(pe.pend)::bigint as v from pe group by pe.cedula, pe.tramo),
    e as (select pe.cedula, count(*) as dias, min(pe.fecha) as desde, string_agg(distinct pe.movil, ', ') as buses,
                 (select jsonb_object_agg(ed.tramo, ed.v) from ed where ed.cedula = pe.cedula) as edades
            from pe group by pe.cedula),
    -- Todas las cédulas con movimiento: también las que consignaron sin tener liquidaciones
    ced as (select t.cedula from t union select u.cedula from u),
    nom as (select ced.cedula, public._cartera_nombre(ced.cedula) as nombre from ced),
    filas as (
      select x.*,
             x.evaluados - x.a_tiempo as tarde,
             case when x.evaluados > 0 then round(100.0 * x.a_tiempo / x.evaluados) end as pct_tiempo,
             -- Pasa el tope: debe el monto o más, o su deuda más vieja ya tiene más de esos días
             coalesce(x.debe >= v_cfg.alerta_monto, false)
               or coalesce(v_hoy - x.debe_desde > v_cfg.alerta_dias, false) as alerta
        from (
          select ced.cedula, nom.nombre, coalesce(t.tc, 0) as cargos, coalesce(u.ta, 0) as abonos,
                 greatest(coalesce(t.tc, 0) - coalesce(u.ta, 0), 0) as debe,
                 greatest(coalesce(u.ta, 0) - coalesce(t.tc, 0), 0) as a_favor,
                 coalesce(u.por_conf, 0) as por_confirmar, coalesce(u.no_aparece, 0) as no_aparece,
                 coalesce(u.colillas, 0) as colillas, coalesce(u.confirmadas, 0) as confirmadas,
                 coalesce(u.en_extracto, 0) as en_extracto,
                 u.ult as ultimo_pago, coalesce(t.n_liq, 0) as dias_liq,
                 coalesce(e.dias, 0) as dias_pendientes, e.desde as debe_desde,
                 e.buses as buses_debe, t.buses, coalesce(e.edades, '{}'::jsonb) as edades,
                 coalesce(t.n_liq, 0) = 0 as sin_liquidaciones,
                 coalesce(t.evaluados, 0) as evaluados, coalesce(t.a_tiempo, 0) as a_tiempo,
                 coalesce(t.vencidos, 0) as vencidos, t.prom_dias
            from ced left join t on t.cedula = ced.cedula left join u on u.cedula = ced.cedula
            left join e on e.cedula = ced.cedula left join nom on nom.cedula = ced.cedula) x)
    select jsonb_build_object(
      'ok', true, 'desde', v_desde, 'hoy', v_hoy,
      'alerta', jsonb_build_object('monto', v_cfg.alerta_monto, 'dias', v_cfg.alerta_dias, 'plazo', v_plazo,
                                   'plazo_puesto', v_cfg.plazo_dias is not null,
                                   'cambiado_por', v_cfg.reglas_cambiado_por, 'cambiado_en', v_cfg.reglas_cambiado_en),
      'conductores', (select coalesce(jsonb_agg(to_jsonb(f) order by f.debe desc, f.a_favor desc, f.nombre), '[]'::jsonb) from filas f),
      'tramos', (select coalesce(jsonb_agg(jsonb_build_object('tramo', x.tramo, 'valor', x.v, 'conductores', x.n)
                                           order by x.tramo), '[]'::jsonb)
                   from (select pe.tramo, sum(pe.pend)::bigint as v, count(distinct pe.cedula) as n
                           from pe group by pe.tramo) x),
      -- Semanas de lunes a domingo: lo liquidado (por el día liquidado) y lo pagado (por la fecha del pago)
      'semanas', (select coalesce(jsonb_agg(jsonb_build_object('semana', s.sem, 'liquidado', s.liq, 'pagado', s.pag)
                                            order by s.sem), '[]'::jsonb)
                    from (select date_trunc('week', z.d)::date as sem, sum(z.liq)::bigint as liq, sum(z.pag)::bigint as pag
                            from (select k.fecha as d, k.valor as liq, 0::bigint as pag from k
                                  union all select a.fecha, 0, a.valor from a) z
                           group by 1) s),
      -- Colillas para revisar: el banco no las muestra, o llevan más de 3 días sin extracto
      'revisar', (select coalesce(jsonb_agg(jsonb_build_object('cedula', a.cedula, 'nombre', nom.nombre, 'id', a.ref,
                                   'fecha', a.fecha, 'valor', a.valor, 'estado', a.estado, 'dias', v_hoy - a.fecha)
                                   order by (a.estado = 'NO_APARECE') desc, a.fecha), '[]'::jsonb)
                    from a left join nom on nom.cedula = a.cedula
                   where a.clase = 'colilla'
                     and (a.estado = 'NO_APARECE' or (a.estado = 'POR_CONFIRMAR' and v_hoy - a.fecha > 3)))));
end $function$;
revoke all on function public.cartera_tablero() from public, anon;
grant execute on function public.cartera_tablero() to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3) Los que pasan el tope, para el número rojo del menú y el aviso al entrar (lo pide la app
--    cada 10 minutos). Sale del mismo tablero: una sola regla.
-- ---------------------------------------------------------------------------------------------
create or replace function public.cartera_alertas()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  v := public.cartera_tablero();
  if not coalesce((v ->> 'ok')::boolean, false) then
    return jsonb_build_object('ok', true, 'n', 0, 'lista', '[]'::jsonb);
  end if;
  return (select jsonb_build_object('ok', true, 'n', count(*),
                   'lista', coalesce(jsonb_agg(jsonb_build_object('cedula', x ->> 'cedula', 'nombre', x ->> 'nombre',
                                       'valor', (x ->> 'debe')::numeric) order by (x ->> 'debe')::numeric desc), '[]'::jsonb))
            from jsonb_array_elements(v -> 'conductores') x where (x ->> 'alerta')::boolean);
end $function$;
revoke all on function public.cartera_alertas() from public, anon;
grant execute on function public.cartera_alertas() to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4) El detalle de un conductor (reemplaza el de sql/154): su cartera, y por cada día liquidado
--    qué día quedó pagado, si fue a tiempo y con qué prueba.
-- ---------------------------------------------------------------------------------------------
create or replace function public.cartera_conductor(p_cedula text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_desde date := public._cartera_desde();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_plazo int := coalesce((select c.plazo_dias from public.liq_cartera_config c where c.id), 1);
  v jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  v := public._cartera(v_ced);
  if not coalesce((v ->> 'ok')::boolean, false) then return v; end if;
  return v || jsonb_build_object('cedula', v_ced, 'nombre', public._cartera_nombre(v_ced),
    'sin_liquidaciones', jsonb_array_length(v -> 'cargos') = 0, 'plazo', v_plazo,
    'puntual', (select coalesce(jsonb_agg(jsonb_build_object('key', k.ref, 'pagado_el', k.pagado_el, 'dias', k.dias,
                                 'a_tiempo', k.a_tiempo, 'prueba', k.prueba)), '[]'::jsonb)
                  from public._cartera_cumple(v_desde, v_hoy, v_plazo, v_ced) k));
end $function$;
revoke all on function public.cartera_conductor(text) from public, anon;
grant execute on function public.cartera_conductor(text) to authenticated;
