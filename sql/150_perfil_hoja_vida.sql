-- 150: HOJA DE VIDA FO-GH-03 (v2, 24/03/2026) DENTRO DEL PERFIL SOCIODEMOGRÁFICO.
--
-- Pedido (31/10/2026): "la idea es incluirlos en el perfil sociodemográfico para que a partir de
-- ahora sean incluidos", y hacerlo POR PARTES, cada quien llena la suya:
--   * El COLABORADOR llena las secciones 2 a 6 y firma la declaración de veracidad y la
--     autorización de antecedentes por el link de actualización de datos (actualizar-datos.html).
--     Como siempre, nada se aplica solo: Gestión Humana lo revisa y lo aplica (sql/75).
--   * El ASPIRANTE las llena al inscribirse (trabaja-con-nosotros.html) y pasan al perfil al
--     contratarlo, con la verificación que ya hizo Gestión Humana durante el proceso (sql/77).
--   * GESTIÓN HUMANA llena la sección 1 (¿por APL o por un afiliado?) en la ficha, y la sección 7
--     (espacio exclusivo del empleador) en CADA VINCULACIÓN: cada ingreso tiene su propia
--     verificación de antecedentes y su propia aprobación.
--
-- Las listas (estudios, familiares, empleos) van en jsonb dentro del perfil. La FIRMA va aparte
-- (perfil_firmas): la tabla del perfil se lee completa (select *) y una imagen por persona la
-- volvería pesada. La sincronización con la hoja de Google (sql/133) no toca ninguna de estas
-- columnas: lo personal no se sobrescribe.

-- ---- 1) Columnas nuevas de la persona ----
alter table public.perfilsociodemografico
  -- 1. Información del cargo (Gestión Humana)
  add column if not exists vinculacion_por             text,     -- APL / AFILIADO
  -- 2. Información personal
  add column if not exists tipo_documento              text,     -- C.C. / T.I. / C.E. / PPT
  add column if not exists lugar_nacimiento            text,
  add column if not exists libreta_militar             text,
  add column if not exists libreta_militar_clase       text,     -- PRIMERA CLASE / SEGUNDA CLASE / NO TIENE
  add column if not exists ocupacion_actual            text,
  -- 3. Contacto y residencia
  add column if not exists localidad_comuna            text,
  -- 4. Académica: [{nivel, institucion, titulo, fecha_grado, ciudad, departamento, contacto, observaciones}]
  add column if not exists estudios                    jsonb not null default '[]'::jsonb,
  -- Familiar: [{nombre, parentesco, edad, ocupacion, depende, convive}]
  add column if not exists familiares                  jsonb not null default '[]'::jsonb,
  -- Segundo contacto de emergencia (el formato pide dos)
  add column if not exists emergencia2_nombre          text,
  add column if not exists emergencia2_parentesco      text,
  add column if not exists emergencia2_telefono1       text,
  add column if not exists emergencia2_telefono2       text,
  add column if not exists emergencia2_direccion       text,
  -- 5. Información laboral
  add column if not exists recomendado_por             text,
  add column if not exists trayectoria_laboral         text,
  add column if not exists experiencia_anios           smallint,
  add column if not exists vinculado_antes             text,     -- SI / NO (lo que declara la persona)
  add column if not exists vinculado_antes_detalle     text,     -- área, cargo o afiliado relacionado
  add column if not exists vinculado_antes_obs         text,
  add column if not exists laboro_exterior             text,     -- SI / NO
  add column if not exists exterior_detalle            text,     -- país(es) y actividad
  add column if not exists periodo_sin_vinculacion     text,     -- ej. DICIEMBRE 2024 - MARZO 2025
  add column if not exists actividades_sin_vinculacion text,
  -- 6. Experiencia laboral: [{empresa, cargo, jefe, telefono, funciones, fecha_ingreso, fecha_retiro, motivo_retiro}]
  add column if not exists empleos                     jsonb not null default '[]'::jsonb,
  add column if not exists experiencia_observaciones   text,
  -- Declaración de veracidad + autorización para consultar antecedentes (la firma, en perfil_firmas)
  add column if not exists declaracion_aceptada_en     timestamptz,
  add column if not exists declaracion_no_firma_motivo text;

alter table public.perfilsociodemografico drop constraint if exists perfil_hv_listas_chk;
alter table public.perfilsociodemografico add constraint perfil_hv_listas_chk
  check (jsonb_typeof(estudios) = 'array' and jsonb_typeof(familiares) = 'array' and jsonb_typeof(empleos) = 'array');
alter table public.perfilsociodemografico drop constraint if exists perfil_experiencia_anios_chk;
alter table public.perfilsociodemografico add constraint perfil_experiencia_anios_chk
  check (experiencia_anios between 0 and 60);

-- ---- 2) 7. Espacio exclusivo del empleador: uno por VINCULACIÓN ----
-- {fecha, filtro1, filtro2, area, responsable, vinculado_antes, motivo_retiro_anterior, runt_licencia,
--  estado, procuraduria_resultado/_fecha/_obs, contraloria_…, policia_…, simit_…, acuerdo_pago,
--  fotomultas, observaciones, aprob_gerencia(_fecha), aprob_afiliado(_fecha), aprob_junta(_fecha),
--  comentarios, por, en, aspirante_id}
alter table public.perfil_vinculaciones
  add column if not exists seleccion jsonb not null default '{}'::jsonb;

-- ---- 3) La firma del colaborador (aparte, por su peso) ----
create table if not exists public.perfil_firmas (
  cedula      text primary key references public.perfilsociodemografico(cedula) on update cascade on delete cascade,
  firma       text not null check (firma like 'data:image/png;base64,%' and length(firma) <= 200000),
  firmado_en  timestamptz not null,           -- cuando la persona firmó (envío del link o inscripción)
  origen      text,                           -- LINK / ASPIRANTE
  guardado_en timestamptz not null default now()
);
alter table public.perfil_firmas enable row level security;
drop policy if exists perfil_firmas_th on public.perfil_firmas;
create policy perfil_firmas_th on public.perfil_firmas
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));
revoke all on public.perfil_firmas from anon;

-- ---- 4) Campos que el empleado (y el aspirante) llenan por el link ----
create or replace function public.perfil_campos_autogestion()
returns text[] language sql immutable as $$
  select array[
    'celular','telefono','correo',
    'direccion','barrio','ciudad','departamento','estrato','tipo_vivienda','localidad_comuna',
    'sexo','fecha_nacimiento','tipo_sangre','estado_civil','uso_lentes',
    'tipo_documento','lugar_nacimiento','libreta_militar','libreta_militar_clase','ocupacion_actual',
    'escolaridad','escolaridad_detalle','institucion_educativa','fecha_ultimo_grado','ciudad_estudio','departamento_estudio',
    'estudios',
    'eps','afp',
    'personas_a_cargo','convive_pareja','nombre_pareja','edad_pareja','tiene_hijos','edades_hijos','edades_hijas','otros_a_cargo','edades_otros',
    'familiares',
    'emergencia_nombre','emergencia_parentesco','emergencia_direccion','emergencia_telefono1','emergencia_telefono2',
    'emergencia2_nombre','emergencia2_parentesco','emergencia2_direccion','emergencia2_telefono1','emergencia2_telefono2',
    'recomendado_por','trayectoria_laboral','experiencia_anios','vinculado_antes','vinculado_antes_detalle','vinculado_antes_obs',
    'laboro_exterior','exterior_detalle','periodo_sin_vinculacion','actividades_sin_vinculacion',
    'empleos','experiencia_observaciones',
    'declaracion_aceptada_en','declaracion_firma','declaracion_no_firma_motivo',
    'categoria_licencia','numero_licencia','licencia_vencimiento'
  ]::text[]
$$;

-- ---- 5) Limpieza de lo que llega por los links públicos ----
-- Una lista (estudios, familiares, empleos): solo las llaves conocidas, como texto, sin filas vacías.
create or replace function public._hv_lista(p_lista jsonb, p_campos text[], p_fechas text[], p_max int, p_nombre text)
returns jsonb language plpgsql stable set search_path to 'public' as $$
declare
  v_out  jsonb := '[]'::jsonb;
  v_it   jsonb;
  v_fila jsonb;
  v_f    date;
  k      text;
  v      jsonb;
  v_txt  text;
begin
  if p_lista is null or jsonb_typeof(p_lista) = 'null' then return '[]'::jsonb; end if;
  if jsonb_typeof(p_lista) <> 'array' then raise exception 'La lista de % no es válida.', p_nombre; end if;
  if jsonb_array_length(p_lista) > p_max then raise exception 'Máximo % en la lista de %.', p_max, p_nombre; end if;
  for v_it in select value from jsonb_array_elements(p_lista) loop
    continue when jsonb_typeof(v_it) <> 'object';
    v_fila := '{}'::jsonb;
    for k, v in select key, value from jsonb_each(v_it) loop
      continue when not (k = any (p_campos));
      continue when jsonb_typeof(v) not in ('string', 'number');
      v_txt := btrim(v #>> '{}');
      continue when v_txt = '';
      if length(v_txt) > 600 then raise exception 'Un dato de % es demasiado largo.', p_nombre; end if;
      if k = any (p_fechas) then
        begin
          v_f := v_txt::date;
        exception when others then
          raise exception 'Revisa las fechas de %.', p_nombre;
        end;
        if v_f < date '1940-01-01' or v_f > current_date + 366 then raise exception 'Revisa las fechas de %.', p_nombre; end if;
        v_txt := v_f::text;
      end if;
      v_fila := v_fila || jsonb_build_object(k, v_txt);
    end loop;
    if v_fila <> '{}'::jsonb then v_out := v_out || jsonb_build_array(v_fila); end if;
  end loop;
  return v_out;
end $$;

-- Todo el paquete: campos sueltos (texto con tope), listas y firma. La fecha de la declaración
-- la pone el servidor (casilla "declaracion_acepta"), nunca el navegador.
create or replace function public._hv_limpiar(p_datos jsonb, p_campos text[])
returns jsonb language plpgsql stable set search_path to 'public' as $$
declare
  v_json  jsonb := '{}'::jsonb;
  v_lista jsonb;
  k       text;
  v       jsonb;
  v_txt   text;
  v_tope  int;
  v_largo text[] := array['trayectoria_laboral','actividades_sin_vinculacion','experiencia_observaciones',
                          'vinculado_antes_obs','exterior_detalle','declaracion_no_firma_motivo'];
begin
  for k, v in select key, value from jsonb_each(p_datos) loop
    continue when not (k = any (p_campos)) or k = 'declaracion_aceptada_en';
    if k in ('estudios', 'familiares', 'empleos') then
      v_lista := case k
        when 'estudios' then public._hv_lista(v,
          array['nivel','institucion','titulo','fecha_grado','ciudad','departamento','contacto','observaciones'],
          array['fecha_grado'], 10, 'estudios')
        when 'familiares' then public._hv_lista(v,
          array['nombre','parentesco','edad','ocupacion','depende','convive'], '{}'::text[], 20, 'familiares')
        else public._hv_lista(v,
          array['empresa','cargo','jefe','telefono','funciones','fecha_ingreso','fecha_retiro','motivo_retiro'],
          array['fecha_ingreso','fecha_retiro'], 8, 'empleos')
      end;
      -- Una lista vacía no borra la que ya tenemos (igual que un campo vacío)
      continue when jsonb_array_length(v_lista) = 0;
      v_json := v_json || jsonb_build_object(k, v_lista);
    elsif k = 'declaracion_firma' then
      continue when jsonb_typeof(v) <> 'string';
      v_txt := v #>> '{}';
      if v_txt !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$' or length(v_txt) > 200000 then
        raise exception 'La firma no es válida. Vuelve a firmar.';
      end if;
      v_json := v_json || jsonb_build_object(k, v_txt);
    else
      continue when jsonb_typeof(v) not in ('string', 'number');
      v_txt := btrim(v #>> '{}');
      continue when v_txt = '';
      v_tope := case when k = any (v_largo) then 1500 else 300 end;
      if length(v_txt) > v_tope then raise exception 'El campo % es demasiado largo.', k; end if;
      v_json := v_json || jsonb_build_object(k, v_txt);
    end if;
  end loop;

  if 'declaracion_aceptada_en' = any (p_campos) and coalesce(p_datos ->> 'declaracion_acepta', '') = 'true' then
    if not (v_json ? 'declaracion_firma') and coalesce(v_json ->> 'declaracion_no_firma_motivo', '') = '' then
      raise exception 'Firma la declaración o escribe el motivo por el que no firmas.';
    end if;
    v_json := v_json || jsonb_build_object('declaracion_aceptada_en', now());
  end if;
  return v_json;
end $$;

-- ---- 6) LINK del colaborador: igual que antes, ahora con listas y firma ----
create or replace function public.perfil_enviar_actualizacion(
  p_cedula text, p_fecha_nacimiento date, p_datos jsonb, p_acepta boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_ced    text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_json   jsonb;
  v_perfil public.perfilsociodemografico;
begin
  if not coalesce(p_acepta, false) then
    raise exception 'Debes aceptar la autorización de tratamiento de datos personales.';
  end if;
  if length(v_ced) < 5 or length(v_ced) > 12 then raise exception 'El número de cédula no es válido.'; end if;
  if p_fecha_nacimiento is null or p_fecha_nacimiento < date '1930-01-01' or p_fecha_nacimiento > current_date - 14 * 365 then
    raise exception 'La fecha de nacimiento no es válida.';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no válidos.'; end if;

  -- Límites contra abuso del link público
  if (select count(1) from perfil_actualizaciones where cedula = v_ced and enviado_en > now() - interval '1 day') >= 3 then
    raise exception 'Ya recibimos tus datos hoy. Si necesitas corregir algo, comunícate con Gestión Humana.';
  end if;
  if (select count(1) from perfil_actualizaciones where enviado_en > now() - interval '1 hour') >= 400 then
    raise exception 'Hay muchas solicitudes en este momento. Intenta de nuevo en unos minutos.';
  end if;

  -- Solo campos permitidos (sueltos, listas y firma), con tope de largo
  v_json := public._hv_limpiar(p_datos, public.perfil_campos_autogestion());
  -- la fecha de nacimiento que escribió también es un dato actualizable
  v_json := v_json || jsonb_build_object('fecha_nacimiento', p_fecha_nacimiento::text);

  -- Valida tipos (fechas, estrato, años de experiencia) sin aplicar nada
  begin
    perform jsonb_populate_record(null::public.perfilsociodemografico, v_json);
  exception when others then
    raise exception 'Hay un dato con formato no válido. Revisa las fechas, el estrato y los años de experiencia.';
  end;
  if (v_json ->> 'experiencia_anios') is not null and (v_json ->> 'experiencia_anios') !~ '^\d{1,2}$' then
    raise exception 'Los años de experiencia deben ser un número.';
  end if;

  select * into v_perfil from perfilsociodemografico where cedula = v_ced;
  insert into perfil_actualizaciones (cedula, fecha_nacimiento, nombre_informado, tipo_informado, datos,
                                      existe, identidad_ok, acepta_habeas)
  values (v_ced, p_fecha_nacimiento,
          left(upper(btrim(p_datos ->> 'nombre')), 150),
          case when upper(p_datos ->> 'tipo') in ('CONDUCTOR', 'ADMINISTRATIVO') then upper(p_datos ->> 'tipo') end,
          v_json,
          v_perfil.id is not null,
          v_perfil.id is not null and v_perfil.fecha_nacimiento = p_fecha_nacimiento,
          true);
  -- Misma respuesta exista o no la cédula (el link no revela quién está en la base)
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.perfil_enviar_actualizacion(text, date, jsonb, boolean) from public;
grant execute on function public.perfil_enviar_actualizacion(text, date, jsonb, boolean) to anon, authenticated;

-- ---- 7) Revisión de Gestión Humana: aplica los campos marcados (cualquier columna del perfil) ----
-- Antes la lista de columnas estaba escrita a mano; ahora sale de los datos marcados, así un campo
-- nuevo del formato no obliga a tocar esta función.
create or replace function public.perfil_actualizacion_revisar(
  p_id bigint, p_aplicar boolean, p_campos text[] default null, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a        public.perfil_actualizaciones;
  cur      public.perfilsociodemografico;
  v_json   jsonb;
  v_campos text[];
  v_cols   text;
  v_email  text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin');
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana revisa las actualizaciones de datos.'; end if;
  select * into a from perfil_actualizaciones where id = p_id for update;
  if a.id is null then raise exception 'La solicitud no existe.'; end if;
  if a.estado <> 'PENDIENTE' then raise exception 'Esta solicitud ya fue revisada (%).', a.estado; end if;

  if not coalesce(p_aplicar, false) then
    update perfil_actualizaciones
       set estado = 'RECHAZADA', revisado_por = v_email, revisado_en = now(), motivo_rechazo = nullif(btrim(p_motivo), '')
     where id = p_id;
    return jsonb_build_object('ok', true, 'estado', 'RECHAZADA');
  end if;

  select * into cur from perfilsociodemografico where cedula = a.cedula for update;
  if cur.id is null then
    raise exception 'La cédula % no está en el perfil. Créala primero con "+ Nuevo" y vuelve a aplicar.', a.cedula;
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb), coalesce(array_agg(key), '{}')
    into v_json, v_campos
    from jsonb_each(a.datos)
   where key = any (public.perfil_campos_autogestion())
     and (p_campos is null or key = any (p_campos));
  if v_json = '{}'::jsonb then raise exception 'No marcaste ningún campo para aplicar.'; end if;

  -- La firma no es una columna del perfil: va a perfil_firmas
  if v_json ? 'declaracion_firma' then
    insert into perfil_firmas (cedula, firma, firmado_en, origen)
    values (cur.cedula, v_json ->> 'declaracion_firma', a.enviado_en, 'LINK')
    on conflict (cedula) do update
      set firma = excluded.firma, firmado_en = excluded.firmado_en, origen = excluded.origen, guardado_en = now();
    v_json := v_json - 'declaracion_firma';
  end if;
  if a.acepta_habeas then v_json := v_json || jsonb_build_object('habeas_data_aceptado_en', a.enviado_en); end if;

  -- Solo columnas reales y escribibles del perfil
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into v_cols
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'perfilsociodemografico'
     and c.is_generated = 'NEVER' and c.is_identity = 'NO'
     and v_json ? c.column_name;
  if v_cols is not null then
    execute format('update public.perfilsociodemografico set (%s) = (select %s from jsonb_populate_record(null::public.perfilsociodemografico, $1)) where id = $2',
                   v_cols, v_cols) using v_json, cur.id;
  end if;

  update perfil_actualizaciones
     set estado = 'APLICADA', revisado_por = v_email, revisado_en = now(), campos_aplicados = v_campos
   where id = p_id;
  return jsonb_build_object('ok', true, 'estado', 'APLICADA', 'campos', to_jsonb(v_campos));
end $$;
revoke all on function public.perfil_actualizacion_revisar(bigint, boolean, text[], text) from public, anon;
grant execute on function public.perfil_actualizacion_revisar(bigint, boolean, text[], text) to authenticated;

-- ---- 8) LINK del aspirante: acepta también las listas y la firma (mismo limpiador) ----
create or replace function public.aspirante_inscribir(p_datos jsonb, p_acepta boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_hoy    date := (now() at time zone 'America/Bogota')::date;
  v_ced    text := regexp_replace(coalesce(p_datos ->> 'cedula', ''), '\D', '', 'g');
  v_nom    text := upper(btrim(regexp_replace(coalesce(p_datos ->> 'nombre', ''), '\s+', ' ', 'g')));
  v_perfil text[] := public.aspirante_campos_perfil();
  v_extra  text[] := public.aspirante_campos_extra();
  v_json   jsonb;
  v_fn     date;
  v_cel    text;
  v_cat    text;
  v_row    public.aspirantes;
begin
  if not coalesce(p_acepta, false) then
    raise exception 'Debes aceptar la autorización de tratamiento de datos personales.';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no válidos.'; end if;
  if length(v_ced) < 5 or length(v_ced) > 12 then raise exception 'El número de cédula no es válido.'; end if;
  if length(v_nom) < 5 or length(v_nom) > 150 then raise exception 'Escribe tus apellidos y nombres completos.'; end if;

  -- Límites contra abuso del link público
  if (select count(1) from aspirantes where cedula = v_ced and creado_en > now() - interval '1 day') >= 3 then
    raise exception 'Ya recibimos tu inscripción hoy. Gestión Humana se comunicará contigo.';
  end if;
  if (select count(1) from aspirantes where creado_en > now() - interval '1 hour') >= 150 then
    raise exception 'Hay muchas inscripciones en este momento. Intenta de nuevo en unos minutos.';
  end if;

  -- Solo campos permitidos (sueltos, listas de la hoja de vida y firma), con tope de largo
  v_json := public._hv_limpiar(p_datos, v_perfil || v_extra);

  -- Tipos de los campos del perfil (fechas, estrato)
  begin
    perform jsonb_populate_record(null::public.perfilsociodemografico,
      (select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from jsonb_each(v_json) where key = any (v_perfil)));
  exception when others then
    raise exception 'Hay un dato con formato no válido. Revisa las fechas y el estrato.';
  end;

  v_fn := (v_json ->> 'fecha_nacimiento')::date;
  if v_fn is null or v_fn > (v_hoy - interval '18 years')::date or v_fn < (v_hoy - interval '80 years')::date then
    raise exception 'Revisa tu fecha de nacimiento (debes ser mayor de edad).';
  end if;
  v_cel := regexp_replace(coalesce(v_json ->> 'celular', ''), '\D', '', 'g');
  v_cel := regexp_replace(v_cel, '^57(3\d{9})$', '\1');
  if v_cel !~ '^3\d{9}$' then raise exception 'El celular debe tener 10 dígitos y empezar por 3.'; end if;
  v_json := v_json || jsonb_build_object('celular', v_cel);
  v_cat := upper(coalesce(v_json ->> 'categoria_licencia', ''));
  if v_cat not in ('A1','A2','B1','B2','B3','C1','C2','C3') then
    raise exception 'Indica la categoría de tu licencia de conducción.';
  end if;
  if (v_json ->> 'licencia_vencimiento') is null then
    raise exception 'Indica la fecha de vencimiento de tu licencia.';
  end if;
  if (v_json ->> 'experiencia_anios') is not null and (v_json ->> 'experiencia_anios') !~ '^\d{1,2}$' then
    raise exception 'Los años de experiencia deben ser un número.';
  end if;

  insert into aspirantes (cedula, nombre, fecha_nacimiento, celular, correo, ciudad, categoria_licencia,
                          licencia_vencimiento, experiencia_anios, datos, origen, acepta_habeas, habeas_data_aceptado_en)
  values (v_ced, v_nom, v_fn, v_cel, lower(v_json ->> 'correo'), upper(v_json ->> 'ciudad'), v_cat,
          (v_json ->> 'licencia_vencimiento')::date, (v_json ->> 'experiencia_anios')::smallint,
          v_json || jsonb_build_object('categoria_licencia', v_cat), 'LINK', true, now())
  returning * into v_row;

  insert into aspirante_historial (aspirante_id, accion, a_etapa, detalle, por)
  values (v_row.id, 'INSCRIPCION', 'DOCUMENTOS', 'Inscripción por el link público', 'aspirante');

  -- El token solo sirve para subir SUS documentos durante 3 horas
  return jsonb_build_object('ok', true, 'token', v_row.token_subida);
end $$;
revoke all on function public.aspirante_inscribir(jsonb, boolean) from public;
grant execute on function public.aspirante_inscribir(jsonb, boolean) to anon, authenticated;

-- ---- 9) Al CONTRATAR un aspirante: lo que el proceso ya sabía pasa a la hoja de vida ----
-- aspirante_contratar (sql/77) ya copia al perfil las columnas con el mismo nombre. Aquí va lo que
-- el proceso llama distinto, la firma de la inscripción y la sección 7 de la vinculación nueva
-- con la verificación de antecedentes que hizo Gestión Humana en la etapa de Documentos.
-- Nunca pisa lo que ya estaba lleno.
create or replace function public.aspirante_contratado_hv()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_doc   jsonb := coalesce(new.evaluaciones -> 'DOCUMENTOS', '{}'::jsonb);
  v_chk   jsonb := coalesce(new.evaluaciones -> 'DOCUMENTOS' -> 'checks', '{}'::jsonb);
  v_fecha text  := nullif(left(coalesce(new.evaluaciones -> 'DOCUMENTOS' ->> 'en', ''), 10), '');
  v_ced   text;
  v_vid   bigint;
  v_sel   jsonb;
  v_res   text;
  e       text;
begin
  if new.etapa <> 'CONTRATADO' or old.etapa = 'CONTRATADO' or new.perfil_id is null then return null; end if;
  select cedula into v_ced from perfilsociodemografico where id = new.perfil_id;
  if v_ced is null then return null; end if;

  update perfilsociodemografico p set
    recomendado_por   = coalesce(p.recomendado_por, nullif(btrim(new.datos ->> 'referido_por'), '')),
    vinculado_antes   = coalesce(p.vinculado_antes, nullif(btrim(new.datos ->> 'trabajo_antes_apl'), '')),
    experiencia_anios = coalesce(p.experiencia_anios, new.experiencia_anios),
    empleos = case when jsonb_array_length(p.empleos) = 0 and coalesce(new.datos ->> 'ref_empresa', '') <> ''
                   then jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                     'empresa', new.datos ->> 'ref_empresa', 'cargo', new.datos ->> 'ref_cargo',
                     'jefe', new.datos ->> 'ref_nombre_jefe', 'telefono', new.datos ->> 'ref_telefono_jefe',
                     'fecha_ingreso', new.datos ->> 'ref_fecha_ingreso', 'fecha_retiro', new.datos ->> 'ref_fecha_retiro',
                     'motivo_retiro', new.datos ->> 'ref_motivo_retiro')))
                   else p.empleos end
  where p.id = new.perfil_id;

  if coalesce(new.datos ->> 'declaracion_firma', '') like 'data:image/png;base64,%' then
    insert into perfil_firmas (cedula, firma, firmado_en, origen)
    values (v_ced, new.datos ->> 'declaracion_firma', new.creado_en, 'ASPIRANTE')
    on conflict (cedula) do nothing;
  end if;

  -- 7. Espacio del empleador de la vinculación que acaba de crear el contrato
  select id into v_vid from perfil_vinculaciones
   where cedula = v_ced order by fecha_ingreso desc nulls last, id desc limit 1;
  if v_vid is null then return null; end if;
  v_sel := jsonb_build_object(
    'fecha', (now() at time zone 'America/Bogota')::date::text,
    'area', 'OPERATIVA',
    'responsable', v_doc ->> 'por',
    'estado', 'APROBADO',
    'runt_licencia', nullif(btrim(new.datos ->> 'numero_licencia'), ''),
    'vinculado_antes', case when exists (select 1 from perfil_vinculaciones where cedula = v_ced and id <> v_vid) then 'SI' else 'NO' end,
    'motivo_retiro_anterior', (select novedad_retiro from perfil_vinculaciones where cedula = v_ced and id <> v_vid
                                order by fecha_ingreso desc nulls last, id desc limit 1),
    'aspirante_id', new.id);
  foreach e in array array['procuraduria', 'contraloria', 'policia', 'simit'] loop
    v_res := v_chk ->> e;
    continue when v_res is null or v_res not in ('OK', 'NO');
    v_sel := v_sel || jsonb_build_object(
      e || '_resultado', case
        when e = 'simit' then case when v_res = 'OK' then 'SIN MULTAS' else 'CON MULTAS PENDIENTES' end
        else case when v_res = 'OK' then 'SIN ANTECEDENTES' else 'CON ANTECEDENTES' end end,
      e || '_fecha', v_fecha);
  end loop;
  update perfil_vinculaciones set seleccion = jsonb_strip_nulls(v_sel) || seleccion where id = v_vid;
  return null;
end $$;
drop trigger if exists aspirante_contratado_hv_trg on public.aspirantes;
create trigger aspirante_contratado_hv_trg
  after update of etapa on public.aspirantes
  for each row execute function public.aspirante_contratado_hv();

-- ---- 10) Gestión Humana guarda la sección 7 de una vinculación ----
create or replace function public.perfil_seleccion_guardar(p_vinculacion bigint, p_datos jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_campos text[] := array[
    'fecha','filtro1','filtro2','area','responsable','vinculado_antes','motivo_retiro_anterior','runt_licencia','estado',
    'procuraduria_resultado','procuraduria_fecha','procuraduria_obs','contraloria_resultado','contraloria_fecha','contraloria_obs',
    'policia_resultado','policia_fecha','policia_obs','simit_resultado','simit_fecha','simit_obs',
    'acuerdo_pago','fotomultas','observaciones',
    'aprob_gerencia','aprob_gerencia_fecha','aprob_afiliado','aprob_afiliado_fecha','aprob_junta','aprob_junta_fecha',
    'comentarios'];
  v_json jsonb := '{}'::jsonb;
  v_ant  jsonb;
  k      text;
  v      jsonb;
  v_txt  text;
  v_f    date;
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana llena el espacio del empleador.'; end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no válidos.'; end if;
  select seleccion into v_ant from perfil_vinculaciones where id = p_vinculacion for update;
  if v_ant is null then raise exception 'La vinculación no existe.'; end if;

  for k, v in select key, value from jsonb_each(p_datos) loop
    continue when not (k = any (v_campos));
    continue when jsonb_typeof(v) not in ('string', 'number');
    v_txt := btrim(v #>> '{}');
    continue when v_txt = '';
    if length(v_txt) > 1500 then raise exception 'El campo % es demasiado largo.', k; end if;
    if k = 'fecha' or k like '%\_fecha' then
      begin
        v_f := v_txt::date;
      exception when others then
        raise exception 'Revisa las fechas.';
      end;
      v_txt := v_f::text;
    end if;
    v_json := v_json || jsonb_build_object(k, v_txt);
  end loop;
  if (v_json ->> 'estado') is not null and (v_json ->> 'estado') not in ('APROBADO', 'NO APROBADO') then
    raise exception 'El estado del proceso es APROBADO o NO APROBADO.';
  end if;

  v_json := v_json || jsonb_strip_nulls(jsonb_build_object('aspirante_id', v_ant -> 'aspirante_id'))
                   || jsonb_build_object('por', coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'), 'en', now());
  update perfil_vinculaciones set seleccion = v_json where id = p_vinculacion;
  return jsonb_build_object('ok', true, 'seleccion', v_json);
end $$;

-- ---- 11) Permisos ----
-- Supabase concede EXECUTE a anon por defecto en funciones nuevas: se quita explícitamente.
revoke all on function public._hv_lista(jsonb, text[], text[], int, text) from public, anon, authenticated;
revoke all on function public._hv_limpiar(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.aspirante_contratado_hv() from public, anon, authenticated;
revoke all on function public.perfil_seleccion_guardar(bigint, jsonb) from public, anon;
grant execute on function public.perfil_seleccion_guardar(bigint, jsonb) to authenticated;
