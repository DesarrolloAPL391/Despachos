-- ============================================================================================
-- 148 · LIQUIDACIONES — la planilla METRO completa, cruzada con la liquidación y el banco
--
-- "en el modulo de liquidacion ya debe de tener cruzado todo para que las plantillas se realicen
--  completas" + "recuerda que eso es de acuerdo a la liquidacion que consultamos a la base de
--  datos" (31/10/2026).
--
-- LAS REGLAS SALEN DE LAS FÓRMULAS DE LA PROPIA PLANTILLA (PLANILLA METRO.xlsx, hoja METRO):
--   L  TOTAL PAX            = C + F + I              (lo validado con cívica)
--   M  COSTO TRANSACCIONAL  = L × 172,87
--   N/O RUTA / RUTA 1       = de la Hoja1 (RUTA 1 es la TARIFA 1..6)
--   R  DIFERENCIA PAX       = Q − L                  (Q = PAX SENSOR)
--   S  TOTAL DIFERENCIA     = R × 3.800
--   U  RECONOCIMIENTO       = T × 3.800              (T = viajes)
--   W  A LIQUIDAR CANTIDAD  = (Q − L) + (I − T)
--   X  A LIQUIDAR $         = W × 3.800
--   AB DIFERENCIA / AC DÉBITO = X − Y                (Y = VALOR CONSIGNADO)
--   AI PAX PARA NÓMINA      = Q − AH                 (AH = novedades por viaje)
--   AJ NÓMINA               = AI × tarifa de la ruta (290, 280, 200, 360, 300, 600)
--
-- Y LA LIQUIDACIÓN DE LA BASE ES ESA MISMA CUENTA, medido sobre 12.287 filas de 2026:
--   UNIDADES               = Q (pax sensor)
--   PASAJEROS A DESCONTAR  = T (los viajes: 100%)
--   TOTAL A LIQUIDAR       = Q − T
--   LIQUIDAR               = W  → TOTAL A LIQUIDAR − LIQUIDAR = lo validado con cívica (>0 en el 100%)
--   DINERO                 = X  (LIQUIDAR × 3.800 en el 100% desde el 16/01/2026)
-- Por eso la planilla se llena desde la liquidación, no desde el sensor de SONAR.
--
-- Lo que la liquidación NO trae y por eso NO se inventa: el reparto de lo validado entre
-- Integrado Cívica / Pleno Cívica / Tarjeta Conductor (y con él, TOTAL DE INGRESOS e INGRESO REAL).
--
-- La consignación del banco se ASIGNA en la app (primero se paga lo más viejo), no aquí: esta
-- función entrega las piezas — liquidaciones, las de los días anteriores del mismo conductor
-- y las consignaciones — para que la misma regla sirva a la planilla y al cuadre diario.
--
-- Se aplica sobre sql/138-140, 142 y 147.
-- ============================================================================================

-- 1) Tarifas de nómina por ruta (Hoja1 de la planilla METRO, "desde el 16 de enero 2026") -------
create table if not exists public.liq_tarifas (
  id      serial primary key,
  grupo   text not null check (grupo in ('METRO', 'CENTRO')),
  ruta    text not null,
  -- Solo para la 134IA: la liquidación la anota como 134I, y lo que la distingue es el bus.
  movil   text,
  tarifa  text not null,
  valor   int  not null check (valor >= 0),
  desde   date not null default date '2026-01-16',
  nota    text
);
create unique index if not exists liq_tarifas_uq
  on public.liq_tarifas (ruta, coalesce(movil, ''), desde);

alter table public.liq_tarifas enable row level security;
drop policy if exists liq_tarifas_admin on public.liq_tarifas;
create policy liq_tarifas_admin on public.liq_tarifas
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
revoke all on public.liq_tarifas from anon;
grant select, insert, update, delete on public.liq_tarifas to authenticated;

comment on table public.liq_tarifas is
  'Pago de nomina por pasajero segun la ruta (Hoja1 de la planilla METRO). sql/148';

insert into public.liq_tarifas (grupo, ruta, movil, tarifa, valor, nota) values
  ('METRO', '130I',      null, 'TARIFA 1', 290, null),
  ('METRO', '133I',      null, 'TARIFA 1', 290, null),
  ('METRO', '133II',     null, 'TARIFA 1', 290, null),
  ('METRO', '133IIA',    null, 'TARIFA 1', 290, null),
  ('METRO', '134I',      null, 'TARIFA 2', 280, null),
  ('METRO', '136II',     null, 'TARIFA 2', 280, null),
  ('METRO', '136I',      null, 'TARIFA 2', 280, null),
  ('METRO', '132II',     null, 'TARIFA 2', 280, null),
  ('METRO', '135II',     null, 'TARIFA 3', 200, null),
  ('METRO', '132I',      null, 'TARIFA 4', 360, null),
  ('METRO', '135I',      null, 'TARIFA 4', 360, null),
  ('METRO', '193II',     null, 'TARIFA 5', 300, null),
  ('METRO', '193I-193II', null, 'TARIFA 5', 300, 'Asi la escribe la liquidacion'),
  ('METRO', '134IA',     null, 'TARIFA 6', 600, null),
  -- Los buses de la 134IA segun la Hoja1 (incluye los que reemplazan): cuando la liquidación
  -- dice 134I, para ellos es la 134IA.
  ('METRO', '134I', '5535', 'TARIFA 6', 600, 'Bus de la 134IA; la liquidacion anota 134I'),
  ('METRO', '134I', '5555', 'TARIFA 6', 600, 'Bus de la 134IA; la liquidacion anota 134I'),
  ('METRO', '134I', '5601', 'TARIFA 6', 600, 'Bus de la 134IA; la liquidacion anota 134I'),
  ('METRO', '134I', '5659', 'TARIFA 6', 600, 'Bus de la 134IA; la liquidacion anota 134I'),
  ('METRO', '134I', '5670', 'TARIFA 6', 600, 'Bus de la 134IA; la liquidacion anota 134I'),
  ('METRO', '134I', '5579', 'TARIFA 6', 600, 'Reemplaza la 5670 en la 134IA'),
  ('CENTRO', '130-132',  null, 'CENTRO', 700, null),
  ('CENTRO', '133-133D', null, 'CENTRO', 750, null),
  ('CENTRO', '134',      null, 'CENTRO', 500, null),
  ('CENTRO', '135',      null, 'CENTRO', 500, null)
on conflict do nothing;

-- La tarifa vigente de una ruta (y bus) en una fecha: primero la del bus, después la de la ruta.
create or replace function public._liq_tarifa(p_ruta text, p_movil text, p_fecha date)
returns table (tarifa text, valor int)
language sql stable security definer set search_path to 'public'
as $function$
  select t.tarifa, t.valor
    from public.liq_tarifas t
   where upper(t.ruta) = upper(btrim(coalesce(p_ruta, '')))
     and (t.movil is null or t.movil = btrim(coalesce(p_movil, '')))
     and t.desde <= p_fecha
   order by (t.movil is not null) desc, t.desde desc
   limit 1;
$function$;
revoke all on function public._liq_tarifa(text, text, date) from public, anon;

-- 2) La planilla: liquidación + tarifa + lo que hace falta para asignar lo consignado ----------
create or replace function public.liquidaciones_planilla(
  p_desde date default null,
  p_hasta date default null,
  p_punto text default null,
  p_movil text default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_h date := coalesce(p_hasta, (now() at time zone 'America/Bogota')::date);
  v_d date := coalesce(p_desde, v_h - 30);
  -- Se consigna al otro día, a veces dos o tres días después (fines de semana): la ventana
  -- del banco se abre una semana a cada lado para no dejar pagos sin su liquidación.
  v_margen int := 7;
  v_out jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  if v_h - v_d > 180 then
    return jsonb_build_object('ok', false, 'error', 'El rango no puede pasar de 180 días.');
  end if;

  with liq as (
    select l.*,
           nullif(regexp_replace(coalesce(l.conductor_cedula, ''), '[^0-9]', '', 'g'), '') as ced
      from public.liquidaciones l
     where l.fecha between v_d and v_h
       and (p_punto is null or btrim(p_punto) = '' or l.punto = btrim(p_punto))
       and (p_movil is null or btrim(p_movil) = '' or l.movil = btrim(p_movil))
  ),
  ceds as (select distinct ced from liq where ced is not null),
  filas as (
    select l.key, l.fecha, l.movil, l.ruta, l.punto, l.viajes,
           l.conductor, l.conductor_cedula, l.ced, l.propietario,
           l.unidades, l.descontar, l.total_liquidar, l.liquidar, l.dinero, l.cuadra,
           t.tarifa, t.valor as tarifa_valor
      from liq l
      left join lateral public._liq_tarifa(l.ruta, l.movil, l.fecha) t on true
  ),
  -- Lo que el mismo conductor liquidó la semana antes del rango: lo que consigna el día 1
  -- normalmente es de esos días, y sin ellos se lo cobraría a la primera fila del mes.
  previas as (
    select l.key, l.fecha, nullif(regexp_replace(coalesce(l.conductor_cedula, ''), '[^0-9]', '', 'g'), '') as ced,
           l.dinero
      from public.liquidaciones l
     where l.fecha between v_d - v_margen and v_d - 1
       and nullif(regexp_replace(coalesce(l.conductor_cedula, ''), '[^0-9]', '', 'g'), '') in (select ced from ceds)
       and (p_punto is null or btrim(p_punto) = '' or l.punto = btrim(p_punto))
  ),
  -- Y lo que liquidó la semana DESPUÉS: quien consigna el 15 lo del 14 y lo del 15 junto, en
  -- una planilla que termina el 14 saldría "pagó de más" si lo del 15 no estuviera en la cuenta.
  posteriores as (
    select l.key, l.fecha, nullif(regexp_replace(coalesce(l.conductor_cedula, ''), '[^0-9]', '', 'g'), '') as ced,
           l.dinero
      from public.liquidaciones l
     where l.fecha between v_h + 1 and v_h + v_margen
       and nullif(regexp_replace(coalesce(l.conductor_cedula, ''), '[^0-9]', '', 'g'), '') in (select ced from ceds)
       and (p_punto is null or btrim(p_punto) = '' or l.punto = btrim(p_punto))
  ),
  con as (
    select r.id, r.cedula as ced, r.fecha, r.valor, r.banco, r.archivo
      from public.recaudos_banco r
     where r.cedula in (select ced from ceds)
       and r.fecha between v_d - v_margen and v_h + v_margen
  )
  select jsonb_build_object(
    'ok', true,
    'desde', v_d, 'hasta', v_h, 'punto', p_punto, 'margen', v_margen,
    'total', (select count(*) from filas),
    'resumen', jsonb_build_object(
      'dinero',     (select coalesce(sum(dinero), 0) from filas),
      'pax',        (select coalesce(sum(unidades), 0) from filas),
      'sin_cuadrar', (select count(*) filter (where not cuadra) from filas),
      'sin_tarifa',  (select count(*) filter (where tarifa is null) from filas),
      'rutas_sin_tarifa', (select coalesce(jsonb_agg(distinct ruta), '[]'::jsonb) from filas where tarifa is null),
      -- Lo que entró al banco en el rango de personas que NO aparecen en esta liquidación
      -- (otra flota, CENTRO, abonos de deudas): no se cruza, pero se dice cuánto es.
      'banco_rango', (select coalesce(sum(r.valor), 0) from public.recaudos_banco r
                       where r.fecha between v_d and v_h + 1),
      'banco_otros', (select coalesce(sum(r.valor), 0) from public.recaudos_banco r
                       where r.fecha between v_d and v_h + 1
                         and (r.cedula is null or r.cedula not in (select ced from ceds))),
      'banco_otros_personas', (select count(distinct coalesce(r.cedula, r.ref1)) from public.recaudos_banco r
                       where r.fecha between v_d and v_h + 1
                         and (r.cedula is null or r.cedula not in (select ced from ceds)))),
    'filas', (select coalesce(jsonb_agg(to_jsonb(f) order by f.fecha, f.movil, f.ruta), '[]'::jsonb) from filas f),
    'previas', (select coalesce(jsonb_agg(to_jsonb(p) order by p.fecha, p.key), '[]'::jsonb) from previas p),
    'posteriores', (select coalesce(jsonb_agg(to_jsonb(p) order by p.fecha, p.key), '[]'::jsonb) from posteriores p),
    'consignaciones', (select coalesce(jsonb_agg(to_jsonb(c) order by c.fecha, c.id), '[]'::jsonb) from con c),
    -- Días que tienen extracto cargado: sin extracto no se puede decir que alguien no pagó.
    'dias_banco', (select coalesce(jsonb_agg(distinct r.fecha order by r.fecha), '[]'::jsonb)
                     from public.recaudos_banco r
                    where r.fecha between v_d - v_margen and v_h + v_margen)
  ) into v_out;
  return v_out;
end $function$;
revoke all on function public.liquidaciones_planilla(date, date, text, text) from public, anon;
grant execute on function public.liquidaciones_planilla(date, date, text, text) to authenticated;

comment on function public.liquidaciones_planilla(date, date, text, text) is
  'Planilla METRO desde la liquidacion: filas con su tarifa de nomina, liquidaciones previas del conductor y consignaciones del banco para asignarlas (sql/148).';

-- 3) Qué extractos del banco hay cargados --------------------------------------------------------
create or replace function public.recaudos_estado()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  return jsonb_build_object(
    'ok', true,
    'movimientos', (select count(*) from public.recaudos_banco),
    'dias', (select count(distinct fecha) from public.recaudos_banco),
    'desde', (select min(fecha) from public.recaudos_banco),
    'hasta', (select max(fecha) from public.recaudos_banco),
    'total', (select coalesce(sum(valor), 0) from public.recaudos_banco),
    'archivos', (select coalesce(jsonb_agg(a order by a.hasta desc), '[]'::jsonb) from (
                   select archivo, min(fecha) as desde, max(fecha) as hasta, count(*) as filas,
                          sum(valor) as valor, max(cargado_en) as cargado_en
                     from public.recaudos_banco group by archivo) a));
end $function$;
revoke all on function public.recaudos_estado() from public, anon;
grant execute on function public.recaudos_estado() to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Comprobaciones (solo lectura):
--   select * from public._liq_tarifa('134I', '5535', date '2026-10-10');   -- TARIFA 6 / 600
--   select * from public._liq_tarifa('134I', '5616', date '2026-10-10');   -- TARIFA 2 / 280
--   select * from public._liq_tarifa('193I-193II', '8256', date '2026-10-10'); -- TARIFA 5 / 300
