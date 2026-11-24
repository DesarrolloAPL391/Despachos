-- ============================================================================================
-- 154 · CARTERA POR CONDUCTOR — la deuda persigue al conductor y cada pago se reparte solo
--
-- "la cuenta es por el conductor, debe de perseguir al conductor como si fuera una cartera y
--  claro identificar el carro porque él puede manejar varios ... si hace una consignación grande
--  el sistema lo puede repartir de acuerdo a lo que deba" (01/11/2026).
--
-- Reemplaza "una colilla por liquidación" de sql/149:
--   · CARGOS: cada liquidación del conductor (por su cédula), en el bus que sea, desde el día de
--     arranque de la cartera (liq_cartera_config.desde). El DINERO de la hoja, tal cual.
--   · ABONOS: sus colillas y las consignaciones del extracto del banco con su cédula, desde el día
--     SIGUIENTE al arranque: lo que se consigna el primer día casi siempre es del día anterior,
--     que ya no está en la cartera. La línea del banco que ES una colilla no se cuenta dos veces.
--   · REPARTO: los abonos, por fecha, pagan los cargos del más viejo al más nuevo. No se guarda:
--     se calcula cada vez, así que si la hoja cambia un valor o se borra una colilla, la cartera
--     se reacomoda sola. Lo que sobra queda A FAVOR y paga lo que se liquide después.
--   · Sin ventana de días: una deuda vieja sigue ahí hasta que se pague.
--
-- La colilla ya no se sube "para una liquidación": el conductor la sube y el servidor le muestra
-- qué días paga. La prueba de que la plata entró sigue siendo el extracto del banco.
--
-- El link nuevo usa cartera_identificar / cartera_analizar / cartera_guardar. Las colilla_* del
-- link de sql/149 quedan como estaban hasta publicar el nuevo; ahí se borran (ver el final).
--
-- Se aplica sobre sql/138 (liquidaciones), 142 (recaudos_banco) y 149 (liq_colillas).
-- ============================================================================================

-- ---------------------------------------------------------------------------------------------
-- 0) El día de arranque (una sola fila). Mientras esté vacío, la cartera no funciona.
-- ---------------------------------------------------------------------------------------------
create table if not exists public.liq_cartera_config (
  id          boolean primary key default true check (id),
  desde       date,                          -- los cargos cuentan desde este día; los abonos, desde el siguiente
  cambiado_en timestamptz not null default now()
);
alter table public.liq_cartera_config enable row level security;
revoke all on public.liq_cartera_config from anon, authenticated;
insert into public.liq_cartera_config (id, desde) values (true, null) on conflict (id) do nothing;

comment on table public.liq_cartera_config is
  'Dia de arranque de la cartera por conductor (sql/154). Se cambia solo por SQL.';

create or replace function public._cartera_desde()
returns date
language sql stable security definer set search_path to 'public'
as $function$ select desde from public.liq_cartera_config where id $function$;
revoke all on function public._cartera_desde() from public, anon, authenticated;

-- El banco de una colilla o de una línea del extracto, para saber si ya está ese extracto.
-- Occidente va primero: el recibo de Efecty (corresponsal de Occidente) imprime "Bogota".
create or replace function public._banco_clave(p text)
returns text
language sql immutable set search_path to 'public'
as $function$
  select case
    when t ~ 'OCCIDENTE|EFECTY|EFECTIVO LTDA' then 'OCCIDENTE'
    when t ~ 'BOGOTA' then 'BOGOTA'
    when t ~ 'POPULAR' then 'POPULAR'
    when t ~ 'VILLAS' then 'AVVILLAS'
    when t ~ 'BANCOLOMBIA' then 'BANCOLOMBIA'
    when t ~ 'DAVIVIENDA' then 'DAVIVIENDA'
    when t ~ 'BBVA' then 'BBVA'
    when t ~ 'CAJA SOCIAL' then 'CAJASOCIAL'
  end
  from (select upper(translate(coalesce(p, ''), 'áéíóúÁÉÍÓÚ', 'aeiouAEIOU')) as t) x
$function$;
revoke all on function public._banco_clave(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1) Los movimientos: cargos y abonos de cada conductor, cada uno con su tramo acumulado
--    [ini, fin). El reparto es el cruce de tramos: el abono que va de 100 a 300 paga la parte
--    de cada cargo que cae en ese tramo. Así lo más viejo se paga primero, sin guardar nada.
--    p_extra = la colilla que se está revisando ({fecha, valor}), que todavía no está guardada.
-- ---------------------------------------------------------------------------------------------
create or replace function public._cartera_movs(p_desde date, p_ced text default null, p_extra jsonb default null)
returns table (cedula text, clase text, ref text, fecha date, movil text, ruta text,
               valor bigint, estado text, ini bigint, fin bigint)
language sql stable security definer set search_path to 'public'
as $function$
  with x as (
    select (p_extra ->> 'fecha')::date as fecha, (p_extra ->> 'valor')::bigint as valor
     where p_ced is not null and p_extra is not null and (p_extra ->> 'valor') is not null
  ),
  cargos as (
    select l.conductor_cedula as ced, l.key as ref, l.fecha, l.movil, l.ruta, l.dinero as valor
      from public.liquidaciones l
     where l.fecha >= p_desde and l.dinero > 0 and coalesce(l.conductor_cedula, '') <> ''
       and (p_ced is null or l.conductor_cedula = p_ced)
  ),
  col as (
    select c.cedula as ced, c.id, c.fecha, c.movil, c.valor, c.banco, c.creado_en
      from public.liq_colillas c
     where c.fecha > p_desde and (p_ced is null or c.cedula = p_ced)
  ),
  ban as (   -- consignaciones del extracto que NO son una colilla (enviada o la que se revisa)
    select r.cedula as ced, r.id, r.fecha, r.valor
      from public.recaudos_banco r
     where r.fecha > p_desde and r.valor > 0 and coalesce(r.cedula, '') <> ''
       and (p_ced is null or r.cedula = p_ced)
       and not exists (select 1 from public.liq_colillas c
                        where c.cedula = r.cedula and c.valor = r.valor
                          and r.fecha between c.fecha and c.fecha + 1)
       and not exists (select 1 from x where x.valor = r.valor and r.fecha between x.fecha and x.fecha + 1)
  ),
  abonos as (
    select col.ced, 'colilla'::text as clase, col.id::text as ref, col.fecha, col.movil, col.valor,
           case when exists (select 1 from public.recaudos_banco r
                              where r.cedula = col.ced and r.valor = col.valor
                                and r.fecha between col.fecha and col.fecha + 1) then 'CONFIRMADA'
                -- NO_APARECE solo si ya está el extracto de ESE banco del día y del siguiente
                when public._banco_clave(col.banco) is not null
                 and exists (select 1 from public.recaudos_banco r where r.fecha = col.fecha
                                and public._banco_clave(r.banco) = public._banco_clave(col.banco))
                 and exists (select 1 from public.recaudos_banco r where r.fecha = col.fecha + 1
                                and public._banco_clave(r.banco) = public._banco_clave(col.banco)) then 'NO_APARECE'
                else 'POR_CONFIRMAR' end as estado,
           col.creado_en as orden
      from col
    union all
    select ban.ced, 'banco', ban.id::text, ban.fecha, null, ban.valor, 'BANCO', ban.fecha::timestamptz from ban
    union all
    select p_ced, 'nueva', 'nueva', x.fecha, null, x.valor, 'NUEVA', 'infinity'::timestamptz from x
  )
  select ced, 'cargo', ref, fecha, movil, ruta, valor, null::text,
         sum(valor) over w - valor, sum(valor) over w
    from cargos
  window w as (partition by ced order by fecha, movil, ruta, ref rows unbounded preceding)
  union all
  select ced, clase, ref, fecha, movil, null, valor, estado,
         sum(valor) over w - valor, sum(valor) over w
    from abonos
  window w as (partition by ced order by fecha, orden, ref rows unbounded preceding)
$function$;
revoke all on function public._cartera_movs(date, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2) La cartera de un conductor: cada cargo con lo pagado y lo pendiente, cada abono con lo que
--    alcanzó a pagar, y el saldo (lo que debe o lo que tiene a favor).
-- ---------------------------------------------------------------------------------------------
create or replace function public._cartera(p_ced text, p_extra jsonb default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_desde date := public._cartera_desde();
  v jsonb;
begin
  if v_desde is null then
    return jsonb_build_object('ok', false, 'error', 'La cartera todavía no arranca: pregunta en la oficina.');
  end if;
  with m as (select * from public._cartera_movs(v_desde, p_ced, p_extra)),
  c as (select * from m where m.clase = 'cargo'),
  a as (select * from m where m.clase <> 'cargo'),
  r as (select c.ref as cref, a.ref as aref, a.clase as aclase, a.estado as aestado,
               least(c.fin, a.fin) - greatest(c.ini, a.ini) as monto
          from c join a on a.ini < c.fin and a.fin > c.ini),
  tc as (select coalesce(sum(c.valor), 0)::bigint as v from c),
  ta as (select coalesce(sum(a.valor), 0)::bigint as v from a)
  select jsonb_build_object(
    'ok', true, 'desde', v_desde,
    'total_cargos', tc.v, 'total_abonos', ta.v,
    'debe', greatest(tc.v - ta.v, 0), 'a_favor', greatest(ta.v - tc.v, 0),
    'cargos', (select coalesce(jsonb_agg(jsonb_build_object(
                  'key', c.ref, 'fecha', c.fecha, 'movil', c.movil, 'ruta', c.ruta, 'dinero', c.valor,
                  'pagado', coalesce(p.pagado, 0), 'pendiente', c.valor - coalesce(p.pagado, 0),
                  -- pagado con colillas que el banco todavía no confirma
                  'sin_confirmar', coalesce(p.sin_conf, 0),
                  'nueva', coalesce(p.nueva, 0)) order by c.ini), '[]'::jsonb)
                 from c left join (select r.cref, sum(r.monto) as pagado,
                                          sum(r.monto) filter (where r.aestado not in ('BANCO', 'CONFIRMADA')) as sin_conf,
                                          sum(r.monto) filter (where r.aclase = 'nueva') as nueva
                                     from r group by r.cref) p on p.cref = c.ref),
    'abonos', (select coalesce(jsonb_agg(jsonb_build_object(
                  'clase', a.clase, 'id', a.ref, 'fecha', a.fecha, 'valor', a.valor, 'estado', a.estado,
                  'aplicado', coalesce(q.ap, 0), 'a_favor', a.valor - coalesce(q.ap, 0)) order by a.ini), '[]'::jsonb)
                 from a left join (select r.aref, r.aclase, sum(r.monto) as ap from r group by r.aref, r.aclase) q
                        on q.aref = a.ref and q.aclase = a.clase))
    into v
    from tc, ta;
  return v;
end $function$;
revoke all on function public._cartera(text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3) Una colilla nueva: qué días paga y cómo queda el conductor (no guarda nada).
--    veredicto: COMPLETO = queda al día · PARCIAL = sigue debiendo · DE_MAS = queda a favor.
-- ---------------------------------------------------------------------------------------------
create or replace function public._colilla_reparto(p_ced text, p_fecha date, p_valor bigint,
  p_comprobante text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_desde date := public._cartera_desde();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_comp text := nullif(btrim(coalesce(p_comprobante, '')), '');
  v jsonb; v_cubre jsonb; v_dup jsonb; v_bid bigint; v_bfecha date;
begin
  if v_desde is null then
    return jsonb_build_object('ok', false, 'error', 'La cartera todavía no arranca: pregunta en la oficina.');
  end if;
  if p_fecha is null or p_fecha > v_hoy + 1 or p_fecha < v_hoy - 45 then
    return jsonb_build_object('ok', false, 'error', 'Revisa la fecha de la colilla.');
  end if;
  if p_fecha <= v_desde then
    return jsonb_build_object('ok', false, 'error',
      'La colilla dice ' || to_char(p_fecha, 'DD/MM/YYYY') || ' y los pagos cuentan desde el '
      || to_char(v_desde + 1, 'DD/MM/YYYY') || '. Revisa la fecha.');
  end if;
  if p_valor is null or p_valor <= 0 or p_valor > 10000000 then
    return jsonb_build_object('ok', false, 'error', 'Revisa el valor de la colilla.');
  end if;

  v := public._cartera(p_ced, jsonb_build_object('fecha', p_fecha, 'valor', p_valor));
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', e ->> 'key', 'fecha', e ->> 'fecha', 'movil', e ->> 'movil', 'ruta', e ->> 'ruta',
           'dinero', (e ->> 'dinero')::bigint, 'aplicado', (e ->> 'nueva')::bigint,
           'pendiente', (e ->> 'pendiente')::bigint)), '[]'::jsonb)
    into v_cubre
    from jsonb_array_elements(v -> 'cargos') e
   where (e ->> 'nueva')::bigint > 0;

  -- ¿El banco ya la registra?
  select r.id, r.fecha into v_bid, v_bfecha
    from public.recaudos_banco r
   where r.cedula = p_ced and r.valor = p_valor and r.fecha between p_fecha and p_fecha + 1
   order by r.fecha, r.id limit 1;

  -- La misma colilla no se cuenta dos veces: ni del mismo conductor (mismo día y valor, y el mismo
  -- comprobante si las dos lo traen) ni de otra persona con el mismo comprobante.
  select jsonb_build_object('id', lc.id, 'otra_persona', lc.cedula <> p_ced,
           'enviada', to_char(lc.creado_en at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI'))
    into v_dup
    from public.liq_colillas lc
   where lc.fecha = p_fecha and lc.valor = p_valor
     and ((lc.cedula = p_ced and (lc.comprobante is null or v_comp is null or lc.comprobante = v_comp))
          or (v_comp is not null and lc.comprobante = v_comp))
   order by lc.id limit 1;

  return jsonb_build_object(
    'ok', true,
    'veredicto', case when (v ->> 'debe')::bigint > 0 then 'PARCIAL'
                      when (v ->> 'a_favor')::bigint > 0 then 'DE_MAS' else 'COMPLETO' end,
    'valor', p_valor, 'fecha', p_fecha,
    -- lo que debía antes de esta colilla (sin ella: la línea del banco que ES ella tampoco cuenta)
    'debia', greatest((v ->> 'total_cargos')::bigint - ((v ->> 'total_abonos')::bigint - p_valor), 0),
    'debe', (v ->> 'debe')::bigint, 'a_favor', (v ->> 'a_favor')::bigint,
    'cubre', v_cubre,
    'banco_confirma', v_bid is not null, 'banco_fecha', v_bfecha,
    'duplicada', v_dup);
end $function$;
revoke all on function public._colilla_reparto(text, date, bigint, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4) Puertas públicas (link del conductor). Mismas reglas de entrada: cédula + un bus suyo.
-- ---------------------------------------------------------------------------------------------
-- Con la cartera, la deuda vieja lo persigue: también entra con un bus de antes del último mes,
-- si es de la cartera.
create or replace function public._colilla_quien(p_cedula text, p_movil text,
  out ced text, out nombre text, out error text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_mov text := btrim(coalesce(p_movil, ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_desde date := least(v_hoy - 45, coalesce(public._cartera_desde(), v_hoy - 45));
begin
  ced := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  if length(ced) < 5 then error := 'Escribe tu número de cédula.'; return; end if;
  if v_mov = '' then error := 'Escribe el número del bus.'; return; end if;

  if (select count(*) from public.liq_colilla_intentos
       where cedula = ced and cuando > now() - interval '1 hour') >= 5 then
    error := 'Demasiados intentos. Espera una hora o pide ayuda en la oficina.';
    return;
  end if;

  select max(l.conductor) into nombre
    from public.liquidaciones l
   where l.fecha >= v_desde
     and l.movil = v_mov
     and regexp_replace(coalesce(l.conductor_cedula, ''), '\D', '', 'g') = ced;

  if nombre is null then
    insert into public.liq_colilla_intentos (cedula) values (ced);
    -- El mismo mensaje sirva o no la cédula: no se le confirma a nadie que una cédula existe.
    error := 'La cédula y el bus no coinciden con tus liquidaciones.';
  end if;
end $function$;
revoke all on function public._colilla_quien(text, text) from public, anon, authenticated;

create or replace function public.cartera_identificar(p_cedula text, p_movil text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  q record; v jsonb;
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  select * into q from public._colilla_quien(p_cedula, p_movil);
  if q.error is not null then return jsonb_build_object('ok', false, 'error', q.error); end if;
  v := public._cartera(q.ced);
  if not coalesce((v ->> 'ok')::boolean, false) then return v; end if;
  return jsonb_build_object('ok', true, 'nombre', q.nombre, 'desde', v -> 'desde',
    'debe', v -> 'debe', 'a_favor', v -> 'a_favor',
    -- Todo lo pendiente (la deuda lo persigue) y lo pagado de las dos últimas semanas
    'cargos', (select coalesce(jsonb_agg(e order by (e ->> 'fecha')::date desc, e ->> 'movil'), '[]'::jsonb)
                 from jsonb_array_elements(v -> 'cargos') e
                where (e ->> 'pendiente')::bigint > 0 or (e ->> 'fecha')::date >= v_hoy - 14),
    'abonos', (select coalesce(jsonb_agg(z.e order by (z.e ->> 'fecha')::date desc), '[]'::jsonb)
                 from (select e from jsonb_array_elements(v -> 'abonos') e
                        order by (e ->> 'fecha')::date desc limit 10) z));
end $function$;

create or replace function public.cartera_analizar(p_cedula text, p_movil text, p_fecha date,
  p_valor numeric, p_comprobante text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare q record;
begin
  select * into q from public._colilla_quien(p_cedula, p_movil);
  if q.error is not null then return jsonb_build_object('ok', false, 'error', q.error); end if;
  if p_valor is null or p_valor <= 0 or p_valor > 10000000 then
    return jsonb_build_object('ok', false, 'error', 'Revisa el valor de la colilla.');
  end if;
  return public._colilla_reparto(q.ced, p_fecha, round(p_valor)::bigint, p_comprobante);
end $function$;

create or replace function public.cartera_guardar(p_cedula text, p_movil text, p_datos jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  q record; v jsonb; v_id bigint;
  v_fecha date; v_valor bigint; v_foto text; v_ref text; v_texto text; v_refced boolean;
begin
  select * into q from public._colilla_quien(p_cedula, p_movil);
  if q.error is not null then return jsonb_build_object('ok', false, 'error', q.error); end if;

  begin
    v_fecha := (p_datos ->> 'fecha')::date;
    v_valor := round((p_datos ->> 'valor')::numeric)::bigint;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'Revisa la fecha y el valor.');
  end;

  v_foto := p_datos ->> 'foto';
  if v_foto is null or v_foto !~ '^data:image/(jpeg|png|webp);base64,' then
    return jsonb_build_object('ok', false, 'error', 'Falta la foto de la colilla.');
  end if;
  if length(v_foto) > 2000000 then
    return jsonb_build_object('ok', false, 'error', 'La foto es muy pesada. Tómala otra vez.');
  end if;

  -- El reparto lo calcula el servidor otra vez: lo que mande el celular no se cree.
  v := public._colilla_reparto(q.ced, v_fecha, v_valor, p_datos ->> 'comprobante');
  if not coalesce((v ->> 'ok')::boolean, false) then return v; end if;
  if v -> 'duplicada' is not null and v -> 'duplicada' <> 'null'::jsonb then
    return jsonb_build_object('ok', false, 'error',
      case when (v -> 'duplicada' ->> 'otra_persona')::boolean
           then 'Esta colilla ya la envió otra persona. Si es tuya, pide ayuda en la oficina.'
           else 'Esta colilla ya la enviaste el ' || (v -> 'duplicada' ->> 'enviada') || '.' end);
  end if;

  -- ¿La colilla trae la cédula? Si no, el banco no sabrá de quién es la plata.
  v_ref := left(btrim(coalesce(p_datos ->> 'referencia', '')), 60);
  v_texto := left(coalesce(p_datos ->> 'ocr_texto', ''), 6000);
  v_refced := regexp_replace(v_ref, '^0+', '') = q.ced
           or exists (select 1 from regexp_matches(v_texto, '\d{5,}', 'g') m
                       where regexp_replace(m[1], '^0+', '') = q.ced);

  -- cubre/faltante/sobrante quedan como estaban AL ENVIARLA; la cartera los recalcula siempre.
  insert into public.liq_colillas
    (cedula, nombre, movil, fecha, valor, valor_a_mano, referencia, ref_cedula, comprobante, banco,
     ocr_texto, ocr_confianza, foto, cubre, veredicto, faltante, sobrante)
  values
    (q.ced, q.nombre, btrim(p_movil), v_fecha, v_valor,
     coalesce((p_datos ->> 'valor_a_mano')::boolean, false),
     nullif(v_ref, ''), v_refced,
     nullif(left(btrim(coalesce(p_datos ->> 'comprobante', '')), 40), ''),
     nullif(left(btrim(coalesce(p_datos ->> 'banco', '')), 60), ''),
     nullif(v_texto, ''),
     nullif(p_datos ->> 'ocr_confianza', '')::numeric,
     v_foto, v -> 'cubre', v ->> 'veredicto', (v ->> 'debe')::bigint, (v ->> 'a_favor')::bigint)
  returning id into v_id;

  return v || jsonb_build_object('id', v_id, 'ref_cedula', v_refced);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'No se pudo guardar: ' || SQLERRM);
end $function$;

revoke all on function public.cartera_identificar(text, text) from public;
revoke all on function public.cartera_analizar(text, text, date, numeric, text) from public;
revoke all on function public.cartera_guardar(text, text, jsonb) from public;
grant execute on function public.cartera_identificar(text, text) to anon, authenticated;
grant execute on function public.cartera_analizar(text, text, date, numeric, text) to anon, authenticated;
grant execute on function public.cartera_guardar(text, text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 5) Para administración: la cartera de todos y el detalle de uno
-- ---------------------------------------------------------------------------------------------
create or replace function public.cartera_conductores()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_desde date := public._cartera_desde();
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  if v_desde is null then
    return jsonb_build_object('ok', false, 'error', 'La cartera todavía no arranca: falta el día de arranque.');
  end if;
  return jsonb_build_object('ok', true, 'desde', v_desde, 'filas', (
    with m as (select * from public._cartera_movs(v_desde)),
    c as (select * from m where m.clase = 'cargo'),
    a as (select * from m where m.clase <> 'cargo'),
    r as (select c.cedula, c.ref, least(c.fin, a.fin) - greatest(c.ini, a.ini) as monto
            from c join a on a.cedula = c.cedula and a.ini < c.fin and a.fin > c.ini),
    pc as (select c.cedula, c.ref, c.fecha, c.movil, c.valor - coalesce(sum(r.monto), 0) as pend
             from c left join r on r.cedula = c.cedula and r.ref = c.ref
            group by c.cedula, c.ref, c.fecha, c.movil, c.valor),
    t as (select c.cedula, sum(c.valor)::bigint as tc from c group by c.cedula),
    u as (select a.cedula, sum(a.valor)::bigint as ta, max(a.fecha) as ult,
                 sum(a.valor) filter (where a.estado not in ('BANCO', 'CONFIRMADA'))::bigint as sin_conf
            from a group by a.cedula),
    nom as (select distinct on (l.conductor_cedula) l.conductor_cedula as cedula, l.conductor as nombre
              from public.liquidaciones l where l.fecha >= v_desde
             order by l.conductor_cedula, l.fecha desc)
    select coalesce(jsonb_agg(jsonb_build_object(
             'cedula', t.cedula, 'nombre', nom.nombre,
             'cargos', t.tc, 'abonos', coalesce(u.ta, 0),
             'debe', greatest(t.tc - coalesce(u.ta, 0), 0), 'a_favor', greatest(coalesce(u.ta, 0) - t.tc, 0),
             'sin_confirmar', coalesce(u.sin_conf, 0), 'ultimo_pago', u.ult,
             'dias_pendientes', (select count(*) from pc where pc.cedula = t.cedula and pc.pend > 0),
             'debe_desde', (select min(pc.fecha) from pc where pc.cedula = t.cedula and pc.pend > 0),
             'buses', (select string_agg(distinct pc.movil, ', ') from pc where pc.cedula = t.cedula and pc.pend > 0))
           order by greatest(t.tc - coalesce(u.ta, 0), 0) desc, nom.nombre), '[]'::jsonb)
      from t left join u on u.cedula = t.cedula left join nom on nom.cedula = t.cedula));
end $function$;
revoke all on function public.cartera_conductores() from public, anon;
grant execute on function public.cartera_conductores() to authenticated;

create or replace function public.cartera_conductor(p_cedula text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  return public._cartera(v_ced) || jsonb_build_object('cedula', v_ced,
    'nombre', (select l.conductor from public.liquidaciones l where l.conductor_cedula = v_ced
                order by l.fecha desc limit 1));
end $function$;
revoke all on function public.cartera_conductor(text) from public, anon;
grant execute on function public.cartera_conductor(text) to authenticated;

-- Lista de colillas: el estado del banco con la misma regla de la cartera (NO_APARECE solo si
-- ya está el extracto de ESE banco; hoy solo se carga el de Bogotá).
create or replace function public.colillas_listar(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_h date := coalesce(p_hasta, (now() at time zone 'America/Bogota')::date);
  v_d date := coalesce(p_desde, v_h - 30);
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  return jsonb_build_object('ok', true, 'desde', v_d, 'hasta', v_h,
    'filas', (select coalesce(jsonb_agg(x order by x.creado_en desc), '[]'::jsonb) from (
      select c.id, c.creado_en, to_char(c.creado_en at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI') as enviada,
             c.cedula, c.nombre, c.movil, c.fecha, c.valor, c.valor_a_mano, c.referencia, c.ref_cedula,
             c.comprobante, c.banco, c.ocr_confianza, c.cubre, c.veredicto, c.faltante, c.sobrante,
             b.fecha as banco_fecha,
             case when b.id is not null then 'CONFIRMADA'
                  when public._banco_clave(c.banco) is not null
                   and exists (select 1 from public.recaudos_banco r where r.fecha = c.fecha
                                  and public._banco_clave(r.banco) = public._banco_clave(c.banco))
                   and exists (select 1 from public.recaudos_banco r where r.fecha = c.fecha + 1
                                  and public._banco_clave(r.banco) = public._banco_clave(c.banco))
                       then 'NO_APARECE'
                  else 'FALTA_EXTRACTO' end as estado_banco
        from public.liq_colillas c
        left join lateral (
          select r.id, r.fecha from public.recaudos_banco r
           where r.cedula = c.cedula and r.valor = c.valor and r.fecha between c.fecha and c.fecha + 1
           order by r.fecha, r.id limit 1) b on true
       where c.fecha between v_d and v_h) x));
end $function$;
revoke all on function public.colillas_listar(date, date) from public, anon;
grant execute on function public.colillas_listar(date, date) to authenticated;

-- Para la planilla (sql/148): qué colillas pagaron cada liquidación, según el reparto de la
-- cartera. Antes de que arranque, lo que se guardó al enviar cada colilla.
create or replace function public.colillas_por_liquidacion(p_desde date, p_hasta date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_ini date := public._cartera_desde();
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  if v_ini is null then
    return jsonb_build_object('ok', true, 'por_key', (
      select coalesce(jsonb_object_agg(s.key, s.info), '{}'::jsonb) from (
        select x.key, jsonb_agg(jsonb_build_object('fecha', c.fecha, 'valor', x.aplicado,
                 'confirmada', exists (select 1 from public.recaudos_banco r
                                        where r.cedula = c.cedula and r.valor = c.valor
                                          and r.fecha between c.fecha and c.fecha + 1))
                 order by c.fecha) as info
          from public.liq_colillas c,
               jsonb_to_recordset(c.cubre) as x(key text, fecha date, aplicado bigint)
         where x.fecha between p_desde and p_hasta
         group by x.key) s));
  end if;
  return jsonb_build_object('ok', true, 'por_key', (
    with m as (select * from public._cartera_movs(v_ini)),
    c as (select * from m where m.clase = 'cargo' and m.fecha between p_desde and p_hasta),
    a as (select * from m where m.clase = 'colilla'),
    r as (select c.ref as key, a.fecha, a.estado, least(c.fin, a.fin) - greatest(c.ini, a.ini) as monto
            from c join a on a.cedula = c.cedula and a.ini < c.fin and a.fin > c.ini)
    select coalesce(jsonb_object_agg(s.key, s.info), '{}'::jsonb) from (
      select r.key, jsonb_agg(jsonb_build_object('fecha', r.fecha, 'valor', r.monto,
               'confirmada', r.estado = 'CONFIRMADA') order by r.fecha) as info
        from r group by r.key) s));
end $function$;
revoke all on function public.colillas_por_liquidacion(date, date) from public, anon;
grant execute on function public.colillas_por_liquidacion(date, date) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 6) Al publicar el link nuevo, lo de "una colilla por liquidación" sobra. Se borra ENTONCES
--    (no antes: el link publicado de sql/149 todavía lo usa):
--      drop function public.colilla_identificar(text, text);
--      drop function public.colilla_analizar(text, text, text, date, numeric, text);
--      drop function public.colilla_guardar(text, text, jsonb);
--      drop function public._colilla_veredicto(text, text, date, bigint, text);
--      drop function public._liq_cuenta(text, date, jsonb);
-- ---------------------------------------------------------------------------------------------
