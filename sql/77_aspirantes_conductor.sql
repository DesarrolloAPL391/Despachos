-- 77: PROCESO DE ASPIRANTES A CONDUCTOR (selección de personal). SOLO TALENTO HUMANO
--     (admin + rol gestion_humana, sql/78).
--
-- Decisiones del usuario (16/09/2026):
--   * El aspirante se inscribe por un LINK PÚBLICO (trabaja-con-nosotros.html): datos + documentos.
--   * Etapas, en orden:  1 DOCUMENTOS  (hoja de vida, cédula, licencia, antecedentes Policía /
--                                       Procuraduría / Contraloría, SIMIT / RUNT)
--                        2 ENTREVISTA  (entrevista de Gestión Humana + pruebas psicotécnicas)
--                        3 MANEJO      (prueba práctica de manejo)
--                        4 MEDICOS     (exámenes médicos de ingreso + visita domiciliaria)
--                        → POR_CONTRATAR → CONTRATADO
--     En cualquier etapa se puede DESCARTAR (con motivo) y luego REABRIR.
--   * Solo TALENTO HUMANO ve y decide: el admin y el rol gestion_humana (sql/78).
--   * Al CONTRATAR pasa SOLO al Perfil sociodemográfico (sql/75) como CONDUCTOR ACTIVO con los datos
--     y documentos de la inscripción. Si la cédula ya estuvo en APL (INACTIVO) se reactiva como
--     REINGRESO (el trigger del perfil crea la vinculación en el historial).
--
-- Seguridad del link público (rol anon):
--   * No lee NADA. aspirante_inscribir valida y guarda, y devuelve un TOKEN de subida (uuid, 3 horas).
--   * Los archivos solo se pueden subir a  aspirantes/inscripciones/<token>/<tipo>/<archivo>  con un
--     token vigente, máximo 15 archivos por inscripción, 10 MB c/u, solo imágenes y PDF.
--   * aspirante_adjuntar registra en la inscripción los archivos que de verdad existen en Storage.
--   * Límites: 3 inscripciones por cédula al día y 150 por hora en total.

-- ---- 1) Aspirantes ----
create table if not exists public.aspirantes (
  id                      bigint generated always as identity primary key,
  cedula                  text not null,
  nombre                  text not null,
  fecha_nacimiento        date,
  celular                 text,
  correo                  text,
  ciudad                  text,
  categoria_licencia      text,
  licencia_vencimiento    date,
  experiencia_anios       smallint check (experiencia_anios between 0 and 60),
  -- Todo lo que llenó en el formulario. Las llaves que existen en perfilsociodemografico usan el
  -- MISMO nombre de columna (así "Contratar" las copia al perfil sin volver a digitar).
  datos                   jsonb not null default '{}'::jsonb,
  -- Documentos: {tipo: [{path, nombre, en, por}]} en el bucket privado `aspirantes`
  adjuntos                jsonb not null default '{}'::jsonb,
  etapa                   text not null default 'DOCUMENTOS'
                          check (etapa in ('DOCUMENTOS','ENTREVISTA','MANEJO','MEDICOS','POR_CONTRATAR','CONTRATADO','DESCARTADO')),
  etapa_desde             timestamptz not null default now(),
  -- Calificación de cada etapa: {ETAPA: {checks: {item: OK|NO|NA}, campos: {...}, observacion, resultado, por, en}}
  evaluaciones            jsonb not null default '{}'::jsonb,
  motivo_descarte         text,
  etapa_descarte          text,            -- en qué etapa se descartó (para reabrir ahí)
  visto                   boolean not null default false,  -- ya la abrieron (badge "nuevos")
  origen                  text not null default 'LINK',
  acepta_habeas           boolean not null default false,
  habeas_data_aceptado_en timestamptz,
  token_subida            uuid not null default gen_random_uuid() unique,
  token_vence             timestamptz not null default now() + interval '3 hours',
  perfil_id               bigint references public.perfilsociodemografico(id) on delete set null,
  contratado_en           timestamptz,
  creado_en               timestamptz not null default now(),
  actualizado_en          timestamptz not null default now(),
  actualizado_por         text
);
create index if not exists aspirantes_etapa_idx  on public.aspirantes (etapa, creado_en desc);
create index if not exists aspirantes_cedula_idx on public.aspirantes (cedula, creado_en desc);

-- ---- 2) Historial del proceso (quién movió a quién, cuándo y por qué) ----
create table if not exists public.aspirante_historial (
  id           bigint generated always as identity primary key,
  aspirante_id bigint not null references public.aspirantes(id) on delete cascade,
  accion       text not null,   -- INSCRIPCION / APROBO / DESCARTO / REABRIO / CONTRATO
  de_etapa     text,
  a_etapa      text,
  detalle      text,
  por          text,
  en           timestamptz not null default now()
);
create index if not exists asp_hist_idx on public.aspirante_historial (aspirante_id, en);

-- ---- 3) Seguridad: SOLO TALENTO HUMANO (admin + gestión humana) ----
alter table public.aspirantes          enable row level security;
alter table public.aspirante_historial enable row level security;

drop policy if exists aspirantes_admin on public.aspirantes;
create policy aspirantes_admin on public.aspirantes
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));

-- El historial lo escriben solo los RPC; Talento humano lo lee.
drop policy if exists asp_hist_sel on public.aspirante_historial;
create policy asp_hist_sel on public.aspirante_historial
  for select to authenticated using ((select public.es_talento_humano()));

revoke all on public.aspirantes, public.aspirante_historial from anon;

-- ---- 4) Campos que acepta el formulario público ----
-- Del perfil: los de autogestión (sql/75) + licencia y referencia laboral.
create or replace function public.aspirante_campos_perfil()
returns text[] language sql immutable as $$
  select public.perfil_campos_autogestion() || array[
    'licencia_expedicion','restricciones_licencia',
    'ref_empresa','ref_cargo','ref_telefono_jefe','ref_fecha_ingreso','ref_fecha_retiro'
  ]::text[]
$$;
-- Propios del proceso de selección (no existen en el perfil; quedan en aspirantes.datos)
create or replace function public.aspirante_campos_extra()
returns text[] language sql immutable as $$
  select array[
    'experiencia_anios','vehiculos_conducidos','comparendos_pendientes','trabajo_antes_apl',
    'como_se_entero','referido_por','disponibilidad',
    'ref_nombre_jefe','ref_motivo_retiro',
    'refp_nombre','refp_telefono','refp_parentesco'
  ]::text[]
$$;
create or replace function public.aspirante_tipos_documento()
returns text[] language sql immutable as $$
  select array['hoja_vida','cedula','licencia','certificados','antecedentes','otros']::text[]
$$;

-- ---- 5) Trigger: normaliza, sella y protege el orden del proceso ----
create or replace function public.aspirante_antes_guardar()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  new.cedula := regexp_replace(coalesce(new.cedula, ''), '\D', '', 'g');
  if new.cedula = '' then raise exception 'La cédula es obligatoria.'; end if;
  new.nombre := upper(btrim(regexp_replace(coalesce(new.nombre, ''), '\s+', ' ', 'g')));
  new.actualizado_en := now();
  new.actualizado_por := coalesce(nullif(auth.jwt() ->> 'email', ''), new.actualizado_por);
  if tg_op = 'INSERT' then
    -- toda inscripción arranca en la etapa 1 (el orden lo llevan los RPC)
    new.etapa := 'DOCUMENTOS'; new.etapa_desde := now(); new.evaluaciones := '{}'::jsonb;
    new.perfil_id := null; new.contratado_en := null; new.motivo_descarte := null; new.etapa_descarte := null;
  elsif new.etapa is distinct from old.etapa then
    -- la etapa solo cambia con los botones del proceso (dejan historial)
    if coalesce(current_setting('app.aspirante_rpc', true), '') <> 'on' then
      raise exception 'La etapa se cambia con los botones del proceso (Aprobar / Descartar / Reabrir / Contratar).';
    end if;
    new.etapa_desde := now();
  end if;
  return new;
end $$;

drop trigger if exists aspirante_antes_guardar_trg on public.aspirantes;
create trigger aspirante_antes_guardar_trg
  before insert or update on public.aspirantes
  for each row execute function public.aspirante_antes_guardar();

-- ---- 6) LINK PÚBLICO: inscripción (no lee nada) ----
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
  v_json   jsonb := '{}'::jsonb;
  k        text;
  v        jsonb;
  v_txt    text;
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

  -- Solo campos permitidos, como texto, recortados y con tope de largo
  for k, v in select key, value from jsonb_each(p_datos) loop
    continue when not (k = any (v_perfil) or k = any (v_extra));
    continue when jsonb_typeof(v) not in ('string', 'number');
    v_txt := btrim(v #>> '{}');
    continue when v_txt = '';
    if length(v_txt) > 300 then raise exception 'El campo % es demasiado largo.', k; end if;
    v_json := v_json || jsonb_build_object(k, v_txt);
  end loop;

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

-- ¿Se puede subir un archivo a la carpeta de este token? (lo usa la política de Storage)
create or replace function public.aspirante_token_ok(p_token text)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  if not exists (select 1 from aspirantes where token_subida = p_token::uuid and token_vence > now()) then return false; end if;
  return (select count(1) from storage.objects
           where bucket_id = 'aspirantes' and name like 'inscripciones/' || p_token || '/%') < 15;
end $$;
revoke all on function public.aspirante_token_ok(text) from public;
grant execute on function public.aspirante_token_ok(text) to anon, authenticated;

-- Registra en la inscripción los archivos subidos (solo los que existen de verdad en Storage)
create or replace function public.aspirante_adjuntar(p_token uuid, p_archivos jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a      public.aspirantes;
  f      jsonb;
  v_path text;
  v_tipo text;
  v_n    int := 0;
  v_adj  jsonb;
begin
  select * into a from aspirantes where token_subida = p_token and token_vence > now() for update;
  if a.id is null then
    raise exception 'El tiempo para subir documentos terminó. Comunícate con Gestión Humana.';
  end if;
  if p_archivos is null or jsonb_typeof(p_archivos) <> 'array' or jsonb_array_length(p_archivos) > 15 then
    raise exception 'Archivos no válidos.';
  end if;
  v_adj := a.adjuntos;
  for f in select value from jsonb_array_elements(p_archivos) loop
    v_tipo := f ->> 'tipo';
    v_path := f ->> 'path';
    if v_tipo is null or not (v_tipo = any (public.aspirante_tipos_documento())) then
      raise exception 'Tipo de documento no válido.';
    end if;
    if v_path is null or position(('inscripciones/' || p_token::text || '/' || v_tipo || '/') in v_path) <> 1 then
      raise exception 'Ruta de archivo no válida.';
    end if;
    if not exists (select 1 from storage.objects where bucket_id = 'aspirantes' and name = v_path) then
      raise exception 'Un archivo no terminó de subir. Intenta de nuevo.';
    end if;
    continue when exists (select 1 from jsonb_array_elements(coalesce(v_adj -> v_tipo, '[]'::jsonb)) x where x ->> 'path' = v_path);
    v_adj := v_adj || jsonb_build_object(v_tipo, coalesce(v_adj -> v_tipo, '[]'::jsonb) || jsonb_build_array(
      jsonb_build_object('path', v_path, 'nombre', left(coalesce(f ->> 'nombre', ''), 160), 'en', now(), 'por', 'aspirante')));
    v_n := v_n + 1;
  end loop;
  update aspirantes set adjuntos = v_adj where id = a.id;
  return jsonb_build_object('ok', true, 'n', v_n);
end $$;
revoke all on function public.aspirante_adjuntar(uuid, jsonb) from public;
grant execute on function public.aspirante_adjuntar(uuid, jsonb) to anon, authenticated;

-- ---- 7) Bucket privado de documentos de aspirantes ----
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('aspirantes', 'aspirantes', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- El aspirante (anon) solo puede CREAR archivos en la carpeta de su token vigente. No lee, no borra, no reemplaza.
drop policy if exists asp_docs_anon_ins on storage.objects;
create policy asp_docs_anon_ins on storage.objects for insert to anon
  with check (bucket_id = 'aspirantes'
              and name ~ '^inscripciones/[0-9a-f-]{36}/[a-z_]+/[^/]{1,180}$'
              and public.aspirante_token_ok(split_part(name, '/', 2)));
-- Talento humano (admin + gestión humana): todo en el bucket (ver, subir resultados, borrar)
drop policy if exists asp_docs_admin_sel on storage.objects;
create policy asp_docs_admin_sel on storage.objects for select to authenticated
  using (bucket_id = 'aspirantes' and public.es_talento_humano());
drop policy if exists asp_docs_admin_ins on storage.objects;
create policy asp_docs_admin_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'aspirantes' and public.es_talento_humano());
drop policy if exists asp_docs_admin_upd on storage.objects;
create policy asp_docs_admin_upd on storage.objects for update to authenticated
  using (bucket_id = 'aspirantes' and public.es_talento_humano());
drop policy if exists asp_docs_admin_del on storage.objects;
create policy asp_docs_admin_del on storage.objects for delete to authenticated
  using (bucket_id = 'aspirantes' and public.es_talento_humano());

-- ---- 8) ADMIN: guardar el avance de la etapa actual (sin decidir) ----
create or replace function public.aspirante_guardar_evaluacion(p_id bigint, p_evaluacion jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a       public.aspirantes;
  v_email text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin');
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana gestiona el proceso de aspirantes.'; end if;
  select * into a from aspirantes where id = p_id for update;
  if a.id is null then raise exception 'El aspirante no existe.'; end if;
  if a.etapa not in ('DOCUMENTOS','ENTREVISTA','MANEJO','MEDICOS') then
    raise exception 'El aspirante está en %: no hay etapa para calificar.', a.etapa;
  end if;
  if p_evaluacion is null or jsonb_typeof(p_evaluacion) <> 'object' then raise exception 'Evaluación no válida.'; end if;
  update aspirantes
     set evaluaciones = evaluaciones || jsonb_build_object(a.etapa,
           coalesce(evaluaciones -> a.etapa, '{}'::jsonb) || (p_evaluacion - 'resultado' - 'por' - 'en')
           || jsonb_build_object('guardado_por', v_email, 'guardado_en', now())),
         visto = true
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ---- 9) ADMIN: aprobar la etapa (pasa a la siguiente) o descartar (con motivo) ----
create or replace function public.aspirante_decidir(
  p_id bigint, p_aprobar boolean, p_evaluacion jsonb default null, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a       public.aspirantes;
  v_email text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin');
  v_orden text[] := array['DOCUMENTOS','ENTREVISTA','MANEJO','MEDICOS','POR_CONTRATAR'];
  v_sig   text;
  v_ev    jsonb;
  v_apr   boolean := coalesce(p_aprobar, false);
  v_mot   text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana gestiona el proceso de aspirantes.'; end if;
  select * into a from aspirantes where id = p_id for update;
  if a.id is null then raise exception 'El aspirante no existe.'; end if;

  if v_apr then
    if a.etapa not in ('DOCUMENTOS','ENTREVISTA','MANEJO','MEDICOS') then
      raise exception 'El aspirante está en %: no hay etapa para aprobar.', a.etapa;
    end if;
    v_sig := v_orden[array_position(v_orden, a.etapa) + 1];
  else
    if a.etapa not in ('DOCUMENTOS','ENTREVISTA','MANEJO','MEDICOS','POR_CONTRATAR') then
      raise exception 'El aspirante está en %: no se puede descartar.', a.etapa;
    end if;
    if v_mot is null then raise exception 'Escribe el motivo del descarte.'; end if;
    v_sig := 'DESCARTADO';
  end if;

  v_ev := coalesce(a.evaluaciones -> a.etapa, '{}'::jsonb)
          || coalesce(case when jsonb_typeof(p_evaluacion) = 'object' then p_evaluacion - 'resultado' - 'por' - 'en' end, '{}'::jsonb)
          || jsonb_build_object('resultado', case when v_apr then 'APROBADO' else 'NO APROBADO' end, 'por', v_email, 'en', now());

  perform set_config('app.aspirante_rpc', 'on', true);
  update aspirantes
     set etapa = v_sig,
         evaluaciones = evaluaciones || jsonb_build_object(a.etapa, v_ev),
         motivo_descarte = case when v_apr then null else v_mot end,
         etapa_descarte  = case when v_apr then null else a.etapa end,
         visto = true
   where id = p_id;
  perform set_config('app.aspirante_rpc', 'off', true);

  insert into aspirante_historial (aspirante_id, accion, de_etapa, a_etapa, detalle, por)
  values (p_id, case when v_apr then 'APROBO' else 'DESCARTO' end, a.etapa, v_sig,
          case when v_apr then nullif(btrim(coalesce(p_evaluacion ->> 'observacion', '')), '') else v_mot end, v_email);
  return jsonb_build_object('ok', true, 'etapa', v_sig);
end $$;

-- ---- 10) ADMIN: reabrir un descartado (vuelve a la etapa donde se descartó) ----
create or replace function public.aspirante_reabrir(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a       public.aspirantes;
  v_email text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin');
  v_sig   text;
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana gestiona el proceso de aspirantes.'; end if;
  select * into a from aspirantes where id = p_id for update;
  if a.id is null then raise exception 'El aspirante no existe.'; end if;
  if a.etapa <> 'DESCARTADO' then raise exception 'Solo se reabre un aspirante DESCARTADO.'; end if;
  v_sig := coalesce(a.etapa_descarte, 'DOCUMENTOS');

  perform set_config('app.aspirante_rpc', 'on', true);
  update aspirantes
     set etapa = v_sig, motivo_descarte = null, etapa_descarte = null,
         evaluaciones = case when evaluaciones ? v_sig
                             then evaluaciones || jsonb_build_object(v_sig, (evaluaciones -> v_sig) - 'resultado' - 'por' - 'en')
                             else evaluaciones end
   where id = p_id;
  perform set_config('app.aspirante_rpc', 'off', true);

  insert into aspirante_historial (aspirante_id, accion, de_etapa, a_etapa, detalle, por)
  values (p_id, 'REABRIO', 'DESCARTADO', v_sig, 'Descartado antes por: ' || coalesce(a.motivo_descarte, '—'), v_email);
  return jsonb_build_object('ok', true, 'etapa', v_sig);
end $$;

-- ---- 11) ADMIN: CONTRATAR → crea o reactiva la persona en el Perfil sociodemográfico ----
create or replace function public.aspirante_contratar(
  p_id bigint, p_fecha_ingreso date, p_cargo text default null, p_tipo_contrato text default null,
  p_salario numeric default null, p_area text default null, p_codigo text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a       public.aspirantes;
  cur     public.perfilsociodemografico;
  v_email text := coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin');
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  v_json  jsonb;
  v_cols  text;
  v_pid   bigint;
  v_reing boolean := false;
  v_docs  jsonb;
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana gestiona el proceso de aspirantes.'; end if;
  select * into a from aspirantes where id = p_id for update;
  if a.id is null then raise exception 'El aspirante no existe.'; end if;
  if a.etapa <> 'POR_CONTRATAR' then
    raise exception 'Solo se contrata a quien aprobó las 4 etapas (está en %).', a.etapa;
  end if;
  if p_fecha_ingreso is null then raise exception 'Indica la fecha de ingreso.'; end if;
  if p_fecha_ingreso > v_hoy + 90 or p_fecha_ingreso < v_hoy - 90 then
    raise exception 'Revisa la fecha de ingreso.';
  end if;
  if p_salario is not null and p_salario < 0 then raise exception 'El salario no es válido.'; end if;

  -- Datos del perfil que trajo la inscripción + los del contrato
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_json
    from jsonb_each(a.datos) where key = any (public.aspirante_campos_perfil());
  v_json := v_json || jsonb_strip_nulls(jsonb_build_object(
    'cedula', a.cedula, 'nombre', a.nombre, 'fecha_nacimiento', a.fecha_nacimiento,
    'celular', a.celular, 'correo', a.correo,
    'categoria_licencia', a.categoria_licencia, 'licencia_vencimiento', a.licencia_vencimiento,
    'tipo', 'CONDUCTOR', 'estado', 'ACTIVO', 'fecha_ingreso', p_fecha_ingreso,
    'cargo', coalesce(nullif(upper(btrim(p_cargo)), ''), 'CONDUCTOR'),
    'tipo_contrato', nullif(upper(btrim(p_tipo_contrato)), ''),
    'salario', p_salario,
    'area', coalesce(nullif(upper(btrim(p_area)), ''), 'OPERATIVA'),
    'codigo', nullif(btrim(p_codigo), ''),
    'habeas_data_aceptado_en', a.habeas_data_aceptado_en));
  -- Documentos de la inscripción (bucket `aspirantes`) quedan referenciados en la ficha
  v_docs := jsonb_build_object('aspirante_' || a.id,
    jsonb_build_object('bucket', 'aspirantes', 'inscrito_en', a.creado_en, 'archivos', a.adjuntos));

  select * into cur from perfilsociodemografico where cedula = a.cedula for update;
  if cur.id is not null then
    if cur.estado = 'ACTIVO' then
      raise exception 'La cédula % ya está ACTIVA en el Perfil sociodemográfico (%).', a.cedula, cur.tipo;
    end if;
    if cur.fecha_ingreso is not null and p_fecha_ingreso <= cur.fecha_ingreso then
      raise exception 'Ya trabajó en APL: la fecha de ingreso debe ser posterior a su ingreso anterior (%).',
        to_char(cur.fecha_ingreso, 'DD/MM/YYYY');
    end if;
    v_reing := true;
    v_json := v_json || jsonb_build_object('tipo_ingreso', 'REINGRESO', 'fecha_retiro', null, 'novedad_retiro', null,
                                           'adjuntos', cur.adjuntos || v_docs);
  else
    v_json := v_json || jsonb_build_object('tipo_ingreso', 'NUEVO', 'origen', 'ASPIRANTES', 'adjuntos', v_docs);
  end if;

  -- Solo columnas reales y escribibles del perfil (las llaves propias del proceso se quedan en aspirantes)
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position) into v_cols
    from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'perfilsociodemografico'
     and c.is_generated = 'NEVER' and c.is_identity = 'NO'
     and v_json ? c.column_name;

  if v_reing then
    -- El trigger del perfil ve INACTIVO → ACTIVO con ingreso posterior y crea la vinculación REINGRESO
    execute format('update public.perfilsociodemografico set (%s) = (select %s from jsonb_populate_record(null::public.perfilsociodemografico, $1)) where id = $2',
                   v_cols, v_cols) using v_json, cur.id;
    v_pid := cur.id;
  else
    -- El trigger del perfil crea la vinculación NUEVO
    execute format('insert into public.perfilsociodemografico (%s) select %s from jsonb_populate_record(null::public.perfilsociodemografico, $1) returning id',
                   v_cols, v_cols) into v_pid using v_json;
  end if;

  perform set_config('app.aspirante_rpc', 'on', true);
  update aspirantes set etapa = 'CONTRATADO', perfil_id = v_pid, contratado_en = now(), visto = true where id = p_id;
  perform set_config('app.aspirante_rpc', 'off', true);

  insert into aspirante_historial (aspirante_id, accion, de_etapa, a_etapa, detalle, por)
  values (p_id, 'CONTRATO', 'POR_CONTRATAR', 'CONTRATADO',
          case when v_reing then 'REINGRESO' else 'NUEVO' end || ' · ingreso ' || to_char(p_fecha_ingreso, 'DD/MM/YYYY'), v_email);
  return jsonb_build_object('ok', true, 'perfil_id', v_pid, 'reingreso', v_reing);
end $$;

-- ---- 12) Permisos de ejecución ----
-- Supabase concede EXECUTE a anon por defecto en funciones nuevas: se quita explícitamente.
revoke all on function public.aspirante_guardar_evaluacion(bigint, jsonb) from public, anon;
revoke all on function public.aspirante_decidir(bigint, boolean, jsonb, text) from public, anon;
revoke all on function public.aspirante_reabrir(bigint) from public, anon;
revoke all on function public.aspirante_contratar(bigint, date, text, text, numeric, text, text) from public, anon;
grant execute on function public.aspirante_guardar_evaluacion(bigint, jsonb) to authenticated;
grant execute on function public.aspirante_decidir(bigint, boolean, jsonb, text) to authenticated;
grant execute on function public.aspirante_reabrir(bigint) to authenticated;
grant execute on function public.aspirante_contratar(bigint, date, text, text, numeric, text, text) to authenticated;
revoke execute on function public.aspirante_antes_guardar() from public, anon, authenticated;
