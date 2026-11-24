-- 202_cartera_plazo_habil.sql
-- "te puse en la carpeta los recaudos por cedula y fecha de conductores de acuerdo a la liquidacion,
--  darme una solucion para todo este tema del recaudo" -> "si hazlo" (23/11/2026).
--
-- EL BANCO ES LA PRUEBA DEL PAGO. El "Archivo Recaudo" que el Banco de Bogota manda cada dia (zip con
-- el .lst y el Asobancaria) trae la cedula del conductor en la referencia de cada pago: la app lo carga
-- tal cual (js/recaudo-banco.js -> recaudos_cargar, sql/142) y la cartera por conductor (sql/154-155)
-- cruza sola. La colilla deja de ser obligatoria.
--
-- Medido con 18 dias reales (31/10-19/11): con solo los conductores que tienen liquidacion se consigno
-- el 95,6 % del DINERO liquidado; casi siempre al dia siguiente, y lo del sabado el lunes (o el martes
-- si el lunes es festivo). Con el plazo en dias de calendario, el que paga el lunes lo del sabado
-- quedaba "tarde" sin serlo.
--
-- LO UNICO QUE CAMBIA: el plazo para pagar cuenta DIAS HABILES. Los domingos y los festivos
-- (public.es_festivo) no cuentan; el sabado si, porque el banco recibe. Con plazo 1:
--   viernes -> sabado a tiempo · sabado -> lunes a tiempo · sabado -> martes (lunes festivo) a tiempo
--   sabado -> martes (lunes normal) tarde.
-- "dias" (lo que tardo o lleva sin pagar) sigue en dias de calendario: es lo que se le dice a la gente.
--
-- Y UN DIA SIN PAGAR SOLO ES "TARDE" SI YA ESTA EL BANCO DEL DIA EN QUE VENCIA: se mide hasta el ultimo
-- dia con archivo del banco cargado, no hasta hoy. Si el zip del lunes todavia no se ha subido, nadie
-- sale atrasado por eso (queda "todavia en plazo" hasta que se cargue).
-- Todo lo demas de _cartera_cumple queda igual que en sql/155.
--
-- DESHACER: volver a ejecutar la definicion de _cartera_cumple de sql/155.

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
          from c left join p on p.cedula = c.cedula and p.ref = c.ref),
  -- Días hábiles acumulados desde antes del arranque: la resta de dos de estos da cuántos días
  -- hábiles hay entre dos fechas (domingos y festivos no suman). Una sola serie para todos.
  h as (select g.d::date as dia,
               (count(*) filter (where extract(isodow from g.d) <> 7 and not public.es_festivo(g.d::date))
                  over (order by g.d))::int as n
          from generate_series(least(p_desde, p_hoy) - 1, greatest(p_desde, p_hoy) + 60, interval '1 day') g(d)),
  -- Hasta dónde se puede afirmar que alguien NO pagó: el último día con archivo del banco
  b as (select least(p_hoy, coalesce(max(r.fecha), p_hoy)) as hasta from public.recaudos_banco r)
  select y.cedula, y.ref, y.fecha, y.movil, y.ruta, y.valor, y.pagado, y.pagado_el, y.prueba,
         -- Días que tardó en pagarlo (o que lleva sin pagarlo); pagar antes cuenta como 0
         greatest(coalesce(y.pagado_el, p_hoy) - y.fecha, 0),
         -- A tiempo: pagado a más tardar p_plazo días HÁBILES después del día liquidado
         case when y.pagado_el is not null then coalesce(hp.n - hf.n, y.pagado_el - y.fecha) <= p_plazo
              when coalesce(hh.n - hf.n, b.hasta - y.fecha) > p_plazo then false end
    from y
    cross join b
    left join h hf on hf.dia = y.fecha
    left join h hp on hp.dia = y.pagado_el
    left join h hh on hh.dia = b.hasta
$function$;
revoke all on function public._cartera_cumple(date, date, int, text) from public, anon, authenticated;

-- Comprobacion (solo lectura): los dias habiles entre dos fechas, con el mismo calculo
with h as (select g.d::date as dia,
                  (count(*) filter (where extract(isodow from g.d) <> 7 and not public.es_festivo(g.d::date))
                     over (order by g.d))::int as n
             from generate_series(date '2026-11-01', date '2026-11-30', interval '1 day') g(d)),
     k(desde, hasta, espera) as (values (date '2026-11-13', date '2026-11-14', 1),   -- viernes -> sabado
                                        (date '2026-11-07', date '2026-11-09', 1),   -- sabado -> lunes
                                        (date '2026-11-14', date '2026-11-17', 1),   -- sabado -> martes, lunes 16 festivo
                                        (date '2026-11-07', date '2026-11-10', 2))   -- sabado -> martes normal
select k.desde, k.hasta, b.n - a.n as habiles, k.espera,
       case when b.n - a.n = k.espera then 'ok' else 'MAL' end as resultado
  from k join h a on a.dia = k.desde join h b on b.dia = k.hasta;
