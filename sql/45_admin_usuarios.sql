-- 45: Administración de usuarios — eliminar y listar (solo admin).
-- Eliminar: borra auth.users (cascada a perfiles, sesion_activa, dispositivos, identities…)
-- y limpia a mano afiliado_vehiculos + auditores (van por correo, sin FK). Protege:
-- no borrarse a sí mismo, ni al único administrador.

create or replace function public.admin_eliminar_usuario(p_email text)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_id uuid; v_email text := lower(trim(coalesce(p_email,'')));
begin
  if not public.es_admin() then return jsonb_build_object('ok',false,'error','No autorizado'); end if;
  if v_email = '' then return jsonb_build_object('ok',false,'error','Correo requerido'); end if;
  if v_email = lower(trim(coalesce(auth.email(),''))) then
    return jsonb_build_object('ok',false,'error','No puedes eliminar tu propio usuario'); end if;
  select id into v_id from auth.users where lower(email)=v_email;
  if v_id is null then return jsonb_build_object('ok',false,'error','No existe ese usuario'); end if;
  -- No dejar el sistema sin administrador
  if exists (select 1 from public.perfiles where id=v_id and rol='admin')
     and (select count(*) from public.perfiles where rol='admin' and activo) <= 1 then
    return jsonb_build_object('ok',false,'error','Es el único administrador: no se puede eliminar');
  end if;
  delete from public.afiliado_vehiculos where lower(trim(afiliado_email)) = v_email;
  delete from public.auditores where lower(trim(email)) = v_email or lower(trim(nombre)) = v_email;
  delete from auth.users where id = v_id;  -- cascada al resto
  return jsonb_build_object('ok',true,'email',v_email);
exception when others then
  return jsonb_build_object('ok',false,'error',SQLERRM);
end $$;
grant execute on function public.admin_eliminar_usuario(text) to authenticated;

-- Lista de TODOS los usuarios (perfiles) con su rol y, si es afiliado, su conteo de vehículos.
create or replace function public.usuarios_listar()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'email', p.email, 'nombre', p.nombre, 'rol', p.rol, 'activo', p.activo,
      'vehiculos', case when p.rol='afiliado'
                        then (select count(*) from public.afiliado_vehiculos av where lower(trim(av.afiliado_email))=lower(trim(p.email)))
                        else null end
    ) order by (case p.rol when 'admin' then 0 when 'auditor' then 1 when 'afiliado' then 2 else 3 end), p.nombre), '[]'::jsonb)
  from public.perfiles p
  where public.es_admin();
$$;
grant execute on function public.usuarios_listar() to authenticated;
