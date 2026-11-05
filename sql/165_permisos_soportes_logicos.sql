-- ============================================================================================
-- 165) Permisos y licencias: los soportes según la lógica de cada permiso
--
-- POR QUÉ: la revisión del módulo (04/11/2026) encontró que los soportes solo se MOSTRABAN.
--   * Se podía radicar cualquier permiso sin adjuntar nada.
--   * El tope era de 3 adjuntos, pero luto pedía 4 y grave calamidad 5.
--   * Varios soportes solo existen DESPUÉS del permiso (la asistencia a la cita, el registro de
--     defunción, el registro civil del bebé o del matrimonio) y no había cómo entregarlos luego.
--   * El soporte del parentesco depende del familiar: el registro civil del empleado prueba que
--     murió su padre, no su hijo ni su suegro.
--   * Calamidad pedía a la vez los soportes de desastre y los de hospitalización.
--   * No se controlaban las duraciones de ley (luto 5 días hábiles, paternidad 2 semanas,
--     maternidad 18 semanas) y se preguntaba si se repone el tiempo de una licencia de ley.
--   * El link no tenía freno: probando fechas de nacimiento se podía confirmar la de cualquiera.
--
-- QUÉ CAMBIA:
--   * Cada solicitud guarda el CASO (qué pasó), el PARENTESCO, qué jefe la autorizó y el día que
--     compensa. La base valida los mismos tipos, casos y parentescos que config.js (permisoReglas):
--     si se agrega uno allá, se agrega en _perm_regla.
--   * Cada soporte se guarda con el REQUISITO que cubre y se sube en su propia llamada
--     (permiso_soporte_subir): así caben todos los que pide el permiso, y los que se entregan
--     después llegan por el mismo link (permiso_mis le muestra al empleado lo que le falta).
--     Gestión Humana también puede adjuntar el que le entregan en papel (permiso_soporte_agregar).
--   * Duraciones y anticipación se AVISAN (alertas), no bloquean, como en vacaciones.
--   * El link usa el mismo freno de vacaciones (_vac_identificar): 8 fallos por hora y cédula.
-- ============================================================================================

-- 1) Lo que faltaba guardar ------------------------------------------------------------------------
alter table public.permisos
  add column if not exists caso           text,
  add column if not exists parentesco     text,
  add column if not exists autoriza       text,
  add column if not exists compensa_fecha date,
  add column if not exists alertas        text[] not null default '{}';
comment on column public.permisos.caso is 'Qué pasó (p. ej. HOSPITALIZACION o DESASTRE en calamidad): de eso dependen los soportes.';
comment on column public.permisos.parentesco is 'Con quién es el permiso (luto, calamidad por hospitalización): decide con qué se prueba el parentesco.';
comment on column public.permisos.alertas is 'Duraciones de ley y anticipación: se avisan a Gestión Humana, no bloquean.';

alter table public.permiso_soportes
  add column if not exists requisito  text,
  add column if not exists subido_por text not null default 'EMPLEADO';
comment on column public.permiso_soportes.requisito is 'Qué soporte cubre (clave de permisoReglas en config.js).';

-- 2) Las reglas de cada tipo (espejo de PERMISO_TIPOS en config.js) --------------------------------
--    repone: el empleado dice si repone el tiempo (las licencias de ley y el compensatorio, no).
--    antes: se pide con anticipación. autoriza: va con el nombre del jefe que lo autorizó.
--    compensa: pide el día que se compensa. casos / parentescos: las opciones válidas.
create or replace function public._perm_regla(p_tipo text, p_caso text)
returns jsonb
language sql immutable
as $$
  with par as (select
    '["PADRE O MADRE","HIJO(A)","HIJO(A) ADOPTIVO(A)","HERMANO(A)","ABUELO(A)","NIETO(A)","CONYUGE","COMPANERO(A) PERMANENTE","HIJASTRO(A)","SUEGRO(A)"]'::jsonb luto,
    '["PADRE O MADRE","HIJO(A)","HIJO(A) ADOPTIVO(A)","CONYUGE","COMPANERO(A) PERMANENTE","HIJASTRO(A)","SUEGRO(A)"]'::jsonb calamidad)
  select case p_tipo
    when 'CITA MEDICA' then jsonb_build_object('casos', '["PROGRAMADA","URGENCIA"]'::jsonb, 'repone', true,
      'antes', p_caso = 'PROGRAMADA')
    when 'MATERNIDAD O PATERNIDAD' then jsonb_build_object('casos', '["MATERNIDAD","PATERNIDAD"]'::jsonb, 'repone', false)
    when 'PERSONAL' then jsonb_build_object('repone', true, 'antes', true, 'autoriza', true)
    when 'MATRIMONIO' then jsonb_build_object('repone', true, 'antes', true)
    when 'CALAMIDAD DOMESTICA' then jsonb_build_object('casos', '["HOSPITALIZACION","DESASTRE","OTRA"]'::jsonb,
      'repone', true, 'parentescos', case when p_caso = 'HOSPITALIZACION' then par.calamidad end)
    when 'GRAVE CALAMIDAD DOMESTICA' then jsonb_build_object('casos', '["HOSPITALIZACION","DESASTRE"]'::jsonb,
      'repone', true, 'parentescos', case when p_caso = 'HOSPITALIZACION' then par.calamidad end)
    when 'LUTO' then jsonb_build_object('repone', false, 'parentescos', par.luto)
    when 'COMPENSATORIO' then jsonb_build_object('casos', '["TIEMPO","SEPELIO","VOTACION","JURADO"]'::jsonb,
      'repone', false, 'antes', p_caso in ('TIEMPO', 'VOTACION', 'JURADO'), 'autoriza', p_caso = 'TIEMPO',
      'compensa', p_caso in ('TIEMPO', 'VOTACION', 'JURADO'))
    when 'ESTUDIO' then jsonb_build_object('repone', true, 'antes', true)
  end
  from par;
$$;
revoke all on function public._perm_regla(text, text) from public, anon, authenticated;

-- 3) Lo que se le avisa a Gestión Humana -----------------------------------------------------------
create or replace function public._perm_alertas(
  p_tipo text, p_caso text, p_desde timestamp, p_hasta timestamp, p_compensa date,
  p_sabado boolean, p_antes boolean)
returns text[]
language plpgsql stable
set search_path to 'public'
as $$
declare
  a text[] := '{}';
  v_horas numeric := extract(epoch from (p_hasta - p_desde)) / 3600.0;
  v_dias int := p_hasta::date - p_desde::date;
  v_hoy timestamp := now() at time zone 'America/Bogota';
  v_hab int := 0; d date;
begin
  if p_antes and p_desde < v_hoy then
    a := array_append(a, 'Se pidió cuando el permiso ya había empezado.');
  end if;

  if p_tipo = 'LUTO' then
    -- Días hábiles de ausencia: sin domingos ni festivos, y el sábado solo para quien lo trabaja.
    -- "Hasta" es cuándo regresa: si vuelve en la mañana, ese día ya lo trabaja.
    d := p_desde::date;
    while d <= case when p_hasta::time <= time '12:00' then p_hasta::date - 1 else p_hasta::date end loop
      if not (extract(dow from d) = 0 or (extract(dow from d) = 6 and not coalesce(p_sabado, false))
              or public.es_festivo(d)) then
        v_hab := v_hab + 1;
      end if;
      d := d + 1;
    end loop;
    if v_hab > 5 then
      a := array_append(a, format('Son %s días hábiles de luto y la ley da 5 (Ley 1280 de 2009).', v_hab));
    end if;
  elsif p_tipo = 'MATERNIDAD O PATERNIDAD' then
    if p_caso = 'MATERNIDAD' and v_dias > 126 then
      a := array_append(a, format('Son %s días y la licencia de maternidad es de 18 semanas (126 días).', v_dias));
    elsif p_caso = 'PATERNIDAD' and v_dias > 14 then
      a := array_append(a, format('Son %s días y la licencia de paternidad es de 2 semanas (14 días).', v_dias));
    end if;
  elsif p_tipo = 'CITA MEDICA' and v_horas > 10 then
    a := array_append(a, 'Dura más de una jornada: si el médico incapacitó, va como incapacidad y no como permiso.');
  elsif p_tipo = 'COMPENSATORIO' then
    if p_caso = 'TIEMPO' and p_compensa > p_desde::date then
      a := array_append(a, 'Compensa un día que todavía no se ha trabajado.');
    elsif p_caso = 'VOTACION' then
      if v_horas > 6 then
        a := array_append(a, 'Es más de media jornada: por votar la ley da media jornada (Ley 403 de 1997).');
      end if;
      if p_desde::date > (p_compensa + interval '1 month')::date then
        a := array_append(a, 'Se toma después del mes siguiente a las elecciones (Ley 403 de 1997).');
      end if;
    elsif p_caso = 'JURADO' then
      if v_horas > 24 then
        a := array_append(a, 'Es más de un día: como jurado la ley da 1 día (Ley 163 de 1994).');
      end if;
      if p_desde::date > p_compensa + 45 then
        a := array_append(a, 'Se toma después de los 45 días siguientes a las elecciones (Ley 163 de 1994).');
      end if;
    end if;
    if p_caso in ('VOTACION', 'JURADO') and p_compensa > v_hoy::date then
      a := array_append(a, 'La fecha de las elecciones todavía no ha pasado.');
    end if;
  end if;
  return a;
end $$;
revoke all on function public._perm_alertas(text, text, timestamp, timestamp, date, boolean, boolean)
  from public, anon, authenticated;

-- 4) RADICAR (link público) ----------------------------------------------------------------------
--    Misma firma de antes con 4 parámetros nuevos al final, todos con valor por defecto: una página
--    vieja que todavía esté abierta sigue pudiendo radicar los tipos que no tienen casos.
drop function if exists public.permiso_radicar(text, date, text, text, timestamp, timestamp, text, boolean, text, text, jsonb);
create or replace function public.permiso_radicar(
  p_cedula text, p_fecha_nacimiento date, p_tipo text, p_motivo text,
  p_desde timestamp, p_hasta timestamp, p_reemplaza text default null,
  p_reposicion boolean default null, p_forma_reposicion text default null,
  p_celular text default null, p_soportes jsonb default '[]'::jsonb,
  p_caso text default null, p_parentesco text default null, p_autoriza text default null,
  p_compensa_fecha date default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento);
  v_p record; v_r jsonb; v_pid bigint; v_rad int; v_n int; s jsonb; v_repone boolean;
  v_tipo text := upper(trim(coalesce(p_tipo, '')));
  v_caso text := nullif(upper(trim(coalesce(p_caso, ''))), '');
  v_par text := nullif(upper(trim(coalesce(p_parentesco, ''))), '');
  v_hoy timestamp := now() at time zone 'America/Bogota';
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  select cedula, nombre, cargo, area, estado, tipo into v_p
    from public.perfilsociodemografico where cedula = v_id->>'cedula' limit 1;
  if v_p.estado is distinct from 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error', 'Tu registro aparece inactivo. Comunícate con Gestión Humana.');
  end if;

  -- Lo que pide el tipo de permiso
  v_r := public._perm_regla(v_tipo, v_caso);
  if v_r is null then
    return jsonb_build_object('ok', false, 'error', 'Elige el tipo de permiso.');
  end if;
  if v_r ? 'casos' then
    if v_caso is null or not (v_r->'casos' ? v_caso) then
      return jsonb_build_object('ok', false, 'error', 'Cuéntanos qué pasó: elige una de las opciones del permiso.');
    end if;
  else
    v_caso := null;
  end if;
  if jsonb_typeof(v_r->'parentescos') = 'array' then
    if v_par is null or not (v_r->'parentescos' ? v_par) then
      return jsonb_build_object('ok', false, 'error', 'Elige el parentesco con tu familiar.');
    end if;
  else
    v_par := null;
  end if;
  if coalesce((v_r->>'autoriza')::boolean, false) and coalesce(trim(p_autoriza), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe qué jefe te autorizó el permiso.');
  end if;
  if coalesce((v_r->>'compensa')::boolean, false) and p_compensa_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el día que se compensa.');
  end if;
  if not coalesce((v_r->>'compensa')::boolean, false) then p_compensa_fecha := null; end if;
  v_repone := coalesce((v_r->>'repone')::boolean, true);
  if v_repone and p_reposicion is null then
    return jsonb_build_object('ok', false, 'error', 'Dinos si vas a reponer el tiempo.');
  end if;

  if coalesce(trim(p_motivo), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe el motivo del permiso.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta <= p_desde then
    return jsonb_build_object('ok', false, 'error', 'Revisa las fechas: la de regreso debe ser posterior.');
  end if;
  if p_desde < v_hoy - interval '30 days' or p_desde > v_hoy + interval '365 days' then
    return jsonb_build_object('ok', false, 'error', 'La fecha del permiso está fuera de rango.');
  end if;

  -- Freno simple: una persona no radica 6 solicitudes el mismo día.
  select count(1) into v_n from public.permisos
   where cedula = v_p.cedula and creado_en > now() - interval '1 day';
  if v_n >= 5 then
    return jsonb_build_object('ok', false, 'error', 'Ya radicaste varias solicitudes hoy. Comunícate con Gestión Humana.');
  end if;

  insert into public.permisos
    (cedula, nombre, cargo, area, tipo, caso, parentesco, motivo, reemplaza, desde, hasta,
     reposicion, forma_reposicion, celular, autoriza, compensa_fecha, alertas)
  values (v_p.cedula, v_p.nombre, v_p.cargo, v_p.area, v_tipo, v_caso, v_par, left(trim(p_motivo), 400),
          left(nullif(trim(coalesce(p_reemplaza, '')), ''), 120), p_desde, p_hasta,
          v_repone and coalesce(p_reposicion, false),
          case when v_repone and coalesce(p_reposicion, false)
               then left(nullif(trim(coalesce(p_forma_reposicion, '')), ''), 200) end,
          nullif(regexp_replace(coalesce(p_celular, ''), '\D', '', 'g'), ''),
          left(nullif(trim(coalesce(p_autoriza, '')), ''), 120), p_compensa_fecha,
          public._perm_alertas(v_tipo, v_caso, p_desde, p_hasta, p_compensa_fecha,
                               public._vac_sabado(v_p.tipo, v_p.cargo), coalesce((v_r->>'antes')::boolean, false)))
  returning id, radicado into v_pid, v_rad;

  -- Soportes que vengan dentro de la misma llamada (la página vieja): máximo 3.
  -- La página nueva los sube uno por uno con permiso_soporte_subir.
  for s in select * from jsonb_array_elements(coalesce(p_soportes, '[]'::jsonb)) limit 3 loop
    if length(coalesce(s->>'archivo', '')) between 100 and 2000000 then
      insert into public.permiso_soportes (permiso_id, requisito, nombre, tipo_mime, archivo, bytes)
      values (v_pid, nullif(left(coalesce(s->>'requisito', ''), 40), ''), left(coalesce(s->>'nombre', 'soporte'), 120),
              s->>'tipo_mime', s->>'archivo', length(s->>'archivo'));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'radicado', v_rad);
end $$;
revoke all on function public.permiso_radicar(text, date, text, text, timestamp, timestamp, text, boolean, text, text, jsonb, text, text, text, date)
  from public;
grant execute on function public.permiso_radicar(text, date, text, text, timestamp, timestamp, text, boolean, text, text, jsonb, text, text, text, date)
  to anon, authenticated;

-- 5) Un soporte, en su propia llamada ------------------------------------------------------------
--    Solo fotos o PDF. Lo valida igual el link (empleado) y la app (Gestión Humana).
create or replace function public._perm_soporte_valido(p_requisito text, p_tipo_mime text, p_archivo text)
returns text
language sql immutable
as $$
  select case
    when coalesce(p_requisito, '') !~ '^[a-z_]{2,40}$' then 'Soporte no válido.'
    when lower(coalesce(p_tipo_mime, '')) not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')
      or left(coalesce(p_archivo, ''), length('data:' || lower(p_tipo_mime) || ';base64,'))
         <> 'data:' || lower(p_tipo_mime) || ';base64,'
      then 'El soporte debe ser una foto o un PDF.'
    when length(p_archivo) not between 100 and 2000000
      then 'El soporte pesa demasiado. Si es una foto, tómala con menos calidad; si es un PDF, envía uno más liviano.'
  end;
$$;
revoke all on function public._perm_soporte_valido(text, text, text) from public, anon, authenticated;

create or replace function public.permiso_soporte_subir(
  p_cedula text, p_fecha_nacimiento date, p_radicado int, p_requisito text,
  p_nombre text, p_tipo_mime text, p_archivo text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento);
  v_pid bigint; v_est text; v_n int; v_mal text;
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  select id, estado into v_pid, v_est from public.permisos
   where radicado = p_radicado and cedula = v_id->>'cedula';
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error', 'No encontramos ese radicado a tu nombre.');
  end if;
  if v_est in ('ANULADO', 'NEGADO') then
    return jsonb_build_object('ok', false, 'error', 'Esta solicitud está anulada o negada: ya no recibe soportes.');
  end if;
  v_mal := public._perm_soporte_valido(p_requisito, p_tipo_mime, p_archivo);
  if v_mal is not null then return jsonb_build_object('ok', false, 'error', v_mal); end if;
  select count(1) into v_n from public.permiso_soportes where permiso_id = v_pid;
  if v_n >= 12 then
    return jsonb_build_object('ok', false, 'error', 'Esta solicitud ya tiene el máximo de soportes. Llévalos a Gestión Humana.');
  end if;
  insert into public.permiso_soportes (permiso_id, requisito, nombre, tipo_mime, archivo, bytes, subido_por)
  values (v_pid, p_requisito, left(coalesce(nullif(trim(p_nombre), ''), 'soporte'), 120), lower(p_tipo_mime),
          p_archivo, length(p_archivo), 'EMPLEADO');
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.permiso_soporte_subir(text, date, int, text, text, text, text) from public;
grant execute on function public.permiso_soporte_subir(text, date, int, text, text, text, text) to anon, authenticated;

-- Gestión Humana adjunta el soporte que le entregaron en papel.
create or replace function public.permiso_soporte_agregar(
  p_id bigint, p_requisito text, p_nombre text, p_tipo_mime text, p_archivo text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_est text; v_mal text;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Solo Gestión Humana adjunta soportes.');
  end if;
  select estado into v_est from public.permisos where id = p_id;
  if v_est is null then return jsonb_build_object('ok', false, 'error', 'No se encontró la solicitud.'); end if;
  if v_est = 'ANULADO' then return jsonb_build_object('ok', false, 'error', 'La solicitud está anulada.'); end if;
  v_mal := public._perm_soporte_valido(p_requisito, p_tipo_mime, p_archivo);
  if v_mal is not null then return jsonb_build_object('ok', false, 'error', v_mal); end if;
  insert into public.permiso_soportes (permiso_id, requisito, nombre, tipo_mime, archivo, bytes, subido_por)
  values (p_id, p_requisito, left(coalesce(nullif(trim(p_nombre), ''), 'soporte'), 120), lower(p_tipo_mime),
          p_archivo, length(p_archivo), lower(coalesce(auth.email(), '')));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.permiso_soporte_agregar(bigint, text, text, text, text) from public, anon;
grant execute on function public.permiso_soporte_agregar(bigint, text, text, text, text) to authenticated;

-- 6) Lo que el empleado ve en el link: sus solicitudes y qué soportes ya entregó --------------------
--    Como vacaciones_identificar: solo el nombre de pila, el cargo y SUS solicitudes de los últimos
--    120 días. Qué soportes le faltan lo calcula la página con permisoReglas (config.js).
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

-- 7) Los soportes de una solicitud, ahora con el requisito que cubren y quién los subió -------------
create or replace function public.permiso_soportes_de(p_id bigint)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_permiso_ver() then '[]'::jsonb
    else (select coalesce(jsonb_agg(jsonb_build_object(
            'id', s.id, 'requisito', s.requisito, 'nombre', s.nombre, 'tipo_mime', s.tipo_mime,
            'archivo', s.archivo, 'bytes', s.bytes, 'subido_por', s.subido_por, 'creado_en', s.creado_en)
            order by s.id), '[]'::jsonb)
          from public.permiso_soportes s where s.permiso_id = p_id)
  end;
$$;
revoke all on function public.permiso_soportes_de(bigint) from public, anon;
grant execute on function public.permiso_soportes_de(bigint) to authenticated;
