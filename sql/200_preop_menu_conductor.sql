-- 200: Menu del conductor dentro del link del preoperacional (pedido del 23/11/2026):
--   "tenemos que incluir en la preoperacional como un menu donde esten los permisos, las vacaciones
--    para los conductores y los documentos del vehiculo".
-- Decisiones (AskUserQuestion, 23/11): menu DESPUES de la cedula; documentos = fechas y estado (sin la
-- foto/PDF, que trae datos del propietario); permisos y vacaciones siguen pidiendo la fecha de nacimiento.
--
-- 1) preop_identificar: se le AGREGAN dos llaves (hoy, bus_hoy). Lo que ya devolvia queda igual, asi
--    que la pagina publicada sigue funcionando sin cambios.
-- 2) preop_docs_bus(cedula, movil): nueva, anonima, solo datos del vehiculo.
--
-- Deshacer: volver a crear preop_identificar desde scratchpad/preop/menu200/preop_identificar_actual.sql
--           y drop function public.preop_docs_bus(text, text);

set lock_timeout = '5s';

CREATE OR REPLACE FUNCTION public.preop_identificar(p_cedula text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ced    text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nombre text;
  v_preg   jsonb;
  v_hoy    date := (now() at time zone 'America/Bogota')::date;
  v_cond   bigint;
  v_mov    text; v_pla text; v_org text; v_cuando date;
  v_hoy_mios jsonb; v_bus_hoy text;   -- 200: para el menu del conductor
begin
  if length(v_ced) < 4 then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu número de cédula.');
  end if;

  select p.nombre into v_nombre
    from public.perfilsociodemografico p
   where regexp_replace(coalesce(p.cedula, ''), '\D', '', 'g') = v_ced
     and p.estado = 'ACTIVO'
     and p.cargo  = 'CONDUCTOR'
   limit 1;

  if v_nombre is null then
    return jsonb_build_object('ok', false, 'error',
      'Esa cédula no aparece como conductor activo. Revísala o avísale a Gestión Humana.');
  end if;

  select jsonb_agg(jsonb_build_object('orden', orden, 'texto', texto, 'corto', corto,
                                      'icono', icono, 'grupo', grupo) order by orden)
    into v_preg
    from public.preoperacional_preguntas where activa;

  -- El conductor en la tabla de despachos se identifica por nombre; se resuelve una sola vez
  -- (404 filas) para despues buscar por conductor_id, que es lo barato.
  select c.id into v_cond
    from public.conductores c
   where public._nom_cmp(c.nombre) = public._nom_cmp(v_nombre)
   limit 1;

  if v_cond is not null then
    -- 1) Ya lo despacharon hoy: ese es el bus, sin adivinar nada.
    select btrim(v.numero), v.placa, 'hoy', d.fecha
      into v_mov, v_pla, v_org, v_cuando
      from public.despachos d
      join public.vehiculos v on v.id = d.vehiculo_id
     where d.conductor_id = v_cond
       and d.fecha = v_hoy
       and btrim(coalesce(v.numero, '')) <> ''
     order by d.hora desc nulls last
     limit 1;

    -- 2) El ultimo que manejo (87% de acierto)
    if v_mov is null then
      select btrim(v.numero), v.placa, 'ultimo', d.fecha
        into v_mov, v_pla, v_org, v_cuando
        from public.despachos d
        join public.vehiculos v on v.id = d.vehiculo_id
       where d.conductor_id = v_cond
         and d.fecha between v_hoy - 30 and v_hoy
         and btrim(coalesce(v.numero, '')) <> ''
       order by d.fecha desc, d.hora desc nulls last
       limit 1;
    end if;
  end if;

  -- 3) La liquidacion, para los que no tienen despacho reciente
  if v_mov is null then
    select l.movil, null, 'liquidacion', l.fecha
      into v_mov, v_pla, v_org, v_cuando
      from public.liquidaciones l
     where regexp_replace(coalesce(l.conductor_cedula, ''), '\D', '', 'g') = v_ced
       and l.fecha >= v_hoy - 60
     order by l.fecha desc
     limit 1;

    -- La liquidacion no trae placa: se busca en el parque por numero interno.
    if v_mov is not null and v_pla is null then
      select v.placa into v_pla from public.vehiculos v
       where btrim(v.numero) = btrim(v_mov) limit 1;
    end if;
  end if;

  -- Solo se propone un bus que siga ACTIVO en el parque: es la misma lista que puede elegir
  -- (preop_buses). Un carro dado de baja no se puede revisar, y proponerlo seria peor que no
  -- proponer nada.
  if v_mov is not null and not exists (
       select 1 from public.parque_automotor
        where estado = 'Activo' and btrim(coalesce(numero_interno, '')) = btrim(v_mov)) then
    v_mov := null; v_pla := null; v_org := null;
  end if;

  -- 200: el menu del conductor dice si ya hizo el preoperacional de hoy (y de que bus),
  -- y si el bus propuesto ya lo tiene (la regla del despacho es por bus: vale el de cualquier conductor).
  select coalesce(jsonb_agg(jsonb_build_object(
           'movil', btrim(p.movil),
           'hora', to_char(p.creado_en at time zone 'America/Bogota', 'HH24:MI'),
           'novedades', coalesce(p.novedades, 0)) order by p.creado_en), '[]'::jsonb)
    into v_hoy_mios
    from public.preoperacionales p
   where p.fecha = v_hoy
     and regexp_replace(coalesce(p.cedula, ''), '\D', '', 'g') = v_ced;

  if v_mov is not null then
    select to_char(min(p.creado_en) at time zone 'America/Bogota', 'HH24:MI') into v_bus_hoy
      from public.preoperacionales p
     where p.fecha = v_hoy and btrim(p.movil) = btrim(v_mov);
  end if;

  return jsonb_build_object(
    'ok', true,
    'nombre', v_nombre,
    'preguntas', coalesce(v_preg, '[]'::jsonb),
    'hoy', v_hoy_mios,          -- 200: sus preoperacionales de hoy [{movil, hora, novedades}]
    'bus_hoy', v_bus_hoy,       -- 200: hora del preoperacional de hoy del bus propuesto (null = no tiene)
    'sugerido', case when v_mov is null then null else jsonb_build_object(
        'movil', v_mov,
        'placa', v_pla,
        'origen', v_org,
        'texto', case v_org
                   when 'hoy'   then 'Es el bus que te despacharon hoy'
                   when 'ultimo' then 'Es el último bus que manejaste, el ' ||
                                      to_char(v_cuando, 'DD/MM')
                   else 'Es el bus de tu última liquidación, del ' ||
                        to_char(v_cuando, 'DD/MM')
                 end) end);
end $function$;

create or replace function public.preop_docs_bus(p_cedula text, p_movil text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $function$
-- Documentos del bus para el menu del conductor (link publico del preoperacional).
-- Mismo candado que preop_identificar: solo un CONDUCTOR ACTIVO del perfil. Devuelve SOLO datos del
-- vehiculo (numero, vencimiento, aseguradora), nunca del propietario: las fechas de SOAT y tecnomecanica
-- son publicas en el RUNT por placa, y el conductor esta obligado a portar estos documentos.
declare
  v_ced  text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_mov  text := btrim(coalesce(p_movil, ''));
  v_hoy  date := (now() at time zone 'America/Bogota')::date;
  pa     public.parque_automotor%rowtype;
  v_prev jsonb;
  v_rev  text[];
begin
  if length(v_ced) < 4 or not exists (
       select 1 from public.perfilsociodemografico p
        where regexp_replace(coalesce(p.cedula, ''), '\D', '', 'g') = v_ced
          and p.estado = 'ACTIVO' and p.cargo = 'CONDUCTOR') then
    return jsonb_build_object('ok', false, 'error',
      'Esa cédula no aparece como conductor activo. Revísala o avísale a Gestión Humana.');
  end if;
  if v_mov = '' then
    return jsonb_build_object('ok', false, 'error', 'Elige el bus.');
  end if;

  select * into pa from public.parque_automotor
   where estado = 'Activo' and btrim(coalesce(numero_interno, '')) = v_mov
   limit 1;
  if pa.id is null then
    return jsonb_build_object('ok', false, 'error', 'El bus ' || v_mov || ' no está activo en el parque.');
  end if;

  -- Proxima cita de preventiva que sigue pendiente (de hoy en adelante)
  select jsonb_build_object('fecha', pr.fecha, 'lugar', nullif(btrim(pr.lugar), ''), 'dias', pr.fecha - v_hoy)
    into v_prev
    from public.preventivas pr
   where btrim(pr.interno) = v_mov and pr.fecha >= v_hoy
     and pr.resultado not in ('APROBADO', 'RECHAZADO')
   order by pr.fecha, pr.id
   limit 1;

  -- Documentos vencidos que ya se subieron y esperan la revision de operaciones (sql/66)
  select coalesce(array_agg(distinct d.tipo), '{}') into v_rev
    from public.doc_desbloqueos d
   where d.vehiculo_id = pa.id and d.estado = 'PENDIENTE';

  return jsonb_build_object(
    'ok', true,
    'movil', v_mov,
    'placa', pa.placa,
    'clase', pa.clase_vehiculo,
    'marca', pa.marca,
    'modelo', pa.modelo,
    'hoy', v_hoy,
    'docs', jsonb_build_array(
      jsonb_build_object('tipo', 'soat', 'nombre', 'SOAT',
        'numero', nullif(btrim(pa.num_soat), ''), 'entidad', nullif(btrim(pa.aseguradora_soat), ''),
        'vence', pa.vence_soat, 'dias', pa.vence_soat - v_hoy,
        'en_revision', 'soat' = any(v_rev)),
      jsonb_build_object('tipo', 'tecnomecanica', 'nombre', 'Revisión técnico-mecánica',
        'numero', nullif(btrim(pa.num_tecnomecanica), ''),
        'vence', pa.vence_tecnomecanica, 'dias', pa.vence_tecnomecanica - v_hoy,
        'en_revision', 'tecnomecanica' = any(v_rev)),
      jsonb_build_object('tipo', 'tarjeta_operacion', 'nombre', 'Tarjeta de operación',
        'numero', nullif(btrim(pa.num_tarjeta_operacion), ''),
        'vence', pa.vence_tarjeta_operacion, 'dias', pa.vence_tarjeta_operacion - v_hoy,
        'en_revision', 'tarjeta_operacion' = any(v_rev))),
    'preventiva', v_prev,
    'preventiva_suspendido', public.preventiva_suspendido(v_mov));
end $function$;

revoke all on function public.preop_docs_bus(text, text) from public;
grant execute on function public.preop_docs_bus(text, text) to anon, authenticated;
