-- 198 · 🪪 Categoría de licencia vs. clase de vehículo (módulo 🛡️ Seguridad vial)
--
-- Pedido (18/11/2026): "tenemos estos conductores, los únicos que tienen licencia C1; los demás deben
-- tener la licencia C2. Organiza esto y dale visualización a seguridad vial".
--
-- La categoría ya llega del libro de Gestión Humana (perfil_sync, sql/133) a
-- perfilsociodemografico.categoria_licencia. La clase del vehículo está en parque_automotor.clase_vehiculo.
--
-- Regla (servicio público, Ley 769/2002 y Res. 1500/2005):
--   microbús        → C1 basta (C2 y C3 también sirven)
--   bus y buseta    → C2 (C3, articulados, también sirve)
-- Solo LEE: no bloquea ni avisa en el despacho (el 17/11 se pidió no restringir por licencia).
--
-- Quién manejó qué: despachos.conductor_id → conductores.nombre → conductores_sonar (mismo nombre)
-- → cédula → perfil. Si SONAR no da cédula, se intenta por el nombre del perfil (si es único).
-- Solo cuentan las SALIDAS REALES: sin novedad (estado null) o con viaje en SONAR (sonar_regid);
-- "TALLER", "VACACIONES", "SIN CONDUCTOR"… son viajes que no se hicieron.
--
-- Ve: seguridad vial y admin (es_seguridad_vial). Devuelve nombre, cédula, código y vencimiento,
-- lo mismo que ya ven en vial_conductores (sql/157) y en las licencias; nada de salario ni salud.

create or replace function public.vial_licencias_categoria(p_dias int default 30)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_dias  int  := least(greatest(coalesce(p_dias, 30), 1), 90);
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  v_desde date;
  v_out   jsonb;
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial y administración.');
  end if;
  v_desde := v_hoy - (v_dias - 1);

  with
  -- Una fila por persona (la hoja trae varias vinculaciones): la ACTIVA y la más reciente
  per as (
    select distinct on (regexp_replace(coalesce(p.cedula, ''), '[^0-9]', '', 'g'))
           regexp_replace(coalesce(p.cedula, ''), '[^0-9]', '', 'g') ced,
           p.nombre, p.codigo, p.estado, p.fecha_retiro,
           nullif(upper(btrim(p.categoria_licencia)), '') cat,
           p.licencia_vencimiento vence,
           regexp_replace(upper(translate(p.nombre, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')), '[^A-Z]', '', 'g') n
      from public.perfilsociodemografico p
     where (p.cargo = 'CONDUCTOR' or p.tipo = 'CONDUCTOR')
       and regexp_replace(coalesce(p.cedula, ''), '[^0-9]', '', 'g') <> ''
     order by regexp_replace(coalesce(p.cedula, ''), '[^0-9]', '', 'g'),
              (p.estado = 'ACTIVO') desc, p.fecha_ingreso desc nulls last),
  per_n as (select n, min(ced) ced from per group by n having count(*) = 1),
  cs as (
    select regexp_replace(upper(translate(nombre, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')), '[^A-Z]', '', 'g') n,
           min(regexp_replace(coalesce(cedula, ''), '[^0-9]', '', 'g')) ced
      from public.conductores_sonar
     where regexp_replace(coalesce(cedula, ''), '[^0-9]', '', 'g') <> ''
     group by 1),
  -- Salidas reales del periodo, por conductor y bus
  dv as (
    select de.conductor_id cid, de.vehiculo_id vid, count(*)::int viajes, max(de.fecha) ultimo
      from public.despachos de
     where de.fecha between v_desde and v_hoy
       and de.despachado_en is not null
       and (de.estado is null or de.sonar_regid is not null)
       and de.conductor_id is not null and de.vehiculo_id is not null
     group by 1, 2),
  veh as (
    select v.id vid, btrim(v.numero) movil,
           lower(btrim(pa.clase_vehiculo)) clase,
           case lower(btrim(pa.clase_vehiculo)) when 'microbus' then 1 when 'bus' then 2 when 'buseta' then 2 end req
      from public.vehiculos v
      left join lateral (select clase_vehiculo from public.parque_automotor pa
                          where btrim(pa.numero_interno) = btrim(v.numero)
                          order by (pa.estado = 'Activo') desc limit 1) pa on true
     where v.id in (select vid from dv)),
  cond as (
    select co.id cid, co.nombre nombre_desp,
           coalesce(cs.ced, pn.ced) ced
      from public.conductores co
      left join cs   on cs.n = regexp_replace(upper(translate(co.nombre, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')), '[^A-Z]', '', 'g')
      left join per_n pn on pn.n = regexp_replace(upper(translate(co.nombre, 'áéíóúÁÉÍÓÚñÑüÜ', 'aeiouAEIOUnNuU')), '[^A-Z]', '', 'g')
     where co.id in (select cid from dv)),
  -- Cada viaje con la categoría del que manejaba y la que pide el bus
  x as (
    select dv.*, veh.movil, veh.clase, veh.req, cond.nombre_desp, cond.ced,
           per.nombre, per.codigo, per.estado, per.cat, per.vence,
           case per.cat when 'C1' then 1 when 'C2' then 2 when 'C3' then 3 end rango
      from dv
      join veh  on veh.vid = dv.vid
      join cond on cond.cid = dv.cid
      left join per on per.ced = cond.ced),
  -- Por persona (o por nombre del despacho si no se sabe quién es)
  porc as (
    select coalesce(ced, 'n:' || cid::text) k,
           max(coalesce(nombre, nombre_desp)) nombre, max(nombre_desp) nombre_desp, max(ced) ced,
           max(codigo) codigo, max(estado) estado, max(cat) cat, max(vence) vence, max(rango) rango,
           bool_or(nombre is not null) en_perfil,
           sum(viajes)::int viajes,
           (sum(viajes) filter (where req is not null and rango is not null and rango < req))::int viajes_no_hab,
           (sum(viajes) filter (where clase = 'microbus'))::int viajes_microbus,
           (sum(viajes) filter (where clase in ('bus', 'buseta')))::int viajes_bus,
           max(ultimo) ultimo,
           max(ultimo) filter (where req is not null and rango is not null and rango < req) ultimo_no_hab,
           string_agg(distinct movil || coalesce(' (' || clase || ')', ''), ', ')
             filter (where req is not null and rango is not null and rango < req) moviles_no_hab,
           string_agg(distinct movil, ', ') moviles
      from x group by 1)
  select jsonb_build_object(
    'ok', true, 'dias', v_dias, 'desde', v_desde, 'hasta', v_hoy,
    -- Conductores ACTIVOS en el perfil, por categoría
    'activos', (select jsonb_build_object(
        'C1', count(*) filter (where cat = 'C1'), 'C2', count(*) filter (where cat = 'C2'),
        'C3', count(*) filter (where cat = 'C3'),
        'otra', count(*) filter (where cat is not null and cat not in ('C1', 'C2', 'C3')),
        'sin', count(*) filter (where cat is null), 'total', count(*))
        from per where estado = 'ACTIVO'),
    'viajes', (select coalesce(sum(viajes), 0) from porc),
    -- 🚨 Manejaron un vehículo que su licencia no permite (C1 en bus o buseta)
    'no_habilitados', coalesce((select jsonb_agg(jsonb_build_object(
        'nombre', nombre, 'cedula', ced, 'codigo', codigo, 'estado', estado, 'categoria', cat, 'vence', vence,
        'viajes', viajes, 'viajes_no_hab', viajes_no_hab, 'ultimo', ultimo_no_hab, 'moviles', moviles_no_hab)
        order by viajes_no_hab desc, nombre)
        from porc where viajes_no_hab > 0), '[]'::jsonb),
    -- ⚠️ Despacharon y no se sabe su categoría (no están en el perfil o la hoja no la trae)
    'sin_categoria', coalesce((select jsonb_agg(jsonb_build_object(
        'nombre', nombre, 'nombre_despacho', nombre_desp, 'cedula', ced, 'en_perfil', en_perfil,
        'estado', estado, 'viajes', viajes, 'ultimo', ultimo, 'moviles', moviles)
        order by viajes desc, nombre)
        from porc where cat is null), '[]'::jsonb),
    -- Los de licencia C1 (activos, y los inactivos que igual despacharon en el periodo)
    'c1', coalesce((select jsonb_agg(jsonb_build_object(
        'nombre', p.nombre, 'cedula', p.ced, 'codigo', p.codigo, 'estado', p.estado, 'vence', p.vence,
        'viajes', coalesce(c.viajes, 0), 'viajes_microbus', coalesce(c.viajes_microbus, 0),
        'viajes_bus', coalesce(c.viajes_bus, 0), 'moviles', c.moviles)
        order by coalesce(c.viajes_bus, 0) desc, p.nombre)
        from per p left join porc c on c.ced = p.ced
       where p.cat = 'C1' and (p.estado = 'ACTIVO' or c.viajes > 0)), '[]'::jsonb),
    -- Los únicos vehículos que una C1 puede manejar
    'microbuses', coalesce((select jsonb_agg(jsonb_build_object(
        'movil', btrim(pa.numero_interno), 'placa', pa.placa, 'ruta', pa.ruta, 'sentados', pa.cap_sentados)
        order by btrim(pa.numero_interno))
        from public.parque_automotor pa
       where pa.estado = 'Activo' and lower(btrim(pa.clase_vehiculo)) = 'microbus'), '[]'::jsonb),
    'parque', (select jsonb_build_object(
        'bus', count(*) filter (where lower(btrim(clase_vehiculo)) = 'bus'),
        'buseta', count(*) filter (where lower(btrim(clase_vehiculo)) = 'buseta'),
        'microbus', count(*) filter (where lower(btrim(clase_vehiculo)) = 'microbus'),
        'otra', count(*) filter (where lower(btrim(coalesce(clase_vehiculo, ''))) not in ('bus', 'buseta', 'microbus')))
        from public.parque_automotor where estado = 'Activo'),
    -- Todos los conductores activos (y los que despacharon), para buscar y para el Excel
    'todos', coalesce((select jsonb_agg(jsonb_build_object(
        'nombre', p.nombre, 'cedula', p.ced, 'codigo', p.codigo, 'estado', p.estado, 'categoria', p.cat,
        'vence', p.vence, 'viajes', coalesce(c.viajes, 0), 'viajes_no_hab', coalesce(c.viajes_no_hab, 0))
        order by p.nombre)
        from per p left join porc c on c.ced = p.ced
       where p.estado = 'ACTIVO' or c.viajes > 0), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $fn$;

revoke all on function public.vial_licencias_categoria(int) from public, anon;
grant execute on function public.vial_licencias_categoria(int) to authenticated;
