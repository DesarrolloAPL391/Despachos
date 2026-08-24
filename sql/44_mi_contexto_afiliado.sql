-- 44: mi_contexto() con rama AFILIADO. Igual que antes (sql/34) pero agrega, después del
-- auditor, una rama para el rol 'afiliado' que devuelve rol+nombre+sus móviles (numero de
-- vehiculo) y nada más (sin puesto/rutas/tablas). Así el afiliado entra sin pasar por la
-- lógica de despachador (que lo dejaría sin contexto y bloqueado por en_horario).

create or replace function public.mi_contexto()
returns jsonb language plpgsql security definer set search_path = public as $function$
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
