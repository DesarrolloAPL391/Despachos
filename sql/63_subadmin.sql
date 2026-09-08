-- 63: Rol interno de SUBADMINISTRADOR para el área de operaciones (acotado).
-- Operaciones = cuentas rol 'despachador' con correo 'operaciones' (es_operaciones()).
-- Suma a su base: crear accesos (no admin), ver análisis (Cumplimiento/Frecuencia/
-- Productividad/Top/Pasajeros) y editar la ficha del parque. SIN acciones destructivas.

-- Subadmin = admin o operaciones (helper de conveniencia)
create or replace function public.es_subadmin()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_admin() or public.es_operaciones(); $$;
revoke all on function public.es_subadmin() from public;
grant execute on function public.es_subadmin() to authenticated;

-- Crear/gestionar accesos: lo puede hacer el subadmin, pero SOLO el admin crea 'admin'.
create or replace function public.admin_crear_usuario(p_email text, p_nombre text, p_pass text, p_rol text default 'despachador'::text)
returns jsonb
language plpgsql security definer set search_path to 'public','auth','extensions'
as $function$
declare v_id uuid; v_rol text := lower(trim(coalesce(p_rol,'despachador')));
begin
  if not public.es_subadmin() then return jsonb_build_object('ok',false,'error','No autorizado'); end if;
  if v_rol not in ('admin','despachador','auditor','afiliado') then
    return jsonb_build_object('ok',false,'error','Rol invalido (admin/despachador/auditor/afiliado)'); end if;
  if v_rol = 'admin' and not public.es_admin() then
    return jsonb_build_object('ok',false,'error','Solo un administrador puede crear administradores'); end if;
  if coalesce(trim(p_email),'')='' or coalesce(p_pass,'')='' then
    return jsonb_build_object('ok',false,'error','Correo y contrasena requeridos'); end if;
  v_id := public._crear_login(lower(trim(p_email)), p_pass, p_nombre);
  insert into public.perfiles(id,email,nombre,rol,activo)
    values (v_id, lower(trim(p_email)), p_nombre, v_rol, true)
    on conflict (id) do update set nombre=coalesce(excluded.nombre,perfiles.nombre), rol=v_rol, activo=true;
  if v_rol = 'auditor' then
    insert into public.auditores(nombre)
      select lower(trim(p_email))
      where not exists (select 1 from public.auditores where lower(trim(nombre))=lower(trim(p_email)));
  end if;
  return jsonb_build_object('ok',true,'id',v_id,'rol',v_rol);
end $function$;

-- Cumplimiento: operaciones lee TODO el resumen (oversight de la flota)
alter policy resumen_select on public.resumen
  using ((select public.es_admin())
         or (select public.es_operaciones())
         or ((select public.es_auditor()) and ruta_id = any((select public.rutas_auditor())::bigint[]))
         or (ruta_id = any((select public.mis_ruta_ids())::bigint[])));

-- Editar la ficha del parque (columnas de la ficha; los DOCUMENTOS siguen por su propio
-- gestor con historial). El trigger de auditoría (sql/61) registra quién cambió qué.
create or replace function public.subadmin_editar_parque(p_id bigint, p_data jsonb)
returns public.parque_automotor
language plpgsql security definer set search_path to 'public'
as $$
declare v public.parque_automotor; k text; v_sets text[] := '{}';
  v_allow text[] := array['placa','centro_costos','sistema_ruta','ruta','marca','combustible',
    'tecnologia_emision','clase_vehiculo','tipo_carroceria','color','cap_sentados','cap_pie',
    'capacidad_to','linea','cilindraje','modelo','propietario','identificacion','direccion',
    'telefono','correo','administrador','correo_admin','fecha_matricula','num_matricula','estado'];
begin
  if not public.es_subadmin() then raise exception 'No autorizado'; end if;
  for k in select jsonb_object_keys(p_data) loop
    if k = any(v_allow) then
      v_sets := array_append(v_sets, format('%I = %L', k, nullif(p_data->>k,'')));
    end if;
  end loop;
  if array_length(v_sets,1) is null then raise exception 'No hay campos para actualizar'; end if;
  execute format('update public.parque_automotor set %s where id = %L',
                 array_to_string(v_sets, ', '), p_id);
  select * into v from public.parque_automotor where id = p_id;
  return v;
end $$;
revoke all on function public.subadmin_editar_parque(bigint,jsonb) from public;
grant execute on function public.subadmin_editar_parque(bigint,jsonb) to authenticated;
