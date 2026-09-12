-- 70: Restricciones por MODO (VIAJE / HORA) y amarradas a una TABLA/puesto (p. ej. Laureles).
--   MODO 'VIAJE' = ruta + hora de salida exacta (hora_viaje): no puede tomar ESE viaje (±30 min).
--   MODO 'HORA'  = franja [hora_inicial, hora_finalizacion]: no se despacha en ese lapso.
--   TABLA       = tabla de puesto donde aplica (public.puestos.tabla, p. ej. 'laureles'); null = todas.

alter table public.restricciones_rutas
  add column if not exists modo       text check (modo in ('VIAJE','HORA')),
  add column if not exists tabla      text,
  add column if not exists hora_viaje time;

-- Backfill del histórico (no bloquea porque son fechas pasadas; es solo para consistencia/consulta):
update public.restricciones_rutas set modo = 'VIAJE' where modo is null;              -- las viejas restringen un viaje puntual
update public.restricciones_rutas set hora_viaje = hora_inicial
  where modo = 'VIAJE' and hora_viaje is null and hora_inicial is not null;
update public.restricciones_rutas set tabla = 'laureles'
  where tabla is null and (ruta ilike '%laurel%' or ruta_restringida in ('190','191','192','193'));

-- Nueva función de bloqueo (5 args): añade la TABLA y respeta el MODO. Se reemplaza la de 4 args.
drop function if exists public.restriccion_bloqueo(text,text,date,time);
create or replace function public.restriccion_bloqueo(
  p_movil text, p_ruta text, p_fecha date default null, p_hora time default null, p_tabla text default null)
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
     and ruta_restringida is not null
     and public._norm_ruta(ruta_restringida) = public._norm_ruta(p_ruta)
     -- amarre a la tabla/puesto: si la restricción tiene tabla, debe coincidir con la del despacho
     and ( tabla is null or p_tabla is null or lower(trim(tabla)) = lower(trim(p_tabla)) )
     -- ventana según el modo
     and (
       case
         when modo = 'HORA' then
           ( hora_inicial is null or hora_finalizacion is null
             or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) )
         when modo = 'VIAJE' then
           ( coalesce(hora_viaje, hora_inicial) is null
             or v_hora between (coalesce(hora_viaje, hora_inicial) - interval '30 minutes')
                           and (coalesce(hora_viaje, hora_inicial) + interval '30 minutes') )
         else true   -- sin modo: bloquea todo el día en esa ruta/tabla
       end
     )
   order by id desc limit 1;
  if r.id is null then return jsonb_build_object('bloqueado', false); end if;
  return jsonb_build_object('bloqueado', true, 'id', r.id, 'movil', r.vehiculo,
    'ruta', r.ruta_restringida, 'modo', r.modo, 'tabla', r.tabla, 'viaje', r.viajes_hora,
    'novedad', r.novedad, 'fecha', r.fecha_restriccion,
    'hora_viaje', r.hora_viaje, 'hora_ini', r.hora_inicial, 'hora_fin', r.hora_finalizacion);
end $$;
revoke all on function public.restriccion_bloqueo(text,text,date,time,text) from public;
grant execute on function public.restriccion_bloqueo(text,text,date,time,text) to authenticated;
