-- 195: la licencia de conduccion vencida YA NO bloquea el despacho (pedido del 17/11/2026:
-- "no restrinjas los conductores por medio de la licencia"). Queda SOLO el aviso, como antes
-- del 11/10: al elegir un conductor con la licencia vencida sale el aviso con el boton
-- "Subir licencia renovada", pero se puede despachar.
--
-- Dos cosas:
--  1. licencia_bloqueo_config.activo = false (el interruptor de sql/110). Con eso
--     licencia_bloqueo_estado devuelve bloqueado = false para todos.
--  2. licencia_bloqueo_estado deja de devolver la fecha cuando el bloqueo esta apagado. Si no,
--     la app mostraria "Desde el 11/10 esto bloqueara el despacho" (la cuenta regresiva de
--     antes del bloqueo), con una fecha que ya paso. Sin fecha, la app no muestra esa linea.
--     El resto de la funcion es igual a sql/110 ([^0-9] en lugar de la clase de digitos).
--
-- Para volver a encenderlo: select public.licencia_bloqueo_config_guardar(p_activo => true);
-- (con p_desde si se quiere una fecha nueva). No hace falta publicar la app.

set lock_timeout = '5s';

update public.licencia_bloqueo_config
   set activo = false,
       nota = '17/11/2026: apagado a pedido del usuario (no restringir a los conductores por la licencia). Queda solo el aviso.'
 where id = 1;

create or replace function public.licencia_bloqueo_estado(p_dr_id text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  cfg     public.licencia_bloqueo_config%rowtype;
  v_ced   text; v_nom text;
  p       public.perfilsociodemografico;
  s       public.licencia_actualizaciones;
  v_dias  int; v_rev boolean := false; v_vig boolean;
  v_desde date;
begin
  if not (public.es_admin() or public.es_despachador() or public.es_auditor()) then
    return jsonb_build_object('bloqueado', false);
  end if;
  select * into cfg from public.licencia_bloqueo_config where id = 1;
  v_vig := coalesce(cfg.activo, false) and cfg.desde is not null and v_hoy >= cfg.desde;
  -- Apagado: sin fecha, para que la app no anuncie un bloqueo que no va a llegar (sql/195).
  v_desde := case when coalesce(cfg.activo, false) then cfg.desde end;

  select regexp_replace(coalesce(cedula, ''), '[^0-9]', '', 'g'), nombre into v_ced, v_nom
    from public.conductores_sonar where dr_id::text = p_dr_id limit 1;
  if coalesce(v_ced, '') = '' then
    return jsonb_build_object('bloqueado', false, 'desde', v_desde, 'vigente', v_vig);
  end if;

  select * into p from public.perfilsociodemografico where cedula = v_ced;
  -- Sin perfil o sin fecha registrada no se bloquea: el dato falta en la empresa, no en
  -- el conductor. Eso se arregla en Gestion Humana, no trancando el despacho.
  if p.id is null or p.licencia_vencimiento is null then
    return jsonb_build_object('bloqueado', false, 'desde', v_desde, 'vigente', v_vig,
                              'nombre', coalesce(v_nom, p.nombre), 'sin_dato', true);
  end if;

  v_dias := p.licencia_vencimiento - v_hoy;

  -- ¿Ya subieron las fotos de este mismo ciclo y estan esperando revision?
  select * into s from public.licencia_actualizaciones
   where cedula = v_ced and vence_anterior is not distinct from p.licencia_vencimiento
   order by subido_en desc limit 1;
  v_rev := (s.id is not null and s.estado = 'PENDIENTE');

  return jsonb_build_object(
    'bloqueado', (v_vig and v_dias < 0 and not v_rev),
    'vigente', v_vig,                 -- si el bloqueo ya esta encendido
    'desde', v_desde,                 -- desde cuando bloquea (null = apagado)
    'faltan', greatest(v_desde - v_hoy, 0),
    'nombre', coalesce(v_nom, p.nombre),
    'vence', p.licencia_vencimiento,
    'dias', v_dias,
    'categoria', p.categoria_licencia,
    'en_revision', v_rev,
    'subido_en', s.subido_en,
    'motivo_rechazo', case when s.estado = 'RECHAZADO' then s.motivo_rechazo else null end);
end $fn$;
revoke all on function public.licencia_bloqueo_estado(text) from public, anon;
grant execute on function public.licencia_bloqueo_estado(text) to authenticated;
