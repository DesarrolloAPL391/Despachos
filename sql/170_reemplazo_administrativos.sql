-- ===================================================================================
-- 170: PERMISOS Y VACACIONES · "¿QUIÉN TE REEMPLAZA?" SOLO PARA ADMINISTRATIVOS, DE UNA LISTA
-- ===================================================================================
-- Pedido del 05/11/2026: "para los permisos el empleado que reemplaza debe de aparecerle solo a
-- los administrativos; a los conductores no les debe de mostrar ninguno porque ellos no saben,
-- igual los despachadores o gestores. En la lista deben aparecer los empleados administrativos
-- activos para que se puedan elegir. Lo mismo para las vacaciones".
--
-- REGLA (_reemplazo_aplica):
--   * Se pregunta solo a los ADMINISTRATIVOS del Perfil que no son despachadores (cargo con
--     "despach": DESPACHADOR Y/O CONTROL, AUXILIAR DE CONTROL Y DESPACHO VIRTUAL) ni gestores
--     (GESTOR DE SERVICIOS). Al 05/11/2026: 35 de los 72 administrativos activos.
--   * A conductores, proveedores, despachadores y gestores no se les pregunta: lo que llegue se
--     guarda vacío (también si lo manda una página vieja que todavía tenga el campo de texto).
--   * La lista son los administrativos ACTIVOS (sin la persona que pide), con nombre, cargo y
--     área; primero los de su misma área. Nunca la cédula.
--   * Lo que se guarde tiene que ser uno de esa lista: se guarda el nombre tal como está en el
--     Perfil. Si no lo es, no se radica y se le pide elegirlo de la lista.
-- Lo hace cumplir un trigger en permisos y vacaciones, así cubre el link de permisos, el de
-- vacaciones y el registro de Gestión Humana en la app sin tocar permiso_radicar ni _vac_crear.
-- La lista llega en la identificación del link (permiso_mis, vacaciones_identificar) y en la
-- búsqueda de Gestión Humana (vacaciones_persona), con la clave 'reemplazo' (null = no aplica).
-- Al 05/11/2026 hay 1 permiso con reemplazo escrito y 0 vacaciones: no se migra nada.
-- ===================================================================================

-- 1) La regla y la lista (internas) ----------------------------------------------------------------
create or replace function public._reemplazo_aplica(p_tipo text, p_cargo text)
returns boolean
language sql immutable
as $$ select coalesce(p_tipo, '') = 'ADMINISTRATIVO' and coalesce(p_cargo, '') !~* 'despach|gestor' $$;
revoke all on function public._reemplazo_aplica(text, text) from public, anon, authenticated;

create or replace function public._reemplazo_opciones(p_cedula text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object('n', btrim(p.nombre), 'c', p.cargo, 'a', p.area)
           order by (p.area is not distinct from yo.area) desc, p.area nulls last, btrim(p.nombre)), '[]'::jsonb)
    from public.perfilsociodemografico p
    left join lateral (select area from public.perfilsociodemografico where cedula = p_cedula limit 1) yo on true
   where p.estado = 'ACTIVO' and p.tipo = 'ADMINISTRATIVO' and p.cedula is distinct from p_cedula
     and nullif(btrim(p.nombre), '') is not null;
$$;
revoke all on function public._reemplazo_opciones(text) from public, anon, authenticated;

-- El nombre tal como está en el Perfil si es un administrativo activo distinto de quien pide; si no, null.
create or replace function public._reemplazo_nombre(p_cedula text, p_txt text)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select btrim(p.nombre) from public.perfilsociodemografico p
   where p.estado = 'ACTIVO' and p.tipo = 'ADMINISTRATIVO' and p.cedula is distinct from p_cedula
     and upper(regexp_replace(btrim(p.nombre), '\s+', ' ', 'g')) = upper(regexp_replace(btrim(p_txt), '\s+', ' ', 'g'))
   limit 1;
$$;
revoke all on function public._reemplazo_nombre(text, text) from public, anon, authenticated;

-- 2) El trigger: vacío si no aplica, y si aplica, uno de la lista ---------------------------------
create or replace function public._reemplazo_trg()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare v_tipo text; v_cargo text; v_txt text := nullif(btrim(coalesce(new.reemplaza, '')), '');
begin
  select tipo, cargo into v_tipo, v_cargo from public.perfilsociodemografico where cedula = new.cedula limit 1;
  if v_txt is null or not public._reemplazo_aplica(v_tipo, coalesce(v_cargo, new.cargo)) then
    new.reemplaza := null;
    return new;
  end if;
  new.reemplaza := public._reemplazo_nombre(new.cedula, v_txt);
  if new.reemplaza is null then
    raise exception 'Quién te reemplaza debe ser un administrativo activo de la lista. Recarga la página y elígelo, o déjalo en "Todavía no se sabe".';
  end if;
  return new;
end $$;
revoke all on function public._reemplazo_trg() from public, anon, authenticated;

drop trigger if exists permisos_reemplazo on public.permisos;
create trigger permisos_reemplazo before insert on public.permisos
  for each row execute function public._reemplazo_trg();
drop trigger if exists vacaciones_reemplazo on public.vacaciones;
create trigger vacaciones_reemplazo before insert on public.vacaciones
  for each row execute function public._reemplazo_trg();

-- 3) La lista llega al identificarse en el link de permisos (igual a sql/165 + 'reemplazo') ------
create or replace function public.permiso_mis(p_cedula text, p_fecha_nacimiento date)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento); v_p record;
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  select nombre, cargo, tipo, estado into v_p from public.perfilsociodemografico where cedula = v_id->>'cedula' limit 1;
  if v_p.estado is distinct from 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error', 'Tu registro aparece inactivo. Comunícate con Gestión Humana.');
  end if;
  return jsonb_build_object('ok', true,
    'nombre', initcap(lower(coalesce(nullif(array_to_string(
                (regexp_split_to_array(trim(v_p.nombre), '\s+'))[3:], ' '), ''), v_p.nombre))),
    'cargo', v_p.cargo, 'sabado_habil', public._vac_sabado(v_p.tipo, v_p.cargo),
    'reemplazo', case when public._reemplazo_aplica(v_p.tipo, v_p.cargo)
                      then public._reemplazo_opciones(v_id->>'cedula') end,
    'permisos', (select coalesce(jsonb_agg(jsonb_build_object(
        'radicado', x.radicado, 'fecha_solicitud', x.fecha_solicitud, 'tipo', x.tipo, 'caso', x.caso,
        'parentesco', x.parentesco, 'desde', x.desde, 'hasta', x.hasta, 'estado', x.estado,
        'nota', case when x.estado = 'NEGADO' then coalesce(x.gh_nota, x.ger_nota) end,
        'entregados', (select coalesce(jsonb_agg(distinct s.requisito), '[]'::jsonb)
                         from public.permiso_soportes s where s.permiso_id = x.id and s.requisito is not null))
        order by x.creado_en desc), '[]'::jsonb)
      from (select * from public.permisos
             where cedula = v_id->>'cedula' and creado_en > now() - interval '120 days'
             order by creado_en desc limit 8) x));
end $$;
revoke all on function public.permiso_mis(text, date) from public;
grant execute on function public.permiso_mis(text, date) to anon, authenticated;

-- 4) …en el link de vacaciones (igual a sql/163 + 'reemplazo') -----------------------------------
create or replace function public.vacaciones_identificar(p_cedula text, p_fecha_nacimiento date)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento); v_p jsonb;
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  v_p := public._vac_persona(v_id->>'cedula');
  if v_p->>'estado' <> 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error', 'Tu registro aparece inactivo. Comunícate con Gestión Humana.');
  end if;
  return jsonb_build_object('ok', true,
    -- Nombre de pila: en Colombia van primero los dos apellidos.
    'nombre', initcap(lower(coalesce(nullif(array_to_string(
                (regexp_split_to_array(trim(v_p->>'nombre'), '\s+'))[3:], ' '), ''), v_p->>'nombre'))),
    'cargo', v_p->>'cargo', 'tipo', v_p->>'tipo', 'sabado_habil', v_p->'sabado_habil',
    'tiene_afiliado', v_p->>'afiliado' is not null, 'periodos', v_p->'periodos',
    'reemplazo', case when public._reemplazo_aplica(v_p->>'tipo', v_p->>'cargo')
                      then public._reemplazo_opciones(v_id->>'cedula') end,
    'solicitudes', (select coalesce(jsonb_agg(jsonb_build_object(
        'radicado', v.radicado, 'periodo', v.periodo, 'inicio', v.fecha_inicio, 'fin', v.fecha_fin,
        'regreso', v.fecha_regreso, 'disfrute', v.dias_disfrute, 'dinero', v.dias_dinero,
        'estado', v.estado, 'nomina', v.nom_en is not null,
        'nota', case when v.estado = 'NEGADO' then coalesce(v.gh_nota, v.ger_nota) end)
        order by v.creado_en desc), '[]'::jsonb)
      from (select * from public.vacaciones where cedula = v_id->>'cedula' order by creado_en desc limit 6) v));
end $$;
revoke all on function public.vacaciones_identificar(text, date) from public;
grant execute on function public.vacaciones_identificar(text, date) to anon, authenticated;

-- 5) …y cuando Gestión Humana registra vacaciones desde la app (igual a sql/163 + 'reemplazo') ----
create or replace function public.vacaciones_persona(p_cedula text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_p jsonb;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Solo Talento Humano registra vacaciones.');
  end if;
  v_p := public._vac_persona(regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g'));
  if v_p is null then return jsonb_build_object('ok', false, 'error', 'Esa cédula no está en el Perfil.'); end if;
  return v_p || jsonb_build_object('ok', true,
    'reemplazo', case when public._reemplazo_aplica(v_p->>'tipo', v_p->>'cargo')
                      then public._reemplazo_opciones(v_p->>'cedula') end);
end $$;
revoke all on function public.vacaciones_persona(text) from public, anon;
grant execute on function public.vacaciones_persona(text) to authenticated;
