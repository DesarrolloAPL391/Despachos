-- 75: PERFIL SOCIODEMOGRÁFICO de los empleados de Autobuses El Poblado
--     (conductores + administrativos, activos e inactivos). SOLO TALENTO HUMANO
--     (admin + rol gestion_humana, sql/78).
--
-- Origen: dos exportes de AppSheet ("APPS - admin.csv" y "APPS - Hoja 3.csv") donde cada fila es
-- una VINCULACIÓN (una persona que se retiró y volvió tiene varias filas). NINGÚN dato queda por
-- fuera: cada fila original se guarda completa en perfil_vinculaciones.datos_origen. Aquí queda:
--   * perfilsociodemografico : 1 fila por PERSONA (llave: cédula) con sus datos actuales.
--   * perfil_vinculaciones   : historial de ingresos/retiros (1 fila por vinculación).
--   * perfil_actualizaciones : lo que envían los empleados desde el LINK público de actualización
--                              de datos (actualizar-datos.html). NO se aplica solo: el admin lo
--                              revisa campo por campo y lo aplica o lo rechaza.
--
-- Datos sensibles (cédula, salario, salud, dirección, familia): las 3 tablas quedan con RLS de
-- Talento humano (admin + rol gestion_humana, sql/78). El link público NO lee nada: solo inserta una solicitud por el RPC
-- perfil_enviar_actualizacion (SECURITY DEFINER), que ni siquiera dice si la cédula existe.
--
-- `por_corregir`: lista (separada por comas) de campos que vinieron dañados o incoherentes en el
-- origen (p. ej. celular en notación científica 3,00E+09). Se limpia SOLA: cuando ese campo se
-- edita y queda con valor, sale de la lista (trigger perfil_antes_guardar).

-- ---- 0) ¿Quién es "Talento humano"? El ADMIN y el rol GESTIÓN HUMANA (sql/78) ----
-- Todo este módulo (y el de aspirantes, sql/77) se rige por es_talento_humano().
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

-- ---- 1) Persona ----
create table if not exists public.perfilsociodemografico (
  id                      bigint generated always as identity primary key,
  cedula                  text not null unique,
  nombre                  text not null,
  tipo                    text not null check (tipo in ('CONDUCTOR','ADMINISTRATIVO')),
  estado                  text not null default 'ACTIVO' check (estado in ('ACTIVO','INACTIVO')),
  codigo                  text,
  correo                  text,
  celular                 text,
  telefono                text,
  foto                    text,            -- ruta AppSheet (X_Images/…); se migra a Storage en un 2º paso
  -- Laboral (vinculación vigente / más reciente)
  fecha_ingreso           date,
  fecha_retiro            date,
  tipo_ingreso            text,            -- NUEVO / REINGRESO / PROVEEDOR
  tipo_contrato           text,
  cargo                   text,
  area                    text,
  salario                 numeric(14,2),
  centro_costos           text,
  nombre_propietario      text,
  placa                   text,
  novedad_retiro          text,
  -- Seguridad social
  eps                     text,
  afp                     text,
  arl                     text,
  -- Licencia y restricción (conductores)
  categoria_licencia      text,
  numero_licencia         text,
  licencia_expedicion     date,
  licencia_vencimiento    date,
  restricciones_licencia  text,
  estado_restriccion      text,            -- SIN RESTRICCION / RESTRINGIDO
  motivo_restriccion      text,
  -- Personal
  sexo                    text,
  fecha_nacimiento        date,
  tipo_sangre             text,
  estado_civil            text,
  uso_lentes              text,
  -- Vivienda
  direccion               text,
  barrio                  text,
  ciudad                  text,
  departamento            text,
  estrato                 smallint check (estrato between 0 and 6),
  tipo_vivienda           text,
  -- Educación
  escolaridad             text,            -- categoría normalizada
  escolaridad_detalle     text,            -- texto original (ej. OCTAVO, TÉCNICO EN MECÁNICA)
  institucion_educativa   text,
  fecha_ultimo_grado      date,
  ciudad_estudio          text,
  departamento_estudio    text,
  -- Núcleo familiar
  personas_a_cargo        text,
  convive_pareja          text,            -- SI / NO
  nombre_pareja           text,
  edad_pareja             text,
  tiene_hijos             text,            -- SI / NO
  edades_hijos            text,
  edades_hijas            text,
  otros_a_cargo           text,
  edades_otros            text,
  -- Contacto de emergencia
  emergencia_nombre       text,
  emergencia_parentesco   text,
  emergencia_direccion    text,
  emergencia_telefono1    text,
  emergencia_telefono2    text,
  -- Referencia laboral
  ref_empresa             text,
  ref_cargo               text,
  ref_telefono_jefe       text,
  ref_fecha_ingreso       date,
  ref_fecha_retiro        date,
  -- Adjuntos de AppSheet (rutas) y metadatos
  adjuntos                jsonb not null default '{}'::jsonb,
  por_corregir            text not null default '',
  calidad                 text generated always as (case when por_corregir <> '' then 'POR CORREGIR' else 'OK' end) stored,
  origen                  text,            -- ADMIN / CONDUCTORES / APP
  key_appsheet            text,
  habeas_data_aceptado_en timestamptz,
  creado_en               timestamptz not null default now(),
  actualizado_en          timestamptz not null default now(),
  actualizado_por         text
);
create index if not exists perfil_estado_tipo_idx on public.perfilsociodemografico (estado, tipo);
create index if not exists perfil_nombre_idx      on public.perfilsociodemografico (nombre);

-- ---- 2) Historial de vinculaciones ----
create table if not exists public.perfil_vinculaciones (
  id                 bigint generated always as identity primary key,
  cedula             text not null references public.perfilsociodemografico(cedula) on update cascade on delete cascade,
  key_appsheet       text unique,
  origen             text,                 -- ADMIN / CONDUCTORES / APP
  tipo               text,                 -- CONDUCTOR / ADMINISTRATIVO
  tipo_ingreso       text,                 -- NUEVO / REINGRESO / PROVEEDOR
  fecha_ingreso      date,
  fecha_retiro       date,
  estado             text,
  tipo_contrato      text,
  cargo              text,
  area               text,
  salario            numeric(14,2),
  centro_costos      text,
  placa              text,
  nombre_propietario text,
  novedad_retiro     text,
  -- La fila ORIGINAL completa del CSV ({encabezado: valor}, tal cual, sin limpiar): garantiza que
  -- no se pierda ningún dato aunque la normalización de la persona lo haya unificado o descartado.
  datos_origen       jsonb not null default '{}'::jsonb,
  creado_en          timestamptz not null default now()
);
create index if not exists perfil_vinc_cedula_idx on public.perfil_vinculaciones (cedula, fecha_ingreso desc);

-- ---- 3) Solicitudes del link de actualización de datos ----
create table if not exists public.perfil_actualizaciones (
  id               bigint generated always as identity primary key,
  cedula           text not null,
  fecha_nacimiento date,                   -- la que escribió la persona (para verificar identidad)
  nombre_informado text,
  tipo_informado   text,
  datos            jsonb not null,         -- solo campos permitidos (perfil_campos_autogestion)
  existe           boolean not null default false, -- la cédula ya estaba en el perfil
  identidad_ok     boolean not null default false, -- cédula + fecha de nacimiento coinciden
  acepta_habeas    boolean not null default false,
  estado           text not null default 'PENDIENTE' check (estado in ('PENDIENTE','APLICADA','RECHAZADA')),
  enviado_en       timestamptz not null default now(),
  revisado_por     text,
  revisado_en      timestamptz,
  campos_aplicados text[],
  motivo_rechazo   text
);
create index if not exists perfil_act_estado_idx on public.perfil_actualizaciones (estado, enviado_en desc);
create index if not exists perfil_act_cedula_idx on public.perfil_actualizaciones (cedula, enviado_en desc);

-- ---- 4) Seguridad: SOLO TALENTO HUMANO en las 3 tablas ----
alter table public.perfilsociodemografico enable row level security;
alter table public.perfil_vinculaciones   enable row level security;
alter table public.perfil_actualizaciones enable row level security;

drop policy if exists perfil_admin on public.perfilsociodemografico;
create policy perfil_admin on public.perfilsociodemografico
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));

drop policy if exists perfil_vinc_admin on public.perfil_vinculaciones;
create policy perfil_vinc_admin on public.perfil_vinculaciones
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));

-- Actualizaciones: el admin las ve/borra; NADIE inserta ni edita directo (solo por los RPC).
drop policy if exists perfil_act_sel on public.perfil_actualizaciones;
create policy perfil_act_sel on public.perfil_actualizaciones
  for select to authenticated using ((select public.es_talento_humano()));
drop policy if exists perfil_act_del on public.perfil_actualizaciones;
create policy perfil_act_del on public.perfil_actualizaciones
  for delete to authenticated using ((select public.es_talento_humano()));

revoke all on public.perfilsociodemografico, public.perfil_vinculaciones, public.perfil_actualizaciones from anon;

-- ---- 5) Campos que el empleado puede actualizar desde el link ----
create or replace function public.perfil_campos_autogestion()
returns text[] language sql immutable as $$
  select array[
    'celular','telefono','correo',
    'direccion','barrio','ciudad','departamento','estrato','tipo_vivienda',
    'sexo','fecha_nacimiento','tipo_sangre','estado_civil','uso_lentes',
    'escolaridad','escolaridad_detalle','institucion_educativa',
    'eps','afp',
    'personas_a_cargo','convive_pareja','nombre_pareja','edad_pareja','tiene_hijos','edades_hijos','edades_hijas','otros_a_cargo','edades_otros',
    'emergencia_nombre','emergencia_parentesco','emergencia_direccion','emergencia_telefono1','emergencia_telefono2',
    'categoria_licencia','numero_licencia','licencia_vencimiento'
  ]::text[]
$$;

-- ---- 6) Triggers de la persona ----
-- Antes de guardar: normaliza cédula/nombre, sella quién y cuándo, y saca de `por_corregir`
-- los campos que se acaban de corregir (cambiaron y quedaron con valor).
create or replace function public.perfil_antes_guardar()
returns trigger language plpgsql set search_path to 'public' as $$
declare
  v_new    jsonb;
  v_old    jsonb;
  v_it     text;
  v_quedan text[] := '{}';
begin
  new.cedula := regexp_replace(coalesce(new.cedula, ''), '\s', '', 'g');
  if new.cedula = '' then raise exception 'La cédula es obligatoria.'; end if;
  new.nombre := upper(btrim(regexp_replace(coalesce(new.nombre, ''), '\s+', ' ', 'g')));
  new.actualizado_en := now();
  new.actualizado_por := coalesce(nullif(auth.jwt() ->> 'email', ''), new.actualizado_por);
  if tg_op = 'UPDATE' and coalesce(new.por_corregir, '') <> '' then
    v_new := to_jsonb(new);
    v_old := to_jsonb(old);
    foreach v_it in array string_to_array(new.por_corregir, ',') loop
      v_it := btrim(v_it);
      continue when v_it = '';
      if (v_new ? v_it) and coalesce(v_new ->> v_it, '') <> ''
         and (v_new -> v_it) is distinct from (v_old -> v_it) then
        continue; -- corregido: sale de la lista
      end if;
      v_quedan := v_quedan || v_it;
    end loop;
    new.por_corregir := array_to_string(v_quedan, ',');
  end if;
  return new;
end $$;

drop trigger if exists perfil_antes_guardar_trg on public.perfilsociodemografico;
create trigger perfil_antes_guardar_trg
  before insert or update on public.perfilsociodemografico
  for each row execute function public.perfil_antes_guardar();

-- Después de guardar: mantiene el historial de vinculaciones cuando el admin crea un empleado
-- nuevo, lo retira o lo reintegra desde la app. La carga masiva lo apaga con
-- set_config('app.perfil_carga','on', true) porque trae su propio historial.
create or replace function public.perfil_despues_guardar()
returns trigger language plpgsql security definer set search_path to 'public' as $$
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

  -- REINGRESO: estaba INACTIVO, vuelve ACTIVO con una fecha de ingreso posterior → vinculación nueva
  if old.estado = 'INACTIVO' and new.estado = 'ACTIVO' and new.fecha_ingreso is not null
     and (old.fecha_ingreso is null or new.fecha_ingreso > old.fecha_ingreso) then
    insert into perfil_vinculaciones (cedula, origen, tipo, tipo_ingreso, fecha_ingreso, fecha_retiro, estado,
                                      tipo_contrato, cargo, area, salario, centro_costos, placa, nombre_propietario, novedad_retiro)
    values (new.cedula, 'APP', new.tipo, 'REINGRESO', new.fecha_ingreso, new.fecha_retiro, new.estado,
            new.tipo_contrato, new.cargo, new.area, new.salario, new.centro_costos, new.placa, new.nombre_propietario, new.novedad_retiro);
    return null;
  end if;

  -- Cualquier otro cambio laboral (retiro, cargo, salario, corrección de fecha…) se refleja
  -- en la vinculación vigente (la de ingreso más reciente).
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
        tipo = new.tipo, fecha_ingreso = new.fecha_ingreso, fecha_retiro = new.fecha_retiro, estado = new.estado,
        tipo_contrato = new.tipo_contrato, cargo = new.cargo, area = new.area, salario = new.salario,
        centro_costos = new.centro_costos, placa = new.placa, nombre_propietario = new.nombre_propietario,
        novedad_retiro = new.novedad_retiro
      where id = v_id;
    end if;
  end if;
  return null;
end $$;

drop trigger if exists perfil_despues_guardar_trg on public.perfilsociodemografico;
create trigger perfil_despues_guardar_trg
  after insert or update on public.perfilsociodemografico
  for each row execute function public.perfil_despues_guardar();

-- ---- 7) LINK PÚBLICO: el empleado envía sus datos (no lee nada) ----
create or replace function public.perfil_enviar_actualizacion(
  p_cedula text, p_fecha_nacimiento date, p_datos jsonb, p_acepta boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_ced    text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_json   jsonb := '{}'::jsonb;
  v_campos text[] := public.perfil_campos_autogestion();
  k        text;
  v        jsonb;
  v_txt    text;
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

  -- Solo campos permitidos, como texto, recortados y con tope de largo
  for k, v in select key, value from jsonb_each(p_datos) loop
    continue when not (k = any (v_campos));
    continue when jsonb_typeof(v) not in ('string', 'number');
    v_txt := btrim(v #>> '{}');
    continue when v_txt = '';
    if length(v_txt) > 300 then raise exception 'El campo % es demasiado largo.', k; end if;
    v_json := v_json || jsonb_build_object(k, v_txt);
  end loop;
  -- la fecha de nacimiento que escribió también es un dato actualizable
  v_json := v_json || jsonb_build_object('fecha_nacimiento', p_fecha_nacimiento::text);

  -- Valida tipos (fechas, estrato) sin aplicar nada
  begin
    perform jsonb_populate_record(null::public.perfilsociodemografico, v_json);
  exception when others then
    raise exception 'Hay un dato con formato no válido. Revisa las fechas y el estrato.';
  end;

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

-- ---- 8) Revisión del admin: aplicar (todo o algunos campos) o rechazar ----
create or replace function public.perfil_actualizacion_revisar(
  p_id bigint, p_aplicar boolean, p_campos text[] default null, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a        public.perfil_actualizaciones;
  cur      public.perfilsociodemografico;
  nue      public.perfilsociodemografico;
  v_json   jsonb;
  v_campos text[];
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

  nue := jsonb_populate_record(cur, v_json);
  update perfilsociodemografico set
    celular = nue.celular, telefono = nue.telefono, correo = nue.correo,
    direccion = nue.direccion, barrio = nue.barrio, ciudad = nue.ciudad, departamento = nue.departamento,
    estrato = nue.estrato, tipo_vivienda = nue.tipo_vivienda,
    sexo = nue.sexo, fecha_nacimiento = nue.fecha_nacimiento, tipo_sangre = nue.tipo_sangre,
    estado_civil = nue.estado_civil, uso_lentes = nue.uso_lentes,
    escolaridad = nue.escolaridad, escolaridad_detalle = nue.escolaridad_detalle, institucion_educativa = nue.institucion_educativa,
    eps = nue.eps, afp = nue.afp,
    personas_a_cargo = nue.personas_a_cargo, convive_pareja = nue.convive_pareja, nombre_pareja = nue.nombre_pareja,
    edad_pareja = nue.edad_pareja,
    tiene_hijos = nue.tiene_hijos, edades_hijos = nue.edades_hijos, edades_hijas = nue.edades_hijas,
    otros_a_cargo = nue.otros_a_cargo, edades_otros = nue.edades_otros,
    emergencia_nombre = nue.emergencia_nombre, emergencia_parentesco = nue.emergencia_parentesco,
    emergencia_direccion = nue.emergencia_direccion, emergencia_telefono1 = nue.emergencia_telefono1,
    emergencia_telefono2 = nue.emergencia_telefono2,
    categoria_licencia = nue.categoria_licencia, numero_licencia = nue.numero_licencia,
    licencia_vencimiento = nue.licencia_vencimiento,
    habeas_data_aceptado_en = case when a.acepta_habeas then a.enviado_en else habeas_data_aceptado_en end
  where id = cur.id;

  update perfil_actualizaciones
     set estado = 'APLICADA', revisado_por = v_email, revisado_en = now(), campos_aplicados = v_campos
   where id = p_id;
  return jsonb_build_object('ok', true, 'estado', 'APLICADA', 'campos', to_jsonb(v_campos));
end $$;
revoke all on function public.perfil_actualizacion_revisar(bigint, boolean, text[], text) from public;
grant execute on function public.perfil_actualizacion_revisar(bigint, boolean, text[], text) to authenticated;

-- Supabase concede EXECUTE a anon por defecto en funciones nuevas: se quita explícitamente
-- (el único RPC que el link público puede usar es perfil_enviar_actualizacion).
revoke execute on function public.perfil_actualizacion_revisar(bigint, boolean, text[], text) from anon;
revoke execute on function public.perfil_antes_guardar() from public, anon, authenticated;
revoke execute on function public.perfil_despues_guardar() from public, anon, authenticated;
