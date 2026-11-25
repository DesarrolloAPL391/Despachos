-- 210: la restricción POR CONDUCTOR frena al conductor en TODAS las tablas (Despachos y las de puesto), en cualquier ruta
-- y en cualquier móvil, dentro de la franja (hora inicial–hora final) del día de la restricción.
-- Pedido del usuario (25/11/2026): "el bloqueo es por conductor: que no lo deje despachar ninguna ruta de acuerdo a los
-- horarios que se pongan".
-- Antes (sql/72) solo frenaba cuando se despachaba desde Despachos (p_tabla = 'despachos'): desde una tabla de puesto
-- (Laureles, 130, 193, 136II…; el 38 % de los despachos del 18 al 24/11) el conductor restringido salía sin problema.
-- Una restricción es POR CONDUCTOR cuando su tabla es 'despachos' (así la crea el formulario). Las de PUESTO (móvil + ruta +
-- VIAJE/HORA) siguen igual que antes, en su tabla.
-- Seguridad: las dos funciones estaban abiertas a anon (internet: el «revoke from public» de sql/72 no quita el grant que
-- Supabase le da a anon) y restricciones_movil_dia devolvía el correo y el celular del propietario. Quedan solo para
-- usuarios con sesión y el aviso ya no trae los datos del propietario (la app no los usa).
-- DESHACER: volver a las definiciones de sql/72 (y grant execute ... to anon, si de verdad se quisiera).

create or replace function public.restriccion_bloqueo(
  p_movil text, p_ruta text, p_fecha date default null, p_hora time default null,
  p_tabla text default null, p_conductor text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare r public.restricciones_rutas;
        v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
        v_hora  time := coalesce(p_hora, (now() at time zone 'America/Bogota')::time);
        v_cond  text := public._norm_txt(p_conductor);
begin
  -- Sin conductor ni móvil no hay con qué comparar.
  if v_cond = '' and coalesce(trim(p_movil), '') = '' then
    return jsonb_build_object('bloqueado', false);
  end if;
  select * into r from public.restricciones_rutas
   where estado = 'VIGENTE'
     and fecha_restriccion = v_fecha
     and (case
       when lower(coalesce(tabla, '')) = 'despachos' then
         -- POR CONDUCTOR (sql/210): en CUALQUIER tabla, ruta y móvil, dentro de la franja (sin franja = todo el día)
         ( v_cond <> ''
           and public._norm_txt(conductor) = v_cond
           and ( hora_inicial is null or hora_finalizacion is null
                 or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) ) )
       else
         -- PUESTO (como en sql/72): en su tabla, mismo móvil + misma ruta + viaje o franja según el modo
         ( (tabla is null or p_tabla is null or lower(trim(tabla)) = lower(trim(p_tabla)))
           and coalesce(trim(p_movil), '') <> ''
           and trim(vehiculo) = trim(p_movil)
           and ruta_restringida is not null
           and public._norm_ruta(ruta_restringida) = public._norm_ruta(p_ruta)
           and ( case
                   when modo = 'HORA' then
                     ( hora_inicial is null or hora_finalizacion is null
                       or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) )
                   when modo = 'VIAJE' then
                     ( coalesce(hora_viaje, hora_inicial) is null
                       or v_hora between (coalesce(hora_viaje, hora_inicial) - interval '30 minutes')
                                     and (coalesce(hora_viaje, hora_inicial) + interval '30 minutes') )
                   else true
                 end ) )
     end)
   order by id desc
   limit 1;
  if r.id is null then
    return jsonb_build_object('bloqueado', false);
  end if;
  return jsonb_build_object('bloqueado', true, 'id', r.id, 'movil', r.vehiculo, 'conductor', r.conductor,
    'ruta', r.ruta_restringida, 'modo', r.modo, 'tabla', r.tabla, 'viaje', r.viajes_hora, 'novedad', r.novedad,
    'fecha', r.fecha_restriccion, 'hora_viaje', r.hora_viaje, 'hora_ini', r.hora_inicial, 'hora_fin', r.hora_finalizacion);
end;
$$;

-- El aviso al elegir móvil/conductor (ya era por conductor en cualquier tabla): igual, pero sin los datos del propietario.
create or replace function public.restricciones_movil_dia(
  p_movil text, p_conductor text default null, p_fecha date default null)
returns setof public.restricciones_rutas
language plpgsql stable security definer set search_path to 'public'
as $$
declare r public.restricciones_rutas;
begin
  for r in
    select * from public.restricciones_rutas
     where estado = 'VIGENTE'
       and fecha_restriccion = coalesce(p_fecha, (now() at time zone 'America/Bogota')::date)
       and (
         ( lower(coalesce(tabla,'')) <> 'despachos' and trim(vehiculo) = trim(p_movil) )
         or ( lower(coalesce(tabla,'')) = 'despachos'
              and public._norm_txt(conductor) <> ''
              and public._norm_txt(conductor) = public._norm_txt(p_conductor) )
       )
     order by hora_inicial nulls last, id
  loop
    r.propietario := null; r.correo_propietario := null; r.celular_propietario := null;
    return next r;
  end loop;
end;
$$;

revoke all on function public.restriccion_bloqueo(text,text,date,time,text,text) from public, anon;
grant execute on function public.restriccion_bloqueo(text,text,date,time,text,text) to authenticated;
revoke all on function public.restricciones_movil_dia(text,text,date) from public, anon;
grant execute on function public.restricciones_movil_dia(text,text,date) to authenticated;
