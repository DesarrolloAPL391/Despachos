-- 72: En DESPACHOS la restricción sigue al CONDUCTOR (cualquier móvil).
--   Motivo: un conductor castigado no debe poder despacharse cambiándose a otro vehículo.
--   Regla Despachos: si el conductor tiene restricción VIGENTE hoy, no puede despacharse en
--     NINGÚN móvil dentro de la franja [hora_inicial, hora_finalizacion]. El móvil deja de importar.
--   Tablas de puesto (laureles, t_130, …): SIN cambios -> por móvil + ruta + modo (sql/69,70,71).

-- ---- Bloqueo (6 args). Se mueve el match del móvil al caso de puesto; despachos = por conductor.
drop function if exists public.restriccion_bloqueo(text,text,date,time,text,text);
create or replace function public.restriccion_bloqueo(
  p_movil text, p_ruta text, p_fecha date default null, p_hora time default null,
  p_tabla text default null, p_conductor text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare r public.restricciones_rutas;
        v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
        v_hora  time := coalesce(p_hora,  (now() at time zone 'America/Bogota')::time);
        v_desp  boolean := lower(coalesce(trim(p_tabla),'')) = 'despachos';
begin
  -- Despachos exige conductor; puesto exige móvil. Sin el dato clave, no hay bloqueo.
  if v_desp then
    if public._norm_txt(p_conductor) = '' then return jsonb_build_object('bloqueado', false); end if;
  else
    if coalesce(trim(p_movil),'') = '' then return jsonb_build_object('bloqueado', false); end if;
  end if;
  select * into r
    from public.restricciones_rutas
   where estado = 'VIGENTE'
     and fecha_restriccion = v_fecha
     and ( tabla is null or p_tabla is null or lower(trim(tabla)) = lower(trim(p_tabla)) )
     and (
       case
         when lower(coalesce(tabla,'')) = 'despachos' then
           -- DESPACHOS: mismo conductor (en cualquier móvil) + dentro de la franja
           ( public._norm_txt(conductor) <> ''
             and public._norm_txt(conductor) = public._norm_txt(p_conductor)
             and ( hora_inicial is null or hora_finalizacion is null
                   or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) ) )
         else
           -- PUESTO: mismo móvil + misma ruta + ventana/viaje según el modo
           ( trim(vehiculo) = trim(p_movil)
             and ruta_restringida is not null
             and public._norm_ruta(ruta_restringida) = public._norm_ruta(p_ruta)
             and (
               case
                 when modo = 'HORA' then
                   ( hora_inicial is null or hora_finalizacion is null
                     or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) )
                 when modo = 'VIAJE' then
                   ( coalesce(hora_viaje, hora_inicial) is null
                     or v_hora between (coalesce(hora_viaje, hora_inicial) - interval '30 minutes')
                                   and (coalesce(hora_viaje, hora_inicial) + interval '30 minutes') )
                 else true
               end
             ) )
       end
     )
   order by id desc limit 1;
  if r.id is null then return jsonb_build_object('bloqueado', false); end if;
  return jsonb_build_object('bloqueado', true, 'id', r.id, 'movil', r.vehiculo,
    'conductor', r.conductor, 'ruta', r.ruta_restringida, 'modo', r.modo, 'tabla', r.tabla,
    'viaje', r.viajes_hora, 'novedad', r.novedad, 'fecha', r.fecha_restriccion,
    'hora_viaje', r.hora_viaje, 'hora_ini', r.hora_inicial, 'hora_fin', r.hora_finalizacion);
end $$;
revoke all on function public.restriccion_bloqueo(text,text,date,time,text,text) from public;
grant execute on function public.restriccion_bloqueo(text,text,date,time,text,text) to authenticated;

-- ---- Aviso al elegir móvil/conductor: puesto por MÓVIL, despachos por CONDUCTOR.
drop function if exists public.restricciones_movil_dia(text,date);
drop function if exists public.restricciones_movil_dia(text,text,date);
create or replace function public.restricciones_movil_dia(
  p_movil text, p_conductor text default null, p_fecha date default null)
returns setof public.restricciones_rutas
language sql stable security definer set search_path to 'public'
as $$
  select * from public.restricciones_rutas
   where estado = 'VIGENTE'
     and fecha_restriccion = coalesce(p_fecha, (now() at time zone 'America/Bogota')::date)
     and (
       ( lower(coalesce(tabla,'')) <> 'despachos' and trim(vehiculo) = trim(p_movil) )
       or ( lower(coalesce(tabla,'')) = 'despachos'
            and public._norm_txt(conductor) <> ''
            and public._norm_txt(conductor) = public._norm_txt(p_conductor) )
     )
   order by hora_inicial nulls last, id;
$$;
revoke all on function public.restricciones_movil_dia(text,text,date) from public;
grant execute on function public.restricciones_movil_dia(text,text,date) to authenticated;
