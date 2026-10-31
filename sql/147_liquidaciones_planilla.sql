-- ============================================================================================
-- 147 · LIQUIDACIONES — lo que hay que corregir y la fila completa de la planilla
--
-- Talento Humano y administración llenan a mano dos planillas de Excel (CENTRO y METRO) con
-- datos que la app ya tiene regados: la liquidación viene de la hoja (sql/138-139), los
-- pasajeros del sensor de SONAR (`pasajeros_dia`) y la consignación del extracto del banco
-- (`recaudos_banco`, sql/142). Aquí se juntan en UNA fila por liquidación, que es la que
-- alimenta tanto la pantalla como el Excel: un solo criterio, no dos.
--
-- Lo que NO se inventa:
--   · El desglose por tipo de tarjeta (Integrado Cívica / Pleno Cívica / Tarjeta Conductor)
--     que pide la planilla METRO no está en ninguna fuente que tengamos. Sale vacío, a
--     propósito, hasta que llegue el archivo del Metro.
--   · La consignación NO se asigna a una liquidación concreta: se muestran las del mismo
--     conductor en la ventana del día, y la diferencia. Emparejar 1 a 1 sin la regla
--     confirmada sería inventar un cuadre.
--
-- Se aplica sobre sql/138-140 (liquidaciones) y sql/142 (recaudos).
-- ============================================================================================

-- 1) Lo que hay que corregir EN LA HOJA ---------------------------------------------------------
-- La hoja de Google es la fuente: corregir aquí sería tapar el error hasta la próxima
-- sincronización. Esto solo lo señala para que alguien lo arregle donde corresponde.
create or replace function public.liquidaciones_revisar()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_out jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  select jsonb_build_object(
    'ok', true,
    -- unidades - descontar <> total_liquidar: la propia hoja se contradice
    'no_cuadran', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'key', l.key, 'fecha', l.fecha, 'movil', l.movil, 'ruta', l.ruta,
               'conductor', l.conductor,
               'unidades', l.unidades, 'descontar', l.descontar,
               'deberia', l.unidades - l.descontar, 'dice', l.total_liquidar)
             order by l.fecha desc), '[]'::jsonb)
        from public.liquidaciones l where not l.cuadra),
    -- Sin cédula no se puede cruzar con el banco ni con la nómina. Se agrupa primero y
    -- después se busca en el perfil: la búsqueda necesita el nombre ya agrupado.
    'sin_cedula', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'conductor', g.conductor, 'filas', g.filas,
               'desde', g.desde, 'hasta', g.hasta, 'moviles', g.moviles,
               -- ¿se puede sacar del perfil por el nombre?
               'en_perfil', (select count(*) from public.perfilsociodemografico p
                              where public._nom_cmp(p.nombre) = g.nom))
             order by g.desde), '[]'::jsonb)
        from (
          select public._nom_cmp(l.conductor) as nom, max(l.conductor) as conductor,
                 count(*) as filas, min(l.fecha) as desde, max(l.fecha) as hasta,
                 string_agg(distinct l.movil, ', ') as moviles
            from public.liquidaciones l
           where coalesce(l.conductor_cedula, '') = ''
           group by public._nom_cmp(l.conductor)) g),
    'total_no_cuadran', (select count(*) from public.liquidaciones where not cuadra),
    'total_sin_cedula', (select count(*) from public.liquidaciones
                          where coalesce(conductor_cedula, '') = '')
  ) into v_out;
  return v_out;
end $function$;
revoke all on function public.liquidaciones_revisar() from public, anon;
grant execute on function public.liquidaciones_revisar() to authenticated;

comment on function public.liquidaciones_revisar() is
  'Lo que hay que corregir en la hoja de liquidaciones: filas que no cuadran y conductores sin cedula.';

-- 2) La fila completa de la planilla -------------------------------------------------------------
-- Una fila por liquidación (vehículo + fecha + ruta) con todo lo que piden CENTRO y METRO.
-- `p_punto` filtra por punto de liquidación, que es lo que separa una planilla de la otra.
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
  v_out jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  -- Un rango abierto traería años enteros a una pantalla: se acota.
  if v_h - v_d > 180 then
    return jsonb_build_object('ok', false, 'error', 'El rango no puede pasar de 180 días.');
  end if;

  with liq as (
    select l.*,
           regexp_replace(coalesce(l.conductor_cedula, ''), '[^0-9]', '', 'g') as ced
      from public.liquidaciones l
     where l.fecha between v_d and v_h
       and (p_punto is null or btrim(p_punto) = '' or l.punto = btrim(p_punto))
       and (p_movil is null or btrim(p_movil) = '' or l.movil = btrim(p_movil))
  ),
  -- Pasajeros del sensor: SONAR cuenta por carro y día, no por ruta. Si el carro hizo dos
  -- rutas ese día, el sensor es el MISMO número para las dos: por eso se marca `pax_dia`,
  -- para que nadie lo sume dos veces al armar la planilla.
  pax as (
    select p.movil, p.fecha, p.subidas
      from public.pasajeros_dia p
     where p.fecha between v_d and v_h
  ),
  -- Consignaciones del conductor ese día o el siguiente (se consigna al día siguiente).
  -- NO se asigna a una liquidación: se informa lo que hay y quien cuadra decide.
  con as (
    select r.cedula as ced, r.fecha, sum(r.valor)::bigint as valor,
           count(*)::int as veces, max(r.banco) as banco
      from public.recaudos_banco r
     where r.cedula is not null and r.fecha between v_d and v_h + 1
     group by r.cedula, r.fecha
  ),
  filas as (
    select
      l.key, l.fecha, l.movil, l.ruta, l.punto, l.viajes,
      l.conductor, l.conductor_cedula, l.propietario,
      l.unidades, l.descontar, l.total_liquidar, l.liquidar, l.dinero,
      l.cuadra,
      (select px.subidas from pax px where px.movil = l.movil and px.fecha = l.fecha) as pax_sensor,
      -- cuántas liquidaciones tiene ese carro ese día (para saber si el pax del sensor se reparte)
      count(*) over (partition by l.movil, l.fecha) as liq_del_dia,
      (select c.valor from con c where c.ced = l.ced and c.fecha = l.fecha)     as consig_mismo_dia,
      (select c.valor from con c where c.ced = l.ced and c.fecha = l.fecha + 1) as consig_dia_siguiente,
      (select c.banco from con c where c.ced = l.ced and c.fecha in (l.fecha, l.fecha + 1)
        order by c.fecha limit 1)                                               as banco
      from liq l
  )
  select jsonb_build_object(
    'ok', true,
    'desde', v_d, 'hasta', v_h,
    'punto', p_punto,
    'total', (select count(*) from filas),
    'resumen', jsonb_build_object(
      'dinero',      (select coalesce(sum(dinero), 0) from filas),
      'pax',         (select coalesce(sum(unidades), 0) from filas),
      'consignado',  (select coalesce(sum(coalesce(consig_mismo_dia, 0)
                                        + coalesce(consig_dia_siguiente, 0)), 0) from filas),
      'con_pax_sensor', (select count(*) filter (where pax_sensor is not null) from filas),
      'sin_cuadrar',    (select count(*) filter (where not cuadra) from filas)),
    'filas', (select coalesce(jsonb_agg(to_jsonb(f) order by f.fecha, f.movil, f.ruta), '[]'::jsonb)
                from filas f)
  ) into v_out;
  return v_out;
end $function$;
revoke all on function public.liquidaciones_planilla(date, date, text, text) from public, anon;
grant execute on function public.liquidaciones_planilla(date, date, text, text) to authenticated;

comment on function public.liquidaciones_planilla(date, date, text, text) is
  'Una fila por liquidacion con lo que piden las planillas CENTRO y METRO: liquidacion + pax del sensor + consignacion del banco.';
