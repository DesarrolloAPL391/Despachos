-- 69: BLOQUEO de despacho por RESTRICCIÓN de ruta VIGENTE.
-- El castigo se cumple en fecha_restriccion, en la ventana [hora_inicial, hora_finalizacion],
-- SOLO en la ruta castigada (ruta_restringida). El bloqueo aplica a las restricciones nuevas
-- (fecha_restriccion = día del despacho); el histórico (fechas pasadas) no bloquea.

-- 1) Campo estructurado para la ruta castigada (hoy va embebida en viajes_hora en texto libre).
alter table public.restricciones_rutas add column if not exists ruta_restringida text;

-- 2) Backfill best-effort desde viajes_hora ("... ruta 192" -> "192"). Solo para consistencia/consulta.
update public.restricciones_rutas
   set ruta_restringida = upper((regexp_match(viajes_hora, 'ruta\s*(\d{2,4})', 'i'))[1])
 where ruta_restringida is null
   and viajes_hora ~* 'ruta\s*\d';

-- 3) Normalizador de ruta: extrae el número (2-4 dígitos) para comparar "Ruta 192" == "192".
create or replace function public._norm_ruta(t text)
returns text language sql immutable as $$
  select coalesce((regexp_match(coalesce(t,''), '(\d{2,4})'))[1], upper(trim(coalesce(t,''))));
$$;

-- 4) ¿El móvil está bloqueado para despachar esta ruta a esta hora, este día?
create or replace function public.restriccion_bloqueo(
  p_movil text, p_ruta text, p_fecha date default null, p_hora time default null)
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
     and ( hora_inicial is null or hora_finalizacion is null
           or (v_hora >= hora_inicial and v_hora <= hora_finalizacion) )
   order by id desc limit 1;
  if r.id is null then return jsonb_build_object('bloqueado', false); end if;
  return jsonb_build_object('bloqueado', true, 'id', r.id, 'movil', r.vehiculo,
    'ruta', r.ruta_restringida, 'viaje', r.viajes_hora, 'novedad', r.novedad,
    'fecha', r.fecha_restriccion, 'hora_ini', r.hora_inicial, 'hora_fin', r.hora_finalizacion);
end $$;
revoke all on function public.restriccion_bloqueo(text,text,date,time) from public;
grant execute on function public.restriccion_bloqueo(text,text,date,time) to authenticated;

-- 5) Restricciones VIGENTES de un móvil para un día (aviso informativo al elegir el móvil).
create or replace function public.restricciones_movil_dia(p_movil text, p_fecha date default null)
returns setof public.restricciones_rutas
language sql stable security definer set search_path to 'public'
as $$
  select * from public.restricciones_rutas
   where estado = 'VIGENTE'
     and trim(vehiculo) = trim(p_movil)
     and fecha_restriccion = coalesce(p_fecha, (now() at time zone 'America/Bogota')::date)
   order by hora_inicial nulls last, id;
$$;
revoke all on function public.restricciones_movil_dia(text,date) from public;
grant execute on function public.restricciones_movil_dia(text,date) to authenticated;
