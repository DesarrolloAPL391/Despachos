-- ============================================================================
-- 33_horario_multigrupo.sql
-- Un despachador puede cubrir VARIOS grupos en un día (ej. 193I-193II + Laureles).
--
-- El horario ya tiene el multiselect "Grupos de ruta" (columna `horarios.grupos`,
-- valores = nombres de GRUPO de parque_automotor.ruta), pero el backend solo lo
-- respetaba domingos/festivos. En día hábil lo ignoraba: ni `mi_contexto` (cliente)
-- ni `mis_ruta_ids` (RLS de `ubicaciones`) derivaban rutas de ahí, así que el 2º
-- grupo ni se veía en el mapa ni se podía despachar.
--
-- Fix (opt-in, sin efecto para quien tenga `grupos` vacío): honrar `horarios.grupos`
-- TODOS los días. Las rutas del despachador = rutas del PUESTO (observacion) UNION
-- rutas de los GRUPOS marcados (via ruta_grupos.grupo -> ruta_sonar -> rutas).
--   • mis_ruta_ids  -> la RLS le entrega los GPS de ambos grupos.
--   • mi_contexto    -> CTX.rutas trae ambos grupos (mapa v185 + despacho ya los toman)
--                       y CTX.grupos sigue trayendo los nombres de grupo marcados.
-- ============================================================================

-- 1) RLS: rutas visibles del despachador = puesto + grupos del horario (cualquier día)
create or replace function public.mis_ruta_ids()
returns bigint[]
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_email text := auth.email();
  v_puesto text; v_txt text; v_grupos text[];
  v_ids bigint[]; v_gids bigint[];
begin
  if public.es_admin() then return null; end if;
  select trim(observacion), grupos into v_puesto, v_grupos
    from public.horarios
    where lower(email)=lower(v_email)
      and fecha = (now() at time zone 'America/Bogota')::date
    order by hora_inicio asc nulls last limit 1;

  -- rutas del PUESTO (observacion)
  if v_puesto is not null and v_puesto <> '' then
    select rutas into v_txt from public.puestos where lower(nombre)=lower(v_puesto) and activo;
    if v_txt is not null then
      select array_agg(distinct r.id) into v_ids
        from unnest(string_to_array(v_txt,',')) s(name)
        join public.rutas r on lower(trim(r.nombre))=lower(trim(s.name));
    end if;
  end if;

  -- rutas de los GRUPOS extra marcados en el horario ("Grupos de ruta")
  if v_grupos is not null and array_length(v_grupos,1) > 0 then
    select array_agg(distinct r.id) into v_gids
      from unnest(v_grupos) as g(name)
      join public.ruta_grupos rg on lower(trim(rg.grupo)) = lower(trim(g.name))
      join public.rutas r on lower(trim(r.nombre)) = lower(trim(rg.ruta_sonar));
  end if;

  return coalesce(v_ids, array[]::bigint[]) || coalesce(v_gids, array[]::bigint[]);
end $function$;

-- 2) Contexto del cliente: en día HÁBIL, unir rutas del puesto + rutas de los grupos.
--    (Se recrea la función completa; solo cambia el bloque del día hábil — el resto
--    queda idéntico a la versión previa.)
create or replace function public.mi_contexto()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_email text := auth.email();
  v_rol text; v_nombre text; v_puesto text; v_rutas_txt text;
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
    into v_puesto, v_h_ini, v_h_fin, v_grupos
  from public.horarios where lower(email)=lower(v_email) and fecha=v_hoy order by hora_inicio asc nulls last limit 1;
  if v_puesto is null or v_puesto = '' then
    if v_tipo in ('domingo','festivo') then
      select nullif(trim(puesto_domingo),'') into v_puesto from public.perfiles where lower(email)=lower(v_email);
    else
      select nullif(trim(puesto_fijo),'') into v_puesto from public.perfiles where lower(email)=lower(v_email);
    end if;
  end if;
  if v_puesto is not null then
    select coalesce(jsonb_agg(jsonb_build_object('tabla',tabla,'label',label) order by label),'[]'::jsonb)
      into v_tablas from public.tablas_despacho where lower(puesto)=lower(v_puesto) and activo;
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
      if v_puesto is not null then
        select rutas into v_rutas_txt from public.puestos where lower(nombre)=lower(v_puesto) and activo;
      end if;
      if v_rutas_txt is not null then
        select array_agg(distinct r.nombre), array_agg(distinct r.id) into v_names, v_ids
        from unnest(string_to_array(v_rutas_txt, ',')) as s(name)
        join public.rutas r on lower(trim(r.nombre)) = lower(trim(s.name));
        select array_agg(distinct rg.grupo) into v_grupos
        from unnest(string_to_array(v_rutas_txt, ',')) as s(name)
        join public.ruta_grupos rg on lower(trim(rg.ruta_sonar)) = lower(trim(s.name));
      end if;
    end if;
  else
    -- DÍA HÁBIL: rutas del PUESTO + rutas de los GRUPOS marcados en el horario.
    if v_puesto is not null then
      select rutas into v_rutas_txt from public.puestos where lower(nombre)=lower(v_puesto) and activo;
    end if;
    select array_agg(distinct u.nombre), array_agg(distinct u.id) into v_names, v_ids
    from (
      -- rutas del puesto
      select r.nombre, r.id
      from unnest(string_to_array(coalesce(v_rutas_txt,''), ',')) as s(name)
      join public.rutas r on lower(trim(r.nombre)) = lower(trim(s.name))
      where nullif(trim(s.name),'') is not null
      union
      -- rutas de los grupos extra del horario
      select r.nombre, r.id
      from unnest(coalesce(v_grupos, array[]::text[])) as g(name)
      join public.ruta_grupos rg on lower(trim(rg.grupo)) = lower(trim(g.name))
      join public.rutas r on lower(trim(r.nombre)) = lower(trim(rg.ruta_sonar))
    ) u;
  end if;
  return jsonb_build_object('email',v_email,'rol',v_rol,'nombre',v_nombre,'puesto',v_puesto,'dia_tipo',v_tipo,
    'hora_inicio',v_h_ini,'hora_fin',v_h_fin,
    'grupos',coalesce(to_jsonb(v_grupos),'[]'::jsonb),
    'tablas',coalesce(v_tablas,'[]'::jsonb),
    'rutas',coalesce(to_jsonb(v_names),'[]'::jsonb),'ids',coalesce(to_jsonb(v_ids),'[]'::jsonb),
    'despachador_id',v_desp_id,'auditor_id',v_aud_id);
end $function$;
