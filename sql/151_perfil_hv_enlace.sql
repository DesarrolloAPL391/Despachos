-- 151: ENLACE PERSONAL para que el colaborador complete su hoja de vida FO-GH-03 (sql/150), y su FOTO.
--
-- Pedido (31/10/2026), desde la hoja de vida en PDF: "que se pueda generar un link para que el
-- conductor llene los campos, algo bien organizado, que se tome la foto, que los campos sean
-- dinámicos y que le explique qué debe hacer".
--
--   * Gestión Humana genera el enlace desde la ficha (perfil_hv_enlace_crear) y lo manda por
--     WhatsApp. Es de UNA persona, vence a los 7 días y sirve para UN envío.
--   * Quien abre el enlace demuestra que es la persona con su fecha de nacimiento o los últimos 4
--     dígitos de su cédula (si el enlace se reenvía, nadie más ve sus datos). 5 intentos fallidos
--     bloquean el enlace.
--   * Ya verificado, el formulario viene PRELLENADO con lo que el perfil tiene (solo los campos que
--     la persona misma actualiza: nunca salario ni datos laborales) y le dice qué le falta.
--   * Lo que envía llega a perfil_actualizaciones como cualquier actualización: Gestión Humana lo
--     revisa y lo aplica. Nada se aplica solo.
--   * La FOTO tipo documento va aparte (perfil_fotos), igual que la firma: la tabla del perfil se
--     lee completa y una imagen por persona la volvería pesada.

-- ---- 1) Foto del colaborador ----
create table if not exists public.perfil_fotos (
  cedula      text primary key references public.perfilsociodemografico(cedula) on update cascade on delete cascade,
  foto        text not null check (foto like 'data:image/jpeg;base64,%' and length(foto) <= 400000),
  tomada_en   timestamptz not null,
  origen      text,                           -- LINK / ENLACE / ASPIRANTE
  guardado_en timestamptz not null default now()
);
alter table public.perfil_fotos enable row level security;
drop policy if exists perfil_fotos_th on public.perfil_fotos;
create policy perfil_fotos_th on public.perfil_fotos
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));
revoke all on public.perfil_fotos from anon;

-- ---- 2) Enlaces personales ----
create table if not exists public.perfil_hv_enlaces (
  token          uuid primary key default gen_random_uuid(),
  cedula         text not null references public.perfilsociodemografico(cedula) on update cascade on delete cascade,
  creado_por     text,
  creado_en      timestamptz not null default now(),
  vence_en       timestamptz not null default now() + interval '7 days',
  intentos       smallint not null default 0,      -- claves equivocadas
  abierto_en     timestamptz,                      -- la primera vez que entró bien
  usado_en       timestamptz,                      -- cuando envió sus datos
  actualizacion_id bigint references public.perfil_actualizaciones(id) on delete set null
);
create index if not exists perfil_hv_enl_ced_idx on public.perfil_hv_enlaces (cedula, creado_en desc);
alter table public.perfil_hv_enlaces enable row level security;
drop policy if exists perfil_hv_enl_th on public.perfil_hv_enlaces;
create policy perfil_hv_enl_th on public.perfil_hv_enlaces
  for select to authenticated using ((select public.es_talento_humano()));
revoke all on public.perfil_hv_enlaces from anon;

-- De dónde llegó cada actualización (el link general o el enlace personal)
alter table public.perfil_actualizaciones add column if not exists origen text not null default 'LINK';

-- ---- 3) La foto es un dato que la persona envía (como la firma) ----
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
    'foto_colaborador',
    'categoria_licencia','numero_licencia','licencia_vencimiento'
  ]::text[]
$$;

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
    elsif k = 'foto_colaborador' then
      continue when jsonb_typeof(v) <> 'string';
      v_txt := v #>> '{}';
      if v_txt !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' or length(v_txt) > 400000 then
        raise exception 'La foto no es válida. Vuelve a tomarla.';
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

-- Gestión Humana aplica: la firma y la foto van a sus tablas, lo demás a las columnas del perfil
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

  if v_json ? 'declaracion_firma' then
    insert into perfil_firmas (cedula, firma, firmado_en, origen)
    values (cur.cedula, v_json ->> 'declaracion_firma', a.enviado_en, a.origen)
    on conflict (cedula) do update
      set firma = excluded.firma, firmado_en = excluded.firmado_en, origen = excluded.origen, guardado_en = now();
    v_json := v_json - 'declaracion_firma';
  end if;
  if v_json ? 'foto_colaborador' then
    insert into perfil_fotos (cedula, foto, tomada_en, origen)
    values (cur.cedula, v_json ->> 'foto_colaborador', a.enviado_en, a.origen)
    on conflict (cedula) do update
      set foto = excluded.foto, tomada_en = excluded.tomada_en, origen = excluded.origen, guardado_en = now();
    v_json := v_json - 'foto_colaborador';
  end if;
  if a.acepta_habeas then v_json := v_json || jsonb_build_object('habeas_data_aceptado_en', a.enviado_en); end if;

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

-- ---- 4) Gestión Humana genera el enlace ----
-- Si la persona ya tiene uno vigente y sin usar (le quedan más de 2 días), se reusa: mandar el
-- enlace dos veces no deja dos enlaces vivos.
create or replace function public.perfil_hv_enlace_crear(p_cedula text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_ced text := btrim(coalesce(p_cedula, ''));
  e     public.perfil_hv_enlaces;
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana genera estos enlaces.'; end if;
  if not exists (select 1 from perfilsociodemografico where cedula = v_ced) then raise exception 'La persona no está en el perfil.'; end if;
  select * into e from perfil_hv_enlaces
   where cedula = v_ced and usado_en is null and intentos < 5 and vence_en > now() + interval '2 days'
   order by creado_en desc limit 1;
  if e.token is null then
    insert into perfil_hv_enlaces (cedula, creado_por)
    values (v_ced, coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'))
    returning * into e;
  end if;
  return jsonb_build_object('ok', true, 'token', e.token, 'vence_en', e.vence_en, 'abierto_en', e.abierto_en);
end $$;

-- Verificación común de abrir y enviar: el enlace sirve y la clave es de la persona.
-- Clave = fecha de nacimiento (AAAA-MM-DD) o los últimos 4 dígitos de la cédula.
create or replace function public._hv_enlace_validar(p_token uuid, p_clave text)
returns public.perfilsociodemografico
language plpgsql security definer set search_path to 'public'
as $$
declare
  e  public.perfil_hv_enlaces;
  p  public.perfilsociodemografico;
  v_clave text := btrim(coalesce(p_clave, ''));
begin
  select * into e from perfil_hv_enlaces where token = p_token for update;
  if e.token is null or e.vence_en < now() then
    raise exception 'Este enlace ya no sirve (venció o no existe). Pide uno nuevo a Gestión Humana.';
  end if;
  if e.usado_en is not null then raise exception 'Ya recibimos tus datos con este enlace. Gestión Humana los está revisando.'; end if;
  if e.intentos >= 5 then raise exception 'Este enlace se bloqueó por seguridad. Pide uno nuevo a Gestión Humana.'; end if;
  select * into p from perfilsociodemografico where cedula = e.cedula;
  if not ((p.fecha_nacimiento is not null and v_clave = p.fecha_nacimiento::text)
          or (length(v_clave) = 4 and v_clave = right(regexp_replace(p.cedula, '\D', '', 'g'), 4))) then
    update perfil_hv_enlaces set intentos = intentos + 1 where token = p_token;
    return null;
  end if;
  if e.abierto_en is null then update perfil_hv_enlaces set abierto_en = now() where token = p_token; end if;
  return p;
end $$;

-- ---- 5) LINK: abrir. Sin clave solo saluda (nombre de pila); con clave, los datos para prellenar ----
create or replace function public.perfil_hv_enlace_abrir(p_token uuid, p_clave text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  e      public.perfil_hv_enlaces;
  p      public.perfilsociodemografico;
  v_nom  text;
  v_dat  jsonb;
  v_quedan int;
begin
  select * into e from perfil_hv_enlaces where token = p_token;
  if e.token is null or e.vence_en < now() then
    return jsonb_build_object('ok', false, 'motivo', 'Este enlace ya no sirve (venció o no existe). Pide uno nuevo a Gestión Humana.');
  end if;
  select * into p from perfilsociodemografico where cedula = e.cedula;
  -- "Juan" de "GOMEZ PEREZ JUAN CARLOS": en Colombia van primero los dos apellidos
  v_nom := initcap(coalesce((regexp_split_to_array(btrim(p.nombre), '\s+'))[case when array_length(regexp_split_to_array(btrim(p.nombre), '\s+'), 1) >= 3 then 3 else 1 end], ''));
  if e.usado_en is not null then
    return jsonb_build_object('ok', true, 'enviado', true, 'nombre_pila', v_nom);
  end if;
  if p_clave is null then
    return jsonb_build_object('ok', true, 'nombre_pila', v_nom, 'vence_en', e.vence_en);
  end if;

  p := public._hv_enlace_validar(p_token, p_clave);
  if p.id is null then
    select 5 - intentos into v_quedan from perfil_hv_enlaces where token = p_token;
    return jsonb_build_object('ok', false, 'clave_mala', true,
      'motivo', case when v_quedan > 0 then format('Ese dato no coincide. Te quedan %s intento(s).', v_quedan)
                     else 'Este enlace se bloqueó por seguridad. Pide uno nuevo a Gestión Humana.' end);
  end if;

  -- Solo lo que la persona misma puede actualizar (nunca salario ni datos laborales) + la referencia
  -- laboral vieja, para prellenar el primer empleo.
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_dat
    from jsonb_each(to_jsonb(p))
   where (key = any (public.perfil_campos_autogestion())
          or key in ('ref_empresa', 'ref_cargo', 'ref_telefono_jefe', 'ref_fecha_ingreso', 'ref_fecha_retiro'))
     and jsonb_typeof(value) <> 'null';
  return jsonb_build_object('ok', true, 'nombre_pila', v_nom, 'nombre', p.nombre, 'tipo', p.tipo,
    'cedula_fin', right(p.cedula, 4), 'datos', v_dat,
    'tiene_foto', exists (select 1 from perfil_fotos where cedula = p.cedula),
    'tiene_firma', exists (select 1 from perfil_firmas where cedula = p.cedula));
end $$;

-- ---- 6) LINK: enviar. Queda PENDIENTE para Gestión Humana, como el link general ----
create or replace function public.perfil_hv_enlace_enviar(p_token uuid, p_clave text, p_datos jsonb, p_acepta boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  p      public.perfilsociodemografico;
  v_json jsonb;
  v_id   bigint;
begin
  if not coalesce(p_acepta, false) then
    raise exception 'Debes aceptar la autorización de tratamiento de datos personales.';
  end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no válidos.'; end if;
  p := public._hv_enlace_validar(p_token, p_clave);
  -- Sin excepción: así el intento fallido queda contado (una excepción lo desharía)
  if p.id is null then return jsonb_build_object('ok', false, 'motivo', 'Ese dato no coincide. Vuelve a abrir el enlace.'); end if;

  v_json := public._hv_limpiar(p_datos, public.perfil_campos_autogestion());
  begin
    perform jsonb_populate_record(null::public.perfilsociodemografico, v_json);
  exception when others then
    raise exception 'Hay un dato con formato no válido. Revisa las fechas, el estrato y los años de experiencia.';
  end;
  if (v_json ->> 'experiencia_anios') is not null and (v_json ->> 'experiencia_anios') !~ '^\d{1,2}$' then
    raise exception 'Los años de experiencia deben ser un número.';
  end if;
  if v_json = '{}'::jsonb then raise exception 'No hay datos para enviar.'; end if;

  insert into perfil_actualizaciones (cedula, fecha_nacimiento, nombre_informado, tipo_informado, datos,
                                      existe, identidad_ok, acepta_habeas, origen)
  values (p.cedula, p.fecha_nacimiento, p.nombre, p.tipo, v_json, true, true, true, 'ENLACE')
  returning id into v_id;
  update perfil_hv_enlaces set usado_en = now(), actualizacion_id = v_id where token = p_token;
  return jsonb_build_object('ok', true);
end $$;

-- ---- 7) Al contratar un aspirante, su foto (si la mandó) también pasa ----
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
  if coalesce(new.datos ->> 'foto_colaborador', '') like 'data:image/jpeg;base64,%' then
    insert into perfil_fotos (cedula, foto, tomada_en, origen)
    values (v_ced, new.datos ->> 'foto_colaborador', new.creado_en, 'ASPIRANTE')
    on conflict (cedula) do nothing;
  end if;

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

-- ---- 8) Permisos ----
-- Supabase concede EXECUTE a anon por defecto en funciones nuevas: se quita explícitamente.
revoke all on function public.perfil_hv_enlace_crear(text) from public, anon;
grant execute on function public.perfil_hv_enlace_crear(text) to authenticated;
revoke all on function public._hv_enlace_validar(uuid, text) from public, anon, authenticated;
revoke all on function public.perfil_hv_enlace_abrir(uuid, text) from public;
grant execute on function public.perfil_hv_enlace_abrir(uuid, text) to anon, authenticated;
revoke all on function public.perfil_hv_enlace_enviar(uuid, text, jsonb, boolean) from public;
grant execute on function public.perfil_hv_enlace_enviar(uuid, text, jsonb, boolean) to anon, authenticated;
revoke all on function public._hv_limpiar(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.aspirante_contratado_hv() from public, anon, authenticated;
