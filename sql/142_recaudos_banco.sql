-- 142_recaudos_banco.sql
-- "en este archivo estan los archivos que se necesitan para llenar las planillas de
--  liquidacion, podemos hacer una automatizacion: la liquidacion verifica, ensaya y monta"
--  (24/10/2026).
--
-- LO QUE TRAIA EL ZIP:
--   * PLANILLA CENTRO.xlsx y PLANILLA METRO.xlsx -> estan **VACIAS**. Son las plantillas: 650 y
--     1.504 filas sin un solo dato, y METRO ademas tiene las formulas de RUTA rotas (#REF!).
--   * RecaudosDiasAnteriores-20261015.xls -> esto SI son datos: el extracto del Banco de Bogota
--     del 15/10/2026, 46 consignaciones por $8.000.200.
--
-- EL HALLAZGO QUE HACE POSIBLE LA AUTOMATIZACION: cada consignacion trae la CEDULA del
-- conductor en la referencia, rellena de ceros a la izquierda
-- (000000000000000000000012345678 -> 12345678). Se comprobo contra el perfil: **las 30 cedulas
-- distintas son conductores reales, 30 de 30**, y 29 de ellas estan en las liquidaciones.
-- Sin eso habria que emparejar por valor, que es ambiguo (hay montos repetidos el mismo dia).
--
-- SE CONSIGNA LO DE LA LIQUIDACION (confirmado por el usuario), Y AL DIA SIGUIENTE: de los 27
-- conductores con liquidacion, **13 cuadran exacto con el dia ANTERIOR** y solo 1 con el mismo
-- dia. Por eso el cuadre no compara dia contra dia sino **saldos acumulados**: un conductor que
-- consigna el lunes lo del sabado y el domingo no puede aparecer como moroso el sabado y con
-- saldo a favor el lunes. La planilla ya piensa asi -- tiene DEBITO, CREDITO y DEUDA REAL.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

-- ---------------------------------------------------------------------------
-- 1) Las consignaciones del banco
-- ---------------------------------------------------------------------------
create table if not exists public.recaudos_banco (
  id           bigserial primary key,
  archivo      text not null,
  linea        int  not null,
  fecha        date not null,
  fecha_aplica date,
  tipo         text,
  origen       text,
  banco        text,
  transaccion  text,
  ref1         text,
  ref2         text,
  cedula       text,
  valor        bigint not null,
  comprobante  text,
  cargado_en   timestamptz not null default now(),
  cargado_por  text,
  -- El mismo archivo se puede volver a subir sin duplicar nada; dos archivos distintos con la
  -- misma consignacion si entrarian, y para eso esta la revision de duplicados de la pantalla.
  unique (archivo, linea)
);

comment on table  public.recaudos_banco is 'Consignaciones del extracto bancario, con la cedula sacada de la referencia (sql/142).';
comment on column public.recaudos_banco.cedula is 'Sale de la referencia rellena de ceros. Es lo que permite saber QUIEN consigno.';

create index if not exists rec_fecha_idx  on public.recaudos_banco (fecha desc);
create index if not exists rec_cedula_idx on public.recaudos_banco (cedula, fecha);

alter table public.recaudos_banco enable row level security;
drop policy if exists rec_admin on public.recaudos_banco;
create policy rec_admin on public.recaudos_banco
  for all to authenticated
  using ((select public.es_admin())) with check ((select public.es_admin()));

-- ---------------------------------------------------------------------------
-- 2) Sacar la cedula de la referencia
--    Viene como 000000000000000000000012345678. Se quitan los ceros de la izquierda y se exige
--    que quede algo con pinta de cedula (6 a 11 digitos): asi una referencia de ceros, o un
--    numero de recibo larguisimo, no se hacen pasar por una persona.
-- ---------------------------------------------------------------------------
create or replace function public._ced_ref(p_ref1 text, p_ref2 text)
returns text language sql immutable as $function$
  select c from (
    select nullif(regexp_replace(coalesce(p_ref1, ''), '^0+', ''), '') as c
    union all
    select nullif(regexp_replace(coalesce(p_ref2, ''), '^0+', ''), '')
  ) t
  where c ~ '^[0-9]{6,11}$'
  limit 1;
$function$;

-- Fecha que puede venir aaaa-mm-dd (el banco) o dd/mm/aaaa (las hojas de la empresa).
create or replace function public._f_banco(v text)
returns date language plpgsql immutable as $function$
declare t text := btrim(coalesce(v, ''));
begin
  if t = '' then return null; end if;
  t := replace(t, '/', '-');
  if t ~ '^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}' then
    return to_date(left(t, 10), 'YYYY-MM-DD');
  end if;
  return public._f_cl(v);
exception when others then
  return null;
end $function$;

-- ---------------------------------------------------------------------------
-- 3) Cargar un extracto. La app lee el .xls en el navegador y manda las filas aqui.
-- ---------------------------------------------------------------------------
create or replace function public.recaudos_cargar(p_archivo text, p_filas jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ins int := 0; v_tot int := 0; v_sin int := 0; v_desde date; v_hasta date;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  if coalesce(btrim(p_archivo), '') = '' or p_filas is null
     or jsonb_typeof(p_filas) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'No llegaron las filas del extracto.');
  end if;

  with f as (
    select (e.v ->> 'linea')::int                       as linea,
           -- El banco manda aaaa/mm/dd y la hoja de liquidaciones dd/mm/aaaa: se aceptan
           -- las dos, porque equivocarse de formato aqui corre los saldos de dia.
           public._f_banco(e.v ->> 'fecha')             as fecha,
           public._f_banco(e.v ->> 'fecha_aplica')      as fecha_aplica,
           nullif(btrim(e.v ->> 'tipo'), '')            as tipo,
           nullif(btrim(e.v ->> 'origen'), '')          as origen,
           nullif(btrim(e.v ->> 'banco'), '')           as banco,
           nullif(btrim(e.v ->> 'transaccion'), '')     as transaccion,
           nullif(btrim(e.v ->> 'ref1'), '')            as ref1,
           nullif(btrim(e.v ->> 'ref2'), '')            as ref2,
           round(coalesce((e.v ->> 'valor')::numeric, 0))::bigint as valor,
           nullif(btrim(e.v ->> 'comprobante'), '')     as comprobante
      from jsonb_array_elements(p_filas) as e(v)
  ),
  val as (
    select * from f where fecha is not null and valor <> 0
  ),
  ins as (
    insert into public.recaudos_banco
      (archivo, linea, fecha, fecha_aplica, tipo, origen, banco, transaccion,
       ref1, ref2, cedula, valor, comprobante, cargado_por)
    select btrim(p_archivo), v.linea, v.fecha, v.fecha_aplica, v.tipo, v.origen, v.banco,
           v.transaccion, v.ref1, v.ref2, public._ced_ref(v.ref1, v.ref2), v.valor,
           v.comprobante, coalesce(auth.jwt() ->> 'email', 'admin')
      from val v
    on conflict (archivo, linea) do nothing
    returning 1
  )
  select (select count(*) from ins), (select count(*) from val),
         (select count(*) from val where public._ced_ref(ref1, ref2) is null),
         (select min(fecha) from val), (select max(fecha) from val)
    into v_ins, v_tot, v_sin, v_desde, v_hasta;

  return jsonb_build_object('ok', true, 'leidas', v_tot, 'nuevas', v_ins,
                            'repetidas', v_tot - v_ins, 'sin_cedula', v_sin,
                            'desde', v_desde, 'hasta', v_hasta,
                            'total', (select count(*) from public.recaudos_banco));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

revoke all on function public.recaudos_cargar(text, jsonb) from public, anon;
grant execute on function public.recaudos_cargar(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) El cuadre: quien debe, quien pago de mas, quien no ha consignado
--    Por SALDO ACUMULADO en el rango, no dia contra dia (ver la nota de arriba).
-- ---------------------------------------------------------------------------
create or replace function public.recaudos_cuadre(
  p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_h date := coalesce(p_hasta, (now() at time zone 'America/Bogota')::date);
  v_d date := coalesce(p_desde, v_h - 30);
  v_out jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  with liq as (
    select regexp_replace(coalesce(conductor_cedula, ''), '[^0-9]', '', 'g') as ced,
           max(conductor) as nombre,
           sum(dinero)::bigint as liquidado,
           count(distinct fecha)::int as dias,
           string_agg(distinct movil, ', ' order by movil) as moviles
      from public.liquidaciones
     where fecha between v_d and v_h
       and conductor_cedula is not null
     group by 1
  ),
  -- La consignacion del dia D corresponde a lo liquidado el dia D-1: se corre un dia la
  -- ventana del banco para que el ultimo dia liquidado alcance a aparecer pago.
  con as (
    select cedula as ced,
           sum(valor)::bigint as consignado,
           count(*)::int as consignaciones,
           max(fecha) as ultima
      from public.recaudos_banco
     where cedula is not null
       and fecha between v_d and v_h + 1
     group by 1
  ),
  todo as (
    select coalesce(l.ced, c.ced) as ced,
           l.nombre, l.moviles, coalesce(l.liquidado, 0) as liquidado, coalesce(l.dias, 0) as dias,
           coalesce(c.consignado, 0) as consignado, coalesce(c.consignaciones, 0) as veces,
           c.ultima,
           coalesce(l.liquidado, 0) - coalesce(c.consignado, 0) as saldo
      from liq l full outer join con c on c.ced = l.ced
  ),
  -- El nombre se busca en el perfil para los que consignaron sin tener liquidacion.
  fin as (
    select t.*, coalesce(t.nombre, p.nombre) as quien
      from todo t
      left join lateral (
        select nombre from public.perfilsociodemografico
         where regexp_replace(coalesce(cedula, ''), '[^0-9]', '', 'g') = t.ced
         limit 1) p on true
  )
  select jsonb_build_object(
    'ok', true,
    'desde', v_d, 'hasta', v_h,
    'resumen', jsonb_build_object(
      'conductores',   (select count(*) from fin),
      'liquidado',     (select coalesce(sum(liquidado), 0) from fin),
      'consignado',    (select coalesce(sum(consignado), 0) from fin),
      'saldo',         (select coalesce(sum(saldo), 0) from fin),
      'al_dia',        (select count(*) from fin where saldo = 0),
      'deben',         (select count(*) from fin where saldo > 0),
      'a_favor',       (select count(*) from fin where saldo < 0),
      'sin_consignar', (select count(*) from fin where consignado = 0 and liquidado > 0),
      'sin_liquidar',  (select count(*) from fin where liquidado = 0 and consignado > 0)),
    'filas', (select coalesce(jsonb_agg(jsonb_build_object(
                'cedula', f.ced, 'nombre', f.quien, 'moviles', f.moviles,
                'dias', f.dias, 'liquidado', f.liquidado,
                'consignado', f.consignado, 'veces', f.veces,
                'ultima', to_char(f.ultima, 'DD/MM/YYYY'),
                'saldo', f.saldo,
                'estado', case when f.liquidado = 0 then 'consigno sin liquidacion'
                               when f.consignado = 0 then 'no ha consignado'
                               when f.saldo = 0 then 'al dia'
                               when f.saldo > 0 then 'debe'
                               else 'pago de mas' end
              ) order by abs(f.saldo) desc, f.quien), '[]'::jsonb) from fin f)
  ) into v_out;

  return v_out;
end $function$;

revoke all on function public.recaudos_cuadre(date, date) from public, anon;
grant execute on function public.recaudos_cuadre(date, date) to authenticated;

-- Comprobacion (solo lectura)
select 'tabla recaudos_banco' as dato,
       (select case when count(*) > 0 then 'si' else 'NO' end::text
          from information_schema.tables
         where table_schema = 'public' and table_name = 'recaudos_banco') as valor
union all
select 'las dos formas de fecha se entienden',
       case when public._f_banco('2026/10/15') = date '2026-10-15'
             and public._f_banco('15/10/2026') = date '2026-10-15'
            then 'si' else 'NO' end
union all
select 'la cedula se saca bien de la referencia',
       case when public._ced_ref('000000000000000000000012345678', null) = '12345678'
             and public._ced_ref('000000000000', null) is null
            then 'si' else 'NO' end
union all
select 'funciones de recaudos',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('recaudos_cargar', 'recaudos_cuadre', '_ced_ref')) || ' de 3'
union all
select 'consignaciones cargadas',
       (select count(*)::text from public.recaudos_banco);
