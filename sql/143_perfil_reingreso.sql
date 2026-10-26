-- 143_perfil_reingreso.sql
-- "al agregar un nuevo empleado debe dejar ingresar si ya existe, porque es un reingreso y
--  queda en el historial; debe estar inactivo para que puedan organizar todo" (26/10/2026).
--
-- QUE PASABA: la cedula es UNICA, asi que agregar a alguien que ya trabajo en la empresa moria
-- con un error de clave duplicada y no habia forma de seguir. El reingreso solo existia por la
-- puerta de los aspirantes (aspirante_contratar).
--
-- Y HABIA ALGO PEOR, MEDIDO AQUI MISMO: el trigger `perfil_despues_guardar` solo reconocia el
-- reingreso cuando la persona pasaba de INACTIVO a **ACTIVO**. Si se registraba el reingreso
-- dejandolo INACTIVO -- que es justo lo que se pidio, para organizarlo antes de activarlo --
-- el cambio caia en la rama de "actualizar la vinculacion vigente" y **PISABA el periodo
-- anterior**: la persona quedaba con una sola vinculacion, con la fecha nueva y marcada como
-- 'NUEVO'. Se perdia la antiguedad, y de ahi cuelgan el certificado laboral y las liquidaciones.
--
-- ARREGLO:
--   1) El trigger reconoce el reingreso por lo que de verdad lo define: la persona venia
--      RETIRADA (inactiva o con fecha de retiro) y entra con una fecha de ingreso posterior.
--      El estado en que quede ya no importa. Ademas cierra la vinculacion anterior en vez de
--      dejarla abierta.
--   2) `perfil_reingreso(...)` hace el alta completa y validada, y **deja la ficha INACTIVA**
--      para que Gestion Humana organice todo antes de activarla.
--   3) `perfil_buscar_cedula(...)` para que la pantalla avise "esta persona ya trabajo aqui"
--      ANTES de que el usuario llene todo el formulario y se estrelle con el error.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

-- ---------------------------------------------------------------------------
-- 1) El trigger: que el reingreso no se coma el periodo anterior
-- ---------------------------------------------------------------------------
create or replace function public.perfil_despues_guardar()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id bigint;
begin
  if coalesce(current_setting('app.perfil_carga', true), '') = 'on' then return null; end if;

  if tg_op = 'INSERT' then
    if new.fecha_ingreso is not null then
      insert into perfil_vinculaciones (cedula, origen, tipo, tipo_ingreso, fecha_ingreso, fecha_retiro, estado,
                                        tipo_contrato, cargo, area, salario, centro_costos, placa, nombre_propietario, novedad_retiro)
      values (new.cedula, 'APP', new.tipo, coalesce(new.tipo_ingreso, 'NUEVO'), new.fecha_ingreso, new.fecha_retiro, new.estado,
              new.tipo_contrato, new.cargo, new.area, new.salario, new.centro_costos, new.placa, new.nombre_propietario, new.novedad_retiro);
    end if;
    return null;
  end if;

  -- REINGRESO: la persona venia RETIRADA (inactiva o con fecha de retiro) y vuelve con una
  -- fecha de ingreso posterior. Antes se exigia ademas que quedara ACTIVA, y por eso un
  -- reingreso que se dejaba inactivo para organizarlo borraba el periodo anterior.
  if new.fecha_ingreso is not null
     and (old.fecha_ingreso is null or new.fecha_ingreso > old.fecha_ingreso)
     and (old.estado = 'INACTIVO' or old.fecha_retiro is not null) then

    -- La vinculacion que queda atras se cierra: si nadie le puso fecha de retiro, se le pone
    -- la que tenia la ficha, y si tampoco hay, el dia anterior al nuevo ingreso. Una
    -- vinculacion vieja abierta haria contar doble la antiguedad.
    update perfil_vinculaciones v
       set fecha_retiro = coalesce(v.fecha_retiro, old.fecha_retiro, new.fecha_ingreso - 1),
           estado = 'INACTIVO'
     where v.cedula = new.cedula
       and v.fecha_retiro is null
       and (v.fecha_ingreso is null or v.fecha_ingreso < new.fecha_ingreso);

    insert into perfil_vinculaciones (cedula, origen, tipo, tipo_ingreso, fecha_ingreso, fecha_retiro, estado,
                                      tipo_contrato, cargo, area, salario, centro_costos, placa, nombre_propietario, novedad_retiro)
    values (new.cedula, 'APP', new.tipo, 'REINGRESO', new.fecha_ingreso, new.fecha_retiro, new.estado,
            new.tipo_contrato, new.cargo, new.area, new.salario, new.centro_costos, new.placa, new.nombre_propietario, new.novedad_retiro);
    return null;
  end if;

  -- Cualquier otro cambio laboral (retiro, cargo, salario, correccion de fecha...) se refleja
  -- en la vinculacion vigente (la de ingreso mas reciente).
  if (new.estado, new.fecha_ingreso, new.fecha_retiro, new.tipo, new.tipo_contrato, new.cargo, new.area, new.salario,
      new.centro_costos, new.placa, new.nombre_propietario, new.novedad_retiro)
     is distinct from
     (old.estado, old.fecha_ingreso, old.fecha_retiro, old.tipo, old.tipo_contrato, old.cargo, old.area, old.salario,
      old.centro_costos, old.placa, old.nombre_propietario, old.novedad_retiro) then
    select id into v_id from perfil_vinculaciones
     where cedula = new.cedula order by fecha_ingreso desc nulls last, id desc limit 1;
    if v_id is null then
      if new.fecha_ingreso is not null then
        insert into perfil_vinculaciones (cedula, origen, tipo, tipo_ingreso, fecha_ingreso, fecha_retiro, estado,
                                          tipo_contrato, cargo, area, salario, centro_costos, placa, nombre_propietario, novedad_retiro)
        values (new.cedula, 'APP', new.tipo, coalesce(new.tipo_ingreso, 'NUEVO'), new.fecha_ingreso, new.fecha_retiro, new.estado,
                new.tipo_contrato, new.cargo, new.area, new.salario, new.centro_costos, new.placa, new.nombre_propietario, new.novedad_retiro);
      end if;
    else
      update perfil_vinculaciones set
        tipo = new.tipo, fecha_ingreso = new.fecha_ingreso, fecha_retiro = new.fecha_retiro,
        estado = new.estado, tipo_contrato = new.tipo_contrato, cargo = new.cargo, area = new.area,
        salario = new.salario, centro_costos = new.centro_costos, placa = new.placa,
        nombre_propietario = new.nombre_propietario, novedad_retiro = new.novedad_retiro
       where id = v_id;
    end if;
  end if;
  return null;
end $function$;

-- ---------------------------------------------------------------------------
-- 2) Antes de llenar el formulario: ¿esta persona ya existe?
-- ---------------------------------------------------------------------------
create or replace function public.perfil_buscar_cedula(p_cedula text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  r     public.perfilsociodemografico;
begin
  if not (public.es_admin() or public.es_talento_humano()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana.');
  end if;
  if length(v_ced) < 4 then
    return jsonb_build_object('ok', true, 'existe', false);
  end if;

  select * into r from public.perfilsociodemografico
   where regexp_replace(coalesce(cedula, ''), '\D', '', 'g') = v_ced;

  if r.id is null then
    return jsonb_build_object('ok', true, 'existe', false, 'cedula', v_ced);
  end if;

  return jsonb_build_object(
    'ok', true, 'existe', true,
    'cedula', r.cedula, 'nombre', r.nombre, 'estado', r.estado, 'tipo', r.tipo,
    'cargo', r.cargo, 'area', r.area,
    'ingreso', to_char(r.fecha_ingreso, 'DD/MM/YYYY'),
    'retiro', to_char(r.fecha_retiro, 'DD/MM/YYYY'),
    'novedad_retiro', r.novedad_retiro,
    'puede_reingresar', (r.estado = 'INACTIVO'),
    'historial', (select coalesce(jsonb_agg(jsonb_build_object(
                    'tipo_ingreso', v.tipo_ingreso, 'cargo', v.cargo, 'area', v.area,
                    'ingreso', to_char(v.fecha_ingreso, 'DD/MM/YYYY'),
                    'retiro', to_char(v.fecha_retiro, 'DD/MM/YYYY'),
                    'estado', v.estado, 'novedad', v.novedad_retiro)
                    order by v.fecha_ingreso desc nulls last), '[]'::jsonb)
                    from public.perfil_vinculaciones v where v.cedula = r.cedula));
end $function$;

revoke all on function public.perfil_buscar_cedula(text) from public, anon;
grant execute on function public.perfil_buscar_cedula(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) El reingreso
--    Queda INACTIVO a proposito: "para que puedan organizar todo". El historial SI se crea en
--    este momento (no al activarlo), porque si no, el periodo anterior se perderia.
-- ---------------------------------------------------------------------------
create or replace function public.perfil_reingreso(
  p_cedula        text,
  p_fecha_ingreso date,
  p_cargo         text    default null,
  p_area          text    default null,
  p_tipo_contrato text    default null,
  p_salario       numeric default null,
  p_codigo        text    default null,
  p_activar       boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  r     public.perfilsociodemografico;
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  if not (public.es_admin() or public.es_talento_humano()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana.');
  end if;

  select * into r from public.perfilsociodemografico
   where regexp_replace(coalesce(cedula, ''), '\D', '', 'g') = v_ced
   for update;

  if r.id is null then
    return jsonb_build_object('ok', false, 'error',
      'Esa cédula no existe en el Perfil. Es un ingreso nuevo, no un reingreso.');
  end if;
  if r.estado = 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error',
      'Esa persona ya está ACTIVA (' || coalesce(r.cargo, r.tipo) || '). No es un reingreso.');
  end if;
  if p_fecha_ingreso is null then
    return jsonb_build_object('ok', false, 'error', 'Indica la fecha de ingreso.');
  end if;
  if r.fecha_ingreso is not null and p_fecha_ingreso <= r.fecha_ingreso then
    return jsonb_build_object('ok', false, 'error',
      'La fecha de ingreso debe ser posterior a la del ingreso anterior (' ||
      to_char(r.fecha_ingreso, 'DD/MM/YYYY') || ').');
  end if;
  if p_fecha_ingreso > v_hoy + 90 or p_fecha_ingreso < v_hoy - 365 then
    return jsonb_build_object('ok', false, 'error', 'Revisa la fecha de ingreso.');
  end if;
  if p_salario is not null and p_salario < 0 then
    return jsonb_build_object('ok', false, 'error', 'El salario no es válido.');
  end if;

  -- El trigger se encarga de cerrar la vinculación anterior y abrir la del reingreso.
  update public.perfilsociodemografico set
      fecha_ingreso  = p_fecha_ingreso,
      fecha_retiro   = null,
      novedad_retiro = null,
      tipo_ingreso   = 'REINGRESO',
      estado         = case when p_activar then 'ACTIVO' else 'INACTIVO' end,
      cargo          = coalesce(nullif(upper(btrim(p_cargo)), ''), cargo),
      area           = coalesce(nullif(upper(btrim(p_area)), ''), area),
      tipo_contrato  = coalesce(nullif(upper(btrim(p_tipo_contrato)), ''), tipo_contrato),
      salario        = coalesce(p_salario, salario),
      codigo         = coalesce(nullif(btrim(p_codigo), ''), codigo)
   where id = r.id;

  return jsonb_build_object('ok', true,
    'cedula', r.cedula, 'nombre', r.nombre,
    'estado', case when p_activar then 'ACTIVO' else 'INACTIVO' end,
    'ingreso_anterior', to_char(r.fecha_ingreso, 'DD/MM/YYYY'),
    'ingreso_nuevo', to_char(p_fecha_ingreso, 'DD/MM/YYYY'),
    'vinculaciones', (select count(*) from public.perfil_vinculaciones where cedula = r.cedula),
    'nota', case when p_activar then 'Quedó activo.'
                 else 'Quedó INACTIVO para que terminen de organizarlo. Actívenlo desde la ficha.' end);
end $function$;

revoke all on function public.perfil_reingreso(text, date, text, text, text, numeric, text, boolean) from public, anon;
grant execute on function public.perfil_reingreso(text, date, text, text, text, numeric, text, boolean) to authenticated;

-- Comprobacion (solo lectura)
select 'el trigger ya no exige quedar ACTIVO' as dato,
       case when position('old.estado = ''INACTIVO'' or old.fecha_retiro is not null' in
                 pg_get_functiondef('public.perfil_despues_guardar()'::regprocedure)) > 0
            then 'si' else 'NO' end as valor
union all
select 'el trigger cierra la vinculacion anterior',
       case when position('fecha_retiro is null' in
                 pg_get_functiondef('public.perfil_despues_guardar()'::regprocedure)) > 0
            then 'si' else 'NO' end
union all
select 'funciones de reingreso',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('perfil_reingreso', 'perfil_buscar_cedula')) || ' de 2'
union all
select 'personas inactivas que podrian reingresar',
       (select count(*)::text from public.perfilsociodemografico where estado = 'INACTIVO');
