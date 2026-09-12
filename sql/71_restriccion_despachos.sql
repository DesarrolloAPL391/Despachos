-- 71: Restricciones en la vista general DESPACHOS: por VEHÍCULO + CONDUCTOR + fecha + franja horaria.
--   tabla = 'despachos'  -> bloquea cuando se despacha ESE móvil CON ESE conductor en la franja.
--   tabla = puesto (laureles, t_130, …) -> sigue por RUTA (sql/69,70).

-- Normalizador de texto (para comparar nombres de conductor): mayúsculas, sin espacios repetidos.
create or replace function public._norm_txt(t text)
returns text language sql immutable as $$
  select upper(regexp_replace(trim(coalesce(t,'')), '\s+', ' ', 'g'));
$$;

-- Nueva función de bloqueo (6 args): añade p_conductor y el caso 'despachos'. Reemplaza la de 5 args.
drop function if exists public.restriccion_bloqueo(text,text,date,time,text);
create or replace function public.restriccion_bloqueo(
  p_movil text, p_ruta text, p_fecha date default null, p_hora time default null,
  p_tabla text default null, p_conductor text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare r public.restricciones_rutas;
        v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
        v_hora  time := coalesce(p_hora,  (now() at time zone 'America/Bogota')::time);
begin
  if coalesce(trim(p_movil),'') = '' then return jsonb_build_object('bloqueado', false); end if;
  select * into r
    from public.restricciones_rutas
   where estado = 'VIGENTE'
     and trim(vehiculo) = trim(p_movil)
     and fecha_restriccion = v_fecha
     and ( tabla is null or p_tabla is null or lower(trim(tabla)) = lower(trim(p_tabla)) )
     and (
       case
         when lower(coalesce(tabla,'')) = 'despachos' then
           -- DESPACHOS: mismo conductor + dentro de la franja [hora_inicial, hora_finalizacion]
           ( public._norm_txt(conductor) <> ''
             and public._norm_txt(conductor) = public._norm_txt(p_conductor)
             and ( hora_inicial is null or hora_finalizacion is null
                   or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) ) )
         else
           -- PUESTO: misma ruta + ventana/viaje según el modo
           ( ruta_restringida is not null
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
