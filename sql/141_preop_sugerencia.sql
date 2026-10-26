-- 141_preop_sugerencia.sql
-- "debe de poner en la preoperacional lo que esta en las liquidaciones, para que el conductor
--  que por cedula ingrese tenga todo listo para poder hacer eso" (24/10/2026).
--
-- QUE HACE: al escribir la cedula, el preoperacional ya le propone SU bus. El conductor solo
-- confirma y pasa derecho a las preguntas, sin buscar en la lista de 315 ni leer el QR.
--
-- DE DONDE SALE EL BUS. Se midieron las fuentes contra lo que los conductores despacharon de
-- verdad del 20 al 22/10/2026 (3.280 despachos con cedula identificada):
--
--   * Ultima LIQUIDACION  -> acierta 813 de 1.264 (64%), y solo cubre 1.264 de 3.280 (39%).
--   * Ultimo DESPACHO     -> acierta 2.857 de 3.267 (87%), y cubre 3.267 de 3.280 (99,6%).
--
-- Las liquidaciones son de 58 vehiculos de un solo propietario: por eso cubren poco. Se usan
-- las DOS, en orden de confianza, y la pantalla dice de donde salio la sugerencia para que el
-- conductor sepa que esta confirmando:
--   1) el despacho de HOY, si ya lo despacharon  -> es el bus exacto, no una suposicion
--   2) el ultimo despacho de los ultimos 30 dias -> 87% de acierto
--   3) la ultima liquidacion de los ultimos 60   -> 64%, solo para los que no tienen despacho
--
-- ES UNA SUGERENCIA, NUNCA UNA SELECCION AUTOMATICA. Uno de cada ocho conductores cambia de
-- carro; si el bus se eligiera solo, se estarian firmando revisiones del vehiculo equivocado,
-- que es justo lo que la Resolucion 315 trata de evitar. En la pantalla hay que tocar "Si, voy
-- en este" y al lado esta "Es otro bus".
--
-- LO QUE NO SE DEVUELVE: nada de plata. El enlace del preoperacional es publico (anon) y los
-- valores liquidados son del propietario, no del conductor. Solo viaja el numero del bus y su
-- placa, que es lo unico que hace falta para la revision.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

create or replace function public.preop_identificar(p_cedula text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ced    text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nombre text;
  v_preg   jsonb;
  v_hoy    date := (now() at time zone 'America/Bogota')::date;
  v_cond   bigint;
  v_mov    text; v_pla text; v_org text; v_cuando date;
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

  return jsonb_build_object(
    'ok', true,
    'nombre', v_nombre,
    'preguntas', coalesce(v_preg, '[]'::jsonb),
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

revoke all on function public.preop_identificar(text) from public;
grant execute on function public.preop_identificar(text) to anon, authenticated;

-- Comprobacion (solo lectura): cobertura de la sugerencia sobre los conductores activos
with act as (
  select regexp_replace(coalesce(cedula, ''), '\D', '', 'g') as ced, nombre
    from public.perfilsociodemografico
   where estado = 'ACTIVO' and cargo = 'CONDUCTOR'
),
con as (
  select a.ced, (select c.id from public.conductores c
                  where public._nom_cmp(c.nombre) = public._nom_cmp(a.nombre) limit 1) as cid
    from act a
)
select 'conductores activos' as dato, count(*)::text as valor from con
union all
select 'con bus sugerido por despacho (30 dias)',
       (select count(*)::text from con c
         where c.cid is not null
           and exists (select 1 from public.despachos d
                        where d.conductor_id = c.cid
                          and d.fecha >= (now() at time zone 'America/Bogota')::date - 30))
union all
select 'con bus sugerido por liquidacion (60 dias)',
       (select count(*)::text from con c
         where exists (select 1 from public.liquidaciones l
                        where regexp_replace(coalesce(l.conductor_cedula, ''), '\D', '', 'g') = c.ced
                          and l.fecha >= (now() at time zone 'America/Bogota')::date - 60))
union all
select 'la funcion ya devuelve sugerido',
       case when position('sugerido' in
                 pg_get_functiondef('public.preop_identificar(text)'::regprocedure)) > 0
            then 'si' else 'NO' end;
