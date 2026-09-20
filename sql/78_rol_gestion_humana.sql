-- 78: ROL GESTIÓN HUMANA (talento humano).
--
-- Decisión del usuario (20/09/2026): además del administrador, un rol NUEVO y aparte para el
-- área de Gestión Humana. Ve SOLO el módulo 👥 Talento humano:
--   * Perfil sociodemográfico e historial de vinculaciones (ficha completa, INCLUIDO el salario)
--   * Estadísticas sociodemográficas, actualizaciones de datos y su link
--   * Aspirantes a conductor: todo el proceso, y SÍ puede contratar
-- NO ve despachos, mapa, rutas, parque, documentos de vehículos ni configuración, y NO entra a
-- ninguna otra tabla (la RLS del resto de módulos no lo reconoce, así que no le devuelve filas).
--
-- Los permisos de las tablas y RPC del módulo salen de `es_talento_humano()` (admin o gestión
-- humana), que se define en sql/75 para que ese archivo se pueda aplicar solo. Este archivo
-- agrega el rol al sistema de acceso: cuenta, horario, contexto y creación de usuarios.
-- Orden de aplicación: 75 → 77 → 78.

-- ---- 1) El rol existe ----
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check
  check (rol in ('admin', 'despachador', 'auditor', 'afiliado', 'gestion_humana'));

-- ---- 2) Helpers de rol (misma definición que en sql/75; aquí por si se aplica suelto) ----
create or replace function public.es_gestion_humana()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select exists(select 1 from public.perfiles where id = auth.uid() and rol = 'gestion_humana' and activo); $$;
revoke all on function public.es_gestion_humana() from public, anon;
grant execute on function public.es_gestion_humana() to authenticated;

create or replace function public.es_talento_humano()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_admin() or public.es_gestion_humana(); $$;
revoke all on function public.es_talento_humano() from public, anon;
grant execute on function public.es_talento_humano() to authenticated;

-- ---- 3) Entra sin turno (no es despachador: no tiene horario de puesto) ----
create or replace function public.en_horario()
returns boolean language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_rol text; v_now time := (now() at time zone 'America/Bogota')::time;
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_email text := auth.jwt() ->> 'email'; r record;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin','auditor','afiliado','gestion_humana') then return true; end if;
  -- operaciones (gestión): entra sin turno del día
  if v_rol = 'despachador' and lower(coalesce(v_email,'')) like '%operaciones%' then return true; end if;
  for r in select hora_inicio, hora_fin from public.horarios
           where lower(email)=lower(v_email) and fecha=v_today loop
    if r.hora_inicio is null or r.hora_fin is null then continue; end if;
    if r.hora_fin >= r.hora_inicio then
      if v_now between r.hora_inicio and r.hora_fin then return true; end if;
    else
      if v_now >= r.hora_inicio or v_now <= r.hora_fin then return true; end if;
    end if;
  end loop;
  return false;
end; $function$;

create or replace function public.mi_acceso_horario()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_rol text; v_email text := auth.jwt() ->> 'email';
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_hi text; v_hf text; v_c int;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin','auditor','gestion_humana')
     or (v_rol = 'despachador' and lower(coalesce(v_email,'')) like '%operaciones%') then
    return jsonb_build_object('permitido', true, 'rol', v_rol);
  end if;
  select to_char(min(hora_inicio),'HH24:MI'), to_char(max(hora_fin),'HH24:MI'), count(*)
    into v_hi, v_hf, v_c
  from public.horarios where lower(email)=lower(v_email) and fecha=v_today;
  return jsonb_build_object('permitido', public.en_horario(),
    'tiene_turno', coalesce(v_c,0) > 0, 'hora_inicio', v_hi, 'hora_fin', v_hf);
end; $function$;

-- ---- 4) Contexto de entrada (rama propia: sin rutas, sin tablas de despacho) ----
CREATE OR REPLACE FUNCTION public.mi_contexto()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text := auth.email();
  v_rol text; v_nombre text; v_obs text; v_rutas_txt text;
  v_names text[]; v_ids bigint[]; v_tablas jsonb; v_desp_id bigint; v_aud_id bigint;
  v_hoy date := (now() at time zone 'America/Bogota')::date; v_tipo text;
  v_h_ini text; v_h_fin text; v_grupos text[];
begin
  select rol, nombre into v_rol, v_nombre from public.perfiles where lower(email)=lower(v_email) and activo;
  if v_rol is null then
    return jsonb_build_object('email',v_email,'rol','sin_acceso','rutas','[]'::jsonb,'ids','[]'::jsonb,'tablas','[]'::jsonb);
  end if;
  select id into v_desp_id from public.despachadores where lower(trim(nombre))=lower(trim(v_nombre)) limit 1;
  select id into v_aud_id from public.auditores where lower(trim(email))=lower(trim(v_email)) limit 1;
  if v_rol = 'admin' then
    return jsonb_build_object('email',v_email,'rol','admin','nombre',v_nombre,'rutas',null,'ids',null,'tablas',null,
      'despachador_id',v_desp_id,'auditor_id',v_aud_id);
  end if;
  -- GESTIÓN HUMANA: solo Talento humano (perfil sociodemográfico + aspirantes).
  -- Sin rutas, sin tablas de despacho y sin control de horario.
  if v_rol = 'gestion_humana' then
    return jsonb_build_object('email',v_email,'rol','gestion_humana','nombre',v_nombre,
      'rutas','[]'::jsonb,'ids','[]'::jsonb,'tablas','[]'::jsonb,'grupos','[]'::jsonb);
  end if;
  if v_rol = 'auditor' then
    select rutas into v_rutas_txt from public.auditores where lower(trim(email))=lower(trim(v_email)) limit 1;
    if v_rutas_txt is not null then
      select array_agg(distinct r.nombre), array_agg(distinct r.id) into v_names, v_ids
      from unnest(string_to_array(v_rutas_txt, ',')) as s(name)
      join public.rutas r on lower(trim(r.nombre)) = lower(trim(s.name));
      select array_agg(distinct rg.grupo) into v_grupos
      from unnest(string_to_array(v_rutas_txt, ',')) as s(name)
      join public.ruta_grupos rg on lower(trim(rg.ruta_sonar)) = lower(trim(s.name));
    end if;
    return jsonb_build_object('email',v_email,'rol','auditor','nombre',v_nombre,'tablas','[]'::jsonb,
      'grupos',coalesce(to_jsonb(v_grupos),'[]'::jsonb),
      'rutas',coalesce(to_jsonb(v_names),'[]'::jsonb),'ids',coalesce(to_jsonb(v_ids),'[]'::jsonb),
      'despachador_id',v_desp_id,'auditor_id',v_aud_id);
  end if;
  -- AFILIADO: rol de solo lectura. Ve el mapa + pasajeros y las TABLAS de despacho donde
  -- están SUS carros (por vehiculo real o programado, en los últimos 90 días). La RLS
  -- (pp_sel_afil, sql/46) limita las filas a sus vehículos; aquí solo decidimos qué pestañas
  -- mostrarle. 'ver_despachos' = si alguno de sus carros aparece en la vista general Despachos.
  if v_rol = 'afiliado' then
    select coalesce(array_agg(distinct av.vehiculo_id), array[]::bigint[]) into v_ids
      from public.afiliado_vehiculos av where lower(trim(av.afiliado_email)) = lower(trim(v_email));
    declare
      rec record; hit int; v_ver_desp boolean := false;
    begin
      v_tablas := '[]'::jsonb;
      if array_length(v_ids, 1) is not null then
        for rec in select tabla, label from public.tablas_despacho where activo order by label loop
          execute format('select 1 from public.%I where (vehiculo_id = any($1) or vehiculo_programado_id = any($1)) and fecha >= (current_date - 90) limit 1', rec.tabla)
            using v_ids into hit;
          if hit is not null then v_tablas := v_tablas || jsonb_build_object('tabla', rec.tabla, 'label', rec.label); end if;
        end loop;
        execute 'select 1 from public.despachos where (vehiculo_id = any($1) or vehiculo_programado_id = any($1)) and fecha >= (current_date - 90) limit 1'
          using v_ids into hit;
        v_ver_desp := hit is not null;
      end if;
      return jsonb_build_object('email',v_email,'rol','afiliado','nombre',v_nombre,
        'tablas', coalesce(v_tablas,'[]'::jsonb), 'ver_despachos', v_ver_desp,
        'rutas','[]'::jsonb,'ids','[]'::jsonb,'grupos','[]'::jsonb,
        'moviles', coalesce((select to_jsonb(array_agg(distinct trim(v.numero)))
                             from public.afiliado_vehiculos av
                             join public.vehiculos v on v.id = av.vehiculo_id
                             where lower(trim(av.afiliado_email)) = lower(trim(v_email))), '[]'::jsonb),
        'despachador_id',null,'auditor_id',null);
    end;
  end if;
  v_tipo := public.tipo_dia(v_hoy);
  select trim(observacion), to_char(hora_inicio,'HH24:MI'), to_char(hora_fin,'HH24:MI'), grupos
    into v_obs, v_h_ini, v_h_fin, v_grupos
  from public.horarios where lower(email)=lower(v_email) and fecha=v_hoy order by hora_inicio asc nulls last limit 1;
  if v_obs is null or v_obs = '' then
    if v_tipo in ('domingo','festivo') then
      select nullif(trim(puesto_domingo),'') into v_obs from public.perfiles where lower(email)=lower(v_email);
    else
      select nullif(trim(puesto_fijo),'') into v_obs from public.perfiles where lower(email)=lower(v_email);
    end if;
  end if;
  if v_obs is not null and v_obs <> '' then
    select coalesce(jsonb_agg(jsonb_build_object('tabla',tabla,'label',label) order by label),'[]'::jsonb)
      into v_tablas
    from (
      select distinct td.tabla, td.label
      from public.tablas_despacho td
      where td.activo
        and lower(td.puesto) = any(
          select lower(trim(x)) from unnest(string_to_array(v_obs, ',')) x where nullif(trim(x),'') is not null)
    ) q;
  end if;
  if v_tipo in ('domingo','festivo') then
    if v_grupos is not null and array_length(v_grupos,1) > 0 then
      select array_agg(distinct rg.ruta_sonar) into v_names
        from public.ruta_grupos rg where rg.grupo = any(v_grupos);
      select array_agg(distinct r.id) into v_ids
        from public.ruta_grupos rg
        join public.rutas r on lower(trim(r.nombre)) = lower(trim(rg.ruta_sonar))
        where rg.grupo = any(v_grupos);
    else
      select array_agg(distinct u.nombre), array_agg(distinct u.id) into v_names, v_ids from (
        select r.nombre, r.id
        from unnest(string_to_array(coalesce(v_obs,''), ',')) as pn(pname)
        join public.puestos p on lower(trim(p.nombre))=lower(trim(pn.pname)) and p.activo
        cross join lateral unnest(string_to_array(coalesce(p.rutas,''), ',')) as s(rname)
        join public.rutas r on lower(trim(r.nombre))=lower(trim(s.rname))
        where nullif(trim(pn.pname),'') is not null
      ) u;
      select array_agg(distinct rg.grupo) into v_grupos
        from unnest(string_to_array(coalesce(v_obs,''), ',')) as pn(pname)
        join public.puestos p on lower(trim(p.nombre))=lower(trim(pn.pname)) and p.activo
        cross join lateral unnest(string_to_array(coalesce(p.rutas,''), ',')) as s(rname)
        join public.ruta_grupos rg on lower(trim(rg.ruta_sonar))=lower(trim(s.rname));
    end if;
  else
    select array_agg(distinct u.nombre), array_agg(distinct u.id) into v_names, v_ids from (
      select r.nombre, r.id
      from unnest(string_to_array(coalesce(v_obs,''), ',')) as pn(pname)
      join public.puestos p on lower(trim(p.nombre))=lower(trim(pn.pname)) and p.activo
      cross join lateral unnest(string_to_array(coalesce(p.rutas,''), ',')) as s(rname)
      join public.rutas r on lower(trim(r.nombre))=lower(trim(s.rname))
      where nullif(trim(pn.pname),'') is not null
      union
      select r.nombre, r.id
      from unnest(coalesce(v_grupos, array[]::text[])) as g(gname)
      join public.ruta_grupos rg on lower(trim(rg.grupo))=lower(trim(g.gname))
      join public.rutas r on lower(trim(r.nombre))=lower(trim(rg.ruta_sonar))
    ) u;
  end if;
  return jsonb_build_object('email',v_email,'rol',v_rol,'nombre',v_nombre,'puesto',v_obs,'dia_tipo',v_tipo,
    'hora_inicio',v_h_ini,'hora_fin',v_h_fin,
    'grupos',coalesce(to_jsonb(v_grupos),'[]'::jsonb),
    'tablas',coalesce(v_tablas,'[]'::jsonb),
    'rutas',coalesce(to_jsonb(v_names),'[]'::jsonb),'ids',coalesce(to_jsonb(v_ids),'[]'::jsonb),
    'despachador_id',v_desp_id,'auditor_id',v_aud_id);
end $function$;

-- ---- 5) Crear accesos: solo el ADMIN crea cuentas de Gestión Humana ----
create or replace function public.admin_crear_usuario(p_email text, p_nombre text, p_pass text, p_rol text default 'despachador'::text)
returns jsonb
language plpgsql security definer set search_path to 'public','auth','extensions'
as $function$
declare v_id uuid; v_rol text := lower(trim(coalesce(p_rol,'despachador')));
begin
  if not public.es_subadmin() then return jsonb_build_object('ok',false,'error','No autorizado'); end if;
  if v_rol not in ('admin','despachador','auditor','afiliado','gestion_humana') then
    return jsonb_build_object('ok',false,'error','Rol invalido (admin/despachador/auditor/afiliado/gestion_humana)'); end if;
  if v_rol in ('admin','gestion_humana') and not public.es_admin() then
    return jsonb_build_object('ok',false,'error','Solo un administrador puede crear ese tipo de acceso'); end if;
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
