-- ============================================================================
-- 34_puesto_multiple.sql
-- El campo "Puesto" del horario ahora admite VARIOS puestos (coma-separados en
-- horarios.observacion, p.ej. "193I, Laureles"). El despachador ve y despacha las
-- rutas/grupos de TODOS sus puestos, y accede a las TABLAS por puesto de todos.
--
-- Piezas:
--  1) mis_puestos()  -> text[] con los puestos de hoy (split de observacion, minúsculas).
--  2) mi_puesto()    -> primer puesto (compat/etiqueta).
--  3) mis_ruta_ids() -> rutas de TODOS los puestos + grupos marcados (RLS ubicaciones).
--  4) setup_tabla_puesto() -> las políticas nuevas usan "lower(puesto)=any(mis_puestos())".
--  5) DO block -> regenera las políticas pp_sel/pp_upd existentes a "pertenece a".
--  6) mi_contexto() y preview_contexto_despachador() -> multi-puesto (rutas+tablas union).
--
-- Seguro: sin coma en observacion equivale a un solo puesto (comportamiento previo).
-- Ningún nombre de puesto contiene coma (verificado).
-- ============================================================================

-- 1) Puestos de hoy del despachador (minúsculas, sin vacíos)
create or replace function public.mis_puestos()
returns text[]
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
           array_agg(distinct lower(trim(x))) filter (where nullif(trim(x),'') is not null),
           array[]::text[])
  from public.horarios h,
       lateral unnest(string_to_array(coalesce(h.observacion,''), ',')) as x
  where lower(h.email)=lower(auth.email())
    and h.fecha=(now() at time zone 'America/Bogota')::date;
$function$;

-- 2) Primer puesto (compat: etiqueta / usos que esperan uno solo)
create or replace function public.mi_puesto()
returns text
language sql stable security definer set search_path to 'public'
as $function$
  select nullif(trim(split_part(observacion, ',', 1)), '')
  from public.horarios
  where lower(email)=lower(auth.email())
    and fecha=(now() at time zone 'America/Bogota')::date
  order by hora_inicio asc nulls last limit 1;
$function$;

-- 3) RLS de ubicaciones: rutas de TODOS los puestos + grupos marcados
create or replace function public.mis_ruta_ids()
returns bigint[]
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_email text := auth.email(); v_obs text; v_grupos text[]; v_ids bigint[];
begin
  if public.es_admin() then return null; end if;
  select trim(observacion), grupos into v_obs, v_grupos
    from public.horarios
    where lower(email)=lower(v_email)
      and fecha=(now() at time zone 'America/Bogota')::date
    order by hora_inicio asc nulls last limit 1;
  select array_agg(distinct u.id) into v_ids from (
    select r.id
    from unnest(string_to_array(coalesce(v_obs,''), ',')) as pn(pname)
    join public.puestos p on lower(trim(p.nombre))=lower(trim(pn.pname)) and p.activo
    cross join lateral unnest(string_to_array(coalesce(p.rutas,''), ',')) as s(rname)
    join public.rutas r on lower(trim(r.nombre))=lower(trim(s.rname))
    where nullif(trim(pn.pname),'') is not null
    union
    select r.id
    from unnest(coalesce(v_grupos, array[]::text[])) as g(gname)
    join public.ruta_grupos rg on lower(trim(rg.grupo))=lower(trim(g.gname))
    join public.rutas r on lower(trim(r.nombre))=lower(trim(rg.ruta_sonar))
  ) u;
  return coalesce(v_ids, array[]::bigint[]);
end $function$;

-- 4) Plantilla de tablas por puesto: políticas por "pertenece a mis_puestos()"
create or replace function public.setup_tabla_puesto(p_tabla text, p_puesto text)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare fk record;
begin
  execute format('create table if not exists public.%I (like public.despachos including all)', p_tabla);
  for fk in select * from (values
      ('ruta_fk','ruta_id','rutas'),('rutap_fk','ruta_programada_id','rutas'),
      ('veh_fk','vehiculo_id','vehiculos'),('vehp_fk','vehiculo_programado_id','vehiculos'),
      ('cond_fk','conductor_id','conductores'),('desp_fk','despachador_id','despachadores')
    ) as t(suf,col,ref)
  loop
    begin
      execute format('alter table public.%I add constraint %I foreign key (%I) references public.%I(id)',
        p_tabla, p_tabla||'_'||fk.suf, fk.col, fk.ref);
    exception when duplicate_object then null; when duplicate_table then null; end;
  end loop;
  execute format('alter table public.%I enable row level security', p_tabla);
  execute format('drop policy if exists pp_sel on public.%I', p_tabla);
  execute format('create policy pp_sel on public.%I for select to authenticated using (public.es_admin() or lower(%L)=any(public.mis_puestos()))', p_tabla, p_puesto);
  execute format('drop policy if exists pp_upd on public.%I', p_tabla);
  execute format('create policy pp_upd on public.%I for update to authenticated using (public.es_admin() or lower(%L)=any(public.mis_puestos())) with check (true)', p_tabla, p_puesto);
  execute format('drop policy if exists pp_ins on public.%I', p_tabla);
  execute format('create policy pp_ins on public.%I for insert to authenticated with check (public.es_admin())', p_tabla);
  execute format('drop policy if exists pp_del on public.%I', p_tabla);
  execute format('create policy pp_del on public.%I for delete to authenticated using (public.es_admin())', p_tabla);
  execute format('grant all on public.%I to authenticated', p_tabla);
end $function$;

-- 5) Regenerar las políticas pp_sel/pp_upd existentes (las que aún usan mi_puesto())
do $do$
declare r record; v_puesto text;
begin
  for r in
    select c.relname as tabla, pol.polname as policy, pol.polcmd as cmd,
           pg_get_expr(pol.polqual, pol.polrelid) as qual
    from pg_policy pol join pg_class c on c.oid=pol.polrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and pg_get_expr(pol.polqual, pol.polrelid) ilike '%mi_puesto()%'
  loop
    v_puesto := (regexp_match(r.qual, $re$'([^']+)'::text$re$))[1];
    if v_puesto is null then continue; end if;
    execute format('drop policy if exists %I on public.%I', r.policy, r.tabla);
    if r.cmd = 'r' then      -- SELECT
      execute format('create policy %I on public.%I for select to authenticated using (public.es_admin() or lower(%L)=any(public.mis_puestos()))', r.policy, r.tabla, v_puesto);
    elsif r.cmd = 'w' then   -- UPDATE
      execute format('create policy %I on public.%I for update to authenticated using (public.es_admin() or lower(%L)=any(public.mis_puestos())) with check (true)', r.policy, r.tabla, v_puesto);
    end if;
  end loop;
end $do$;

-- 6) Contexto del cliente: multi-puesto (rutas + tablas de TODOS los puestos)
create or replace function public.mi_contexto()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
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
  -- Tablas por puesto de TODOS los puestos del observacion
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
    -- HÁBIL: rutas de TODOS los puestos + grupos marcados
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

-- 7) Vista previa del admin (mismo criterio multi-puesto)
create or replace function public.preview_contexto_despachador(p_email text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_email text := lower(trim(p_email));
  v_rol text; v_nombre text; v_obs text; v_rutas_txt text;
  v_names text[]; v_ids bigint[]; v_tablas jsonb; v_desp_id bigint;
  v_hoy date := (now() at time zone 'America/Bogota')::date; v_tipo text;
  v_h_ini text; v_h_fin text; v_grupos text[];
begin
  if not exists (select 1 from public.perfiles where lower(email)=lower(auth.email()) and rol='admin' and activo) then
    raise exception 'Solo un administrador puede usar la vista previa';
  end if;
  select rol, nombre into v_rol, v_nombre from public.perfiles where lower(email)=v_email and activo;
  if v_rol is null then
    return jsonb_build_object('email',v_email,'rol','sin_acceso','rutas','[]'::jsonb,'ids','[]'::jsonb,'tablas','[]'::jsonb);
  end if;
  select id into v_desp_id from public.despachadores where lower(trim(nombre))=lower(trim(v_nombre)) limit 1;
  v_tipo := public.tipo_dia(v_hoy);
  select trim(observacion), to_char(hora_inicio,'HH24:MI'), to_char(hora_fin,'HH24:MI'), grupos
    into v_obs, v_h_ini, v_h_fin, v_grupos
  from public.horarios where lower(email)=v_email and fecha=v_hoy order by hora_inicio asc nulls last limit 1;
  if v_obs is null or v_obs = '' then
    if v_tipo in ('domingo','festivo') then
      select nullif(trim(puesto_domingo),'') into v_obs from public.perfiles where lower(email)=v_email;
    else
      select nullif(trim(puesto_fijo),'') into v_obs from public.perfiles where lower(email)=v_email;
    end if;
  end if;
  if v_obs is not null and v_obs <> '' then
    select coalesce(jsonb_agg(jsonb_build_object('tabla',tabla,'label',label) order by label),'[]'::jsonb)
      into v_tablas
    from (
      select distinct td.tabla, td.label from public.tablas_despacho td
      where td.activo and lower(td.puesto) = any(
        select lower(trim(x)) from unnest(string_to_array(v_obs, ',')) x where nullif(trim(x),'') is not null)
    ) q;
  end if;
  if v_tipo in ('domingo','festivo') then
    if v_grupos is not null and array_length(v_grupos,1) > 0 then
      select array_agg(distinct rg.ruta_sonar) into v_names from public.ruta_grupos rg where rg.grupo = any(v_grupos);
      select array_agg(distinct r.id) into v_ids
        from public.ruta_grupos rg join public.rutas r on lower(trim(r.nombre)) = lower(trim(rg.ruta_sonar))
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
    'despachador_id',v_desp_id);
end $function$;
