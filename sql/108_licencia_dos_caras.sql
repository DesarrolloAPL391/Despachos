-- ===================================================================================
-- 108: LICENCIA DE CONDUCCIÓN — las dos caras y la fecha de actualización (amplía sql/76).
-- ===================================================================================
-- Hasta hoy el despachador subía UNA foto y operaciones registraba a mano la nueva fecha
-- de vencimiento. El problema es que esa fecha NO está en el frente de la licencia: está
-- en el RESPALDO, en la tabla de categorías, con una vigencia por categoría. Con una sola
-- foto —casi siempre la del frente, que es la que la gente asocia con "la licencia"—
-- operaciones tenía que escribir una fecha que no podía verificar.
--
-- Ahora se suben las DOS CARAS, el sistema dice cuál va primero, y al aprobar queda
-- registrado CUÁNDO se actualizó, que es lo que permite saber si el dato está fresco o
-- lleva tres años sin tocarse.
--
-- El proceso no cambia: el DESPACHADOR monta las fotos, OPERACIONES registra la fecha.
-- Sigue siendo solo alerta: no bloquea el despacho (decisión del 16/09/2026, sql/76).
-- ===================================================================================

-- ---------- 1) Las dos caras ----------
alter table public.licencia_actualizaciones
  add column if not exists archivo_respaldo_path   text,
  add column if not exists archivo_respaldo_nombre text;

comment on column public.licencia_actualizaciones.archivo_path is
  'Foto del FRENTE de la licencia (el lado de la foto y el nombre).';
comment on column public.licencia_actualizaciones.archivo_respaldo_path is
  'Foto del RESPALDO: el lado con las categorias y las fechas de vigencia. De ahi sale la fecha.';

-- ---------- 2) Cuándo se actualizó ----------
alter table public.perfilsociodemografico
  add column if not exists licencia_actualizada_en date;
comment on column public.perfilsociodemografico.licencia_actualizada_en is
  'Fecha en que operaciones aprobo la ultima actualizacion de la licencia. Dice si el dato esta fresco.';

-- ---------- 3) El despachador sube las dos caras ----------
-- La firma vieja (4 argumentos) se deja viva a propósito: una app que quedó en caché la
-- seguiría llamando y subiría una sola foto sin que nadie se entere. Así avisa qué pasa.
create or replace function public.licencia_actualizacion_subir(
  p_dr_id text, p_archivo_path text, p_archivo_nombre text, p_observacion text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  raise exception 'Actualiza la aplicación (Ctrl+Shift+R): ahora se suben las dos caras de la licencia.';
end $$;

create or replace function public.licencia_actualizacion_subir(
  p_dr_id text, p_archivo_path text, p_archivo_nombre text,
  p_respaldo_path text, p_respaldo_nombre text, p_observacion text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_ced text;
  v_nom text;
  p     public.perfilsociodemografico;
  v_id  bigint;
begin
  if not (public.es_admin() or public.es_despachador()) then
    raise exception 'Solo despachadores, operaciones o admin suben licencias.';
  end if;
  if coalesce(p_archivo_path, '') = '' or position(p_dr_id || '/' in p_archivo_path) <> 1 then
    raise exception 'Falta la foto del FRENTE de la licencia.';
  end if;
  if coalesce(p_respaldo_path, '') = '' or position(p_dr_id || '/' in p_respaldo_path) <> 1 then
    raise exception 'Falta la foto del RESPALDO: ahí está la fecha de vencimiento.';
  end if;
  if p_archivo_path = p_respaldo_path then
    raise exception 'Las dos fotos son el mismo archivo. Toma una del frente y otra del respaldo.';
  end if;

  select regexp_replace(coalesce(cedula, ''), '\D', '', 'g'), nombre into v_ced, v_nom
    from conductores_sonar where dr_id::text = p_dr_id limit 1;
  select * into p from perfilsociodemografico where cedula = coalesce(v_ced, '');
  if p.id is null then raise exception 'Este conductor no está en el perfil sociodemográfico.'; end if;
  if p.licencia_vencimiento is not null and p.licencia_vencimiento > v_hoy + 30 then
    raise exception 'La licencia de este conductor está vigente (vence %).', to_char(p.licencia_vencimiento, 'DD/MM/YYYY');
  end if;
  if exists (select 1 from licencia_actualizaciones where cedula = p.cedula and estado = 'PENDIENTE') then
    raise exception 'Ya hay una licencia de este conductor en revisión.';
  end if;

  insert into licencia_actualizaciones (cedula, dr_id, conductor_nombre, vence_anterior,
                                        archivo_path, archivo_nombre,
                                        archivo_respaldo_path, archivo_respaldo_nombre,
                                        observacion, subido_por)
  values (p.cedula, p_dr_id, coalesce(v_nom, p.nombre), p.licencia_vencimiento,
          p_archivo_path, left(p_archivo_nombre, 200),
          p_respaldo_path, left(p_respaldo_nombre, 200),
          nullif(left(btrim(coalesce(p_observacion, '')), 500), ''), coalesce(auth.email(), 'desconocido'))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.licencia_actualizacion_subir(text, text, text, text, text, text) from public, anon;
grant execute on function public.licencia_actualizacion_subir(text, text, text, text, text, text) to authenticated;

-- ---------- 4) El listado para operaciones: las dos fotos y cuándo se actualizó ----------
create or replace function public.licencia_actualizaciones_listar(p_estado text default null)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', la.id, 'dr_id', la.dr_id, 'conductor_nombre', la.conductor_nombre, 'vence_anterior', la.vence_anterior,
           'vence_actual', p.licencia_vencimiento, 'categoria_actual', p.categoria_licencia,
           'actualizada_en', p.licencia_actualizada_en,
           'archivo_path', la.archivo_path, 'archivo_nombre', la.archivo_nombre,
           'archivo_respaldo_path', la.archivo_respaldo_path, 'archivo_respaldo_nombre', la.archivo_respaldo_nombre,
           'observacion', la.observacion,
           'estado', la.estado, 'subido_por', la.subido_por, 'subido_en', la.subido_en,
           'revisado_por', la.revisado_por, 'revisado_en', la.revisado_en, 'nueva_fecha', la.nueva_fecha,
           'nueva_categoria', la.nueva_categoria, 'nuevo_numero', la.nuevo_numero, 'motivo_rechazo', la.motivo_rechazo)
         order by la.subido_en desc), '[]'::jsonb)
    from (select * from licencia_actualizaciones
           where (p_estado is null or estado = p_estado) and public.es_operaciones()
           order by subido_en desc limit 300) la
    left join perfilsociodemografico p on p.cedula = la.cedula
$$;
revoke all on function public.licencia_actualizaciones_listar(text) from public, anon;
grant execute on function public.licencia_actualizaciones_listar(text) to authenticated;

-- ---------- 5) Operaciones aprueba: guarda las dos caras y la fecha de actualización ----------
create or replace function public.licencia_actualizacion_revisar(
  p_id bigint, p_aprobar boolean, p_nueva_fecha date, p_categoria text, p_numero text, p_motivo text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  a     public.licencia_actualizaciones;
  v_cat text := upper(nullif(btrim(coalesce(p_categoria, '')), ''));
  v_num text := nullif(regexp_replace(coalesce(p_numero, ''), '\s', '', 'g'), '');
begin
  if not public.es_operaciones() then raise exception 'Solo operaciones o admin revisan licencias.'; end if;
  select * into a from licencia_actualizaciones where id = p_id for update;
  if a.id is null then raise exception 'La solicitud no existe.'; end if;
  if a.estado <> 'PENDIENTE' then raise exception 'Esta licencia ya fue revisada (%).', a.estado; end if;

  if coalesce(p_aprobar, false) then
    if p_nueva_fecha is null or p_nueva_fecha <= v_hoy then
      raise exception 'Escribe la NUEVA fecha de vencimiento de la licencia (debe ser posterior a hoy).';
    end if;
    if v_cat is not null and v_cat !~ '^[ABC][1-3]$' then raise exception 'Categoría de licencia no válida.'; end if;
    update perfilsociodemografico set
      licencia_vencimiento    = p_nueva_fecha,
      categoria_licencia      = coalesce(v_cat, categoria_licencia),
      numero_licencia         = coalesce(v_num, numero_licencia),
      licencia_actualizada_en = v_hoy,
      -- Las dos caras quedan guardadas: el frente identifica, el respaldo es el soporte
      -- de la fecha que se acaba de registrar.
      adjuntos = adjuntos
                 || jsonb_build_object('licencia_frente', a.archivo_path)
                 || case when a.archivo_respaldo_path is not null
                         then jsonb_build_object('licencia_respaldo', a.archivo_respaldo_path)
                         else '{}'::jsonb end
                 || jsonb_build_object('licencia_renovada', a.archivo_path)   -- compatibilidad con sql/76
    where cedula = a.cedula;
    update licencia_actualizaciones set estado = 'APROBADO', revisado_por = coalesce(auth.email(), 'admin'), revisado_en = now(),
           nueva_fecha = p_nueva_fecha, nueva_categoria = v_cat, nuevo_numero = v_num
     where id = p_id;
    return jsonb_build_object('ok', true, 'estado', 'APROBADO');
  end if;

  if nullif(btrim(coalesce(p_motivo, '')), '') is null then raise exception 'Escribe el motivo del rechazo.'; end if;
  update licencia_actualizaciones set estado = 'RECHAZADO', revisado_por = coalesce(auth.email(), 'admin'), revisado_en = now(),
         motivo_rechazo = left(btrim(p_motivo), 500)
   where id = p_id;
  return jsonb_build_object('ok', true, 'estado', 'RECHAZADO');
end $$;
revoke all on function public.licencia_actualizacion_revisar(bigint, boolean, date, text, text, text) from public, anon;
grant execute on function public.licencia_actualizacion_revisar(bigint, boolean, date, text, text, text) to authenticated;

-- ---------- 6) El estado de la licencia, con la fecha de actualización ----------
-- Es la misma de sql/76 con UN campo nuevo: actualizada_en. El resto del contrato
-- (encontrado, nivel, solicitud del mismo ciclo) se conserva tal cual, porque de eso
-- depende la alerta que ve el despachador al despachar.
create or replace function public.licencia_estado(p_dr_id text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_hoy  date := (now() at time zone 'America/Bogota')::date;
  v_ced  text;
  v_nom  text;
  p      public.perfilsociodemografico;
  s      public.licencia_actualizaciones;
  v_dias int;
begin
  if not (public.es_admin() or public.es_despachador() or public.es_auditor()) then return null; end if;
  select regexp_replace(coalesce(cedula, ''), '\D', '', 'g'), nombre into v_ced, v_nom
    from conductores_sonar where dr_id::text = p_dr_id limit 1;
  if coalesce(v_ced, '') = '' then return jsonb_build_object('encontrado', false); end if;
  select * into p from perfilsociodemografico where cedula = v_ced;
  if p.id is null then return jsonb_build_object('encontrado', false, 'nombre', v_nom); end if;
  -- solicitud del MISMO ciclo (subida con el vencimiento que tiene hoy la licencia)
  select * into s from licencia_actualizaciones
   where cedula = v_ced and vence_anterior is not distinct from p.licencia_vencimiento
   order by subido_en desc limit 1;
  v_dias := p.licencia_vencimiento - v_hoy;
  return jsonb_build_object(
    'encontrado', true,
    'nombre', coalesce(v_nom, p.nombre),
    'activo', p.estado = 'ACTIVO',          -- estado en Gestión Humana (el archivo)
    'vence', p.licencia_vencimiento,
    'dias', v_dias,
    'categoria', p.categoria_licencia,
    'actualizada_en', p.licencia_actualizada_en,   -- sql/108: cuándo se registró por última vez
    'nivel', case when p.licencia_vencimiento is null then 'sin_dato'
                  when v_dias < 0 then 'vencida'
                  when v_dias <= 30 then 'por_vencer'
                  else 'vigente' end,
    'solicitud', case when s.id is null then null
                      else jsonb_build_object('estado', s.estado, 'subido_en', s.subido_en, 'subido_por', s.subido_por,
                                              'motivo_rechazo', s.motivo_rechazo) end);
end $$;
revoke all on function public.licencia_estado(text) from public, anon;
grant execute on function public.licencia_estado(text) to authenticated;
