-- ===================================================================================
-- 115: cambiar la fecha del bloqueo de licencias desde el SQL Editor.
-- ===================================================================================
-- licencia_bloqueo_config_guardar (sql/110) exigía es_admin(), que lee el rol del JWT.
-- Desde el SQL Editor no hay sesión de la app, así que contestaba "Solo administración
-- cambia el bloqueo de licencias" justo cuando administración era quien estaba pidiendo.
--
-- Permitir la consola no abre nada: quien está ahí es el dueño de la base y puede hacer
-- el UPDATE a mano igual. Lo que se gana es que quede registrado quién y cuándo, que es
-- para lo que existe la función.
-- ===================================================================================

create or replace function public.licencia_bloqueo_config_guardar(
  p_desde date default null, p_activo boolean default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not ( (select public.es_admin()) or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración cambia el bloqueo de licencias.');
  end if;
  update public.licencia_bloqueo_config
     set desde = coalesce(p_desde, desde),
         activo = coalesce(p_activo, activo),
         nota = coalesce(nullif(trim(coalesce(p_nota, '')), ''), nota),
         actualizado_en = now(),
         actualizado_por = coalesce(auth.jwt() ->> 'email', 'consola')
   where id = 1;
  return jsonb_build_object('ok', true) || (select to_jsonb(c) from public.licencia_bloqueo_config c where c.id = 1);
end $fn$;
revoke all on function public.licencia_bloqueo_config_guardar(date, boolean, text) from public, anon;
grant execute on function public.licencia_bloqueo_config_guardar(date, boolean, text) to authenticated;

-- Lo mismo para el del taller, por la misma razón.
create or replace function public.taller_config_guardar(
  p_activo boolean default null, p_reporta_por_id int default null,
  p_prog_atras int default null, p_prog_adelante int default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not ( (select public.es_admin()) or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración.');
  end if;
  update public.taller_config
     set activo = coalesce(p_activo, activo),
         reporta_por_id = coalesce(p_reporta_por_id, reporta_por_id),
         prog_atras = coalesce(p_prog_atras, prog_atras),
         prog_adelante = coalesce(p_prog_adelante, prog_adelante),
         nota = coalesce(nullif(btrim(coalesce(p_nota, '')), ''), nota),
         actualizado_en = now(), actualizado_por = coalesce(auth.jwt() ->> 'email', 'consola')
   where id = 1;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.taller_config_guardar(boolean, int, int, int, text) from public, anon;
grant execute on function public.taller_config_guardar(boolean, int, int, int, text) to authenticated;
