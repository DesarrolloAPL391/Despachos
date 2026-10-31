-- 152: la CÉDULA por foto en los links de la hoja de vida (actualizar-datos.html en sus dos modos y
-- trabaja-con-nosotros.html).
--
-- Pedido (31/10/2026): "que al tomarle foto a la cédula podamos leer los datos de la persona", en los
-- 3 links, y "sí, guardar frente y reverso" como soporte de la hoja de vida.
--
--   * La LECTURA corre en el celular (webapp/js/cedula-lector.js): el servidor no lee imágenes. Recibe
--     lo que la persona confirmó (como cualquier dato del link), las dos fotos y cómo se leyó
--     (cedula_lectura: CODIGO = código de barras de la amarilla, MRZ = líneas de la digital, NO).
--   * Las fotos de los links viajan en perfil_actualizaciones.datos (cedula_frente / cedula_reverso) y,
--     al aplicar, quedan en perfil_cedulas (aparte, como la foto y la firma).
--   * La bandeja de actualizaciones lista SIN las fotos de la cédula (datos_liviano): pesan unos 300 KB
--     cada una y la pestaña de aplicadas trae hasta 200 solicitudes. Se piden al tocar "Ver".
--   * Aspirantes: la cédula ya se sube como documento (bucket aspirantes). No se manda dos veces: al
--     contratar, perfil_cedulas apunta a esos archivos (frente_ruta / reverso_ruta).

-- ---- 1) La cédula de cada persona ----
create table if not exists public.perfil_cedulas (
  cedula       text primary key references public.perfilsociodemografico(cedula) on update cascade on delete cascade,
  frente       text check (frente like 'data:image/jpeg;base64,%' and length(frente) <= 450000),
  reverso      text check (reverso like 'data:image/jpeg;base64,%' and length(reverso) <= 450000),
  frente_ruta  text,                        -- archivo del bucket "aspirantes" (lo subió al inscribirse)
  reverso_ruta text,
  lectura      text check (lectura in ('CODIGO', 'MRZ', 'NO')),
  tomada_en    timestamptz not null,
  origen       text,                        -- LINK / ENLACE / ASPIRANTE
  guardado_en  timestamptz not null default now(),
  constraint perfil_cedulas_algo check (coalesce(frente, reverso, frente_ruta, reverso_ruta) is not null)
);
alter table public.perfil_cedulas enable row level security;
drop policy if exists perfil_cedulas_th on public.perfil_cedulas;
create policy perfil_cedulas_th on public.perfil_cedulas
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));
revoke all on public.perfil_cedulas from anon;

-- ---- 2) La bandeja lista sin las fotos de la cédula ----
alter table public.perfil_actualizaciones
  add column if not exists datos_liviano jsonb generated always as (datos - 'cedula_frente' - 'cedula_reverso') stored,
  add column if not exists tiene_cedula boolean generated always as (datos ? 'cedula_frente' or datos ? 'cedula_reverso') stored;

-- ---- 3) Las fotos de la cédula y cómo se leyó son datos que la persona envía ----
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
    'cedula_frente','cedula_reverso','cedula_lectura',
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
    elsif k in ('cedula_frente', 'cedula_reverso') then
      continue when jsonb_typeof(v) <> 'string';
      v_txt := v #>> '{}';
      if v_txt !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' or length(v_txt) > 450000 then
        raise exception 'La foto de la cédula no es válida. Vuelve a tomarla.';
      end if;
      v_json := v_json || jsonb_build_object(k, v_txt);
    elsif k = 'cedula_lectura' then
      continue when coalesce(v #>> '{}', '') not in ('CODIGO', 'MRZ', 'NO');
      v_json := v_json || jsonb_build_object(k, v #>> '{}');
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

-- ---- 4) Gestión Humana aplica: firma, foto y cédula van a sus tablas; lo demás a las columnas ----
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
  -- La cédula: un lado nuevo reemplaza al guardado (y a la copia de cuando fue aspirante)
  if v_json ?| array['cedula_frente', 'cedula_reverso'] then
    insert into perfil_cedulas (cedula, frente, reverso, lectura, tomada_en, origen)
    values (cur.cedula, v_json ->> 'cedula_frente', v_json ->> 'cedula_reverso', v_json ->> 'cedula_lectura', a.enviado_en, a.origen)
    on conflict (cedula) do update
      set frente       = coalesce(excluded.frente, perfil_cedulas.frente),
          reverso      = coalesce(excluded.reverso, perfil_cedulas.reverso),
          frente_ruta  = case when excluded.frente is not null then null else perfil_cedulas.frente_ruta end,
          reverso_ruta = case when excluded.reverso is not null then null else perfil_cedulas.reverso_ruta end,
          lectura      = coalesce(excluded.lectura, perfil_cedulas.lectura),
          tomada_en = excluded.tomada_en, origen = excluded.origen, guardado_en = now();
  end if;
  v_json := v_json - 'cedula_frente' - 'cedula_reverso' - 'cedula_lectura';
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

-- ---- 5) El enlace personal dice si ya tenemos su cédula (para no exigirla de nuevo) ----
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
    'tiene_firma', exists (select 1 from perfil_firmas where cedula = p.cedula),
    'tiene_cedula', exists (select 1 from perfil_cedulas where cedula = p.cedula));
end $$;

-- ---- 6) Al contratar un aspirante, la ficha apunta a la cédula que subió como documento ----
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
  v_fre   text;
  v_rev   text;
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
  -- Cédula: las fotos (no PDF) que subió como documento "cedula"; el lector las nombra frente/reverso
  select x ->> 'path' into v_fre
    from jsonb_array_elements(coalesce(new.adjuntos -> 'cedula', '[]'::jsonb)) with ordinality t(x, n)
   where x ->> 'path' ~* '\.(jpe?g|png|webp)$'
   order by (x ->> 'nombre') ilike '%reverso%', n limit 1;
  select x ->> 'path' into v_rev
    from jsonb_array_elements(coalesce(new.adjuntos -> 'cedula', '[]'::jsonb)) with ordinality t(x, n)
   where x ->> 'path' ~* '\.(jpe?g|png|webp)$' and x ->> 'path' is distinct from v_fre
   order by (x ->> 'nombre') ilike '%reverso%' desc, n limit 1;
  if v_fre is not null then
    insert into perfil_cedulas (cedula, frente_ruta, reverso_ruta, lectura, tomada_en, origen)
    values (v_ced, v_fre, v_rev, case when new.datos ->> 'cedula_lectura' in ('CODIGO', 'MRZ', 'NO') then new.datos ->> 'cedula_lectura' end,
            new.creado_en, 'ASPIRANTE')
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

-- ---- 7) Permisos (Supabase concede EXECUTE a anon por defecto: se quita explícitamente) ----
revoke all on function public.perfil_hv_enlace_abrir(uuid, text) from public;
grant execute on function public.perfil_hv_enlace_abrir(uuid, text) to anon, authenticated;
revoke all on function public._hv_limpiar(jsonb, text[]) from public, anon, authenticated;
revoke all on function public.aspirante_contratado_hv() from public, anon, authenticated;
