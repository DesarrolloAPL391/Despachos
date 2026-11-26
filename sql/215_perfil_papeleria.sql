-- 215: 📁 PAPELERÍA del empleado en el perfil sociodemográfico (y 📷 la foto la sube Talento humano).
--
-- Pedido (26/11/2026): "al perfil sociodemográfico en la parte de los empleados toca ponerle un
-- espacio para ingresar la foto que es el distintivo de los empleados y espacios para la papelería
-- que monten un documento y lo nombren para evitar problemas".
--
--   * La FOTO ya tiene su tabla (perfil_fotos, sql/151) y Talento humano ya puede escribirla (RLS
--     "for all"): no necesita SQL. La ficha la sube con origen 'FICHA'.
--   * Cada DOCUMENTO va al bucket privado `perfil-docs` con una ruta SIN datos de la persona
--     (d/<uuid>.<ext>) y se registra en perfil_documentos con su TIPO y el NOMBRE que le pone quien
--     lo sube. El nombre es obligatorio, no puede ser el que le puso la cámara o el escáner
--     (IMG_2025…, documento.pdf) y no se repite en la misma persona: así no hay dos "Contrato" y nadie
--     tiene que abrir cinco PDF para encontrar uno. Al descargarlo, el archivo sale con ese nombre.
--   * Nada se borra: "Quitar" pide el motivo y deja el rastro (el archivo sigue en el bucket).
--   * Solo Talento humano (admin + Gestión Humana) ve, sube, renombra y quita. anon, nada.
--   * Se escribe SOLO por las funciones (quién y cuándo los pone el servidor); la tabla solo se lee.

set lock_timeout = '8s';

-- ---- 1) Tabla ----
create table if not exists public.perfil_documentos (
  id             bigint generated always as identity primary key,
  cedula         text not null references public.perfilsociodemografico(cedula) on update cascade on delete cascade,
  tipo           text not null check (length(btrim(tipo)) between 2 and 60),
  nombre         text not null check (length(btrim(nombre)) between 4 and 120),
  fecha_doc      date,
  path           text not null unique,
  archivo        text,                -- nombre original del archivo (solo referencia)
  mime           text,
  tamano         bigint,
  subido_por     text,
  subido_nombre  text,
  subido_en      timestamptz not null default now(),
  editado_por    text,
  editado_en     timestamptz,
  quitado_por    text,
  quitado_en     timestamptz,
  quitado_motivo text
);
create index if not exists perfil_docs_ced_idx on public.perfil_documentos (cedula, subido_en desc);
-- El mismo nombre no se repite en la misma persona (los quitados no cuentan)
create unique index if not exists perfil_docs_nombre_uq
  on public.perfil_documentos (cedula, lower(btrim(nombre))) where quitado_en is null;

alter table public.perfil_documentos enable row level security;
drop policy if exists perfil_docs_th_sel on public.perfil_documentos;
create policy perfil_docs_th_sel on public.perfil_documentos
  for select to authenticated using ((select public.es_talento_humano()));
revoke all on public.perfil_documentos from public, anon, authenticated;
grant select on public.perfil_documentos to authenticated;

-- ---- 2) Bucket privado: PDF, fotos, Word y Excel, hasta 15 MB ----
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('perfil-docs', 'perfil-docs', false, 15728640,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Leer y subir: solo Talento humano. Ni actualizar ni borrar: cada archivo nuevo es un archivo nuevo.
drop policy if exists perfil_docs_obj_sel on storage.objects;
create policy perfil_docs_obj_sel on storage.objects for select to authenticated
  using (bucket_id = 'perfil-docs' and (select public.es_talento_humano()));
drop policy if exists perfil_docs_obj_ins on storage.objects;
create policy perfil_docs_obj_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'perfil-docs' and (select public.es_talento_humano())
              and name ~ '^d/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png|webp|docx|xlsx)$');

-- ---- 3) El nombre: obligatorio y que diga qué es ----
-- Espejo de pfDocNombreError (app.js): si cambia uno, cambiar el otro.
create or replace function public._perfil_doc_nombre(p text)
returns text language plpgsql immutable set search_path = public as $$
declare n text := regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g');
begin
  if length(n) < 4 then
    raise exception 'Ponle un nombre al documento (mínimo 4 letras): por ejemplo «Contrato a término fijo 2025».';
  end if;
  if length(n) > 120 then raise exception 'El nombre del documento es muy largo (máximo 120).'; end if;
  if n ~* '\.(pdf|jpe?g|png|webp|heic|docx?|xlsx?)$' then
    raise exception 'Eso parece el nombre del archivo: escribe qué documento es.';
  end if;
  if n ~* '^(img|dsc|dcim|pxl|photo|pic|foto|image|imagen|cam|camscanner|scan|scanned|escaneo|escaneado|whatsapp( (image|imagen|document|documento|video))?|wa|doc|document|documento|archivo|file|screenshot|captura( de pantalla)?)[ _-]*[0-9]' then
    raise exception 'Eso parece el nombre que le puso la cámara o el escáner: escribe qué documento es.';
  end if;
  if n !~ '[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]{3}' then raise exception 'Escribe qué documento es (con letras).'; end if;
  return n;
end $$;
revoke all on function public._perfil_doc_nombre(text) from public, anon, authenticated;

create or replace function public._perfil_doc_fecha_ok(p date)
returns boolean language sql stable set search_path = public as $$
  select p is null or (p >= date '1950-01-01' and p <= (now() at time zone 'America/Bogota')::date + 366);
$$;
revoke all on function public._perfil_doc_fecha_ok(date) from public, anon, authenticated;

-- ---- 4) Registrar un documento (después de subirlo al bucket) ----
create or replace function public.perfil_doc_registrar(
  p_cedula text, p_tipo text, p_nombre text, p_fecha date, p_path text,
  p_archivo text default null, p_mime text default null, p_tamano bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nombre text; v_meta jsonb; v_doc perfil_documentos;
begin
  if not public.es_talento_humano() then raise exception 'Solo Talento humano sube la papelería.'; end if;
  if not exists (select 1 from perfilsociodemografico where cedula = p_cedula) then
    raise exception 'La persona no está en el perfil sociodemográfico.';
  end if;
  if length(btrim(coalesce(p_tipo, ''))) not between 2 and 60 then raise exception 'Elige el tipo de documento.'; end if;
  v_nombre := public._perfil_doc_nombre(p_nombre);
  if not public._perfil_doc_fecha_ok(p_fecha) then raise exception 'La fecha del documento no es válida.'; end if;
  if coalesce(p_path, '') !~ '^d/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(pdf|jpg|png|webp|docx|xlsx)$' then
    raise exception 'Ruta del documento no válida.';
  end if;
  select metadata into v_meta from storage.objects where bucket_id = 'perfil-docs' and name = p_path;
  if not found then raise exception 'El documento no se subió. Intenta de nuevo.'; end if;
  if exists (select 1 from perfil_documentos where path = p_path) then raise exception 'Ese archivo ya está registrado.'; end if;
  if exists (select 1 from perfil_documentos where cedula = p_cedula and quitado_en is null
             and lower(btrim(nombre)) = lower(v_nombre)) then
    raise exception 'Esta persona ya tiene un documento llamado «%»: ponle un nombre que los distinga (por ejemplo con la fecha o el año).', v_nombre;
  end if;
  insert into perfil_documentos (cedula, tipo, nombre, fecha_doc, path, archivo, mime, tamano, subido_por, subido_nombre)
  values (p_cedula, btrim(p_tipo), v_nombre, p_fecha, p_path, left(nullif(btrim(coalesce(p_archivo, '')), ''), 200),
          coalesce(v_meta ->> 'mimetype', p_mime),
          coalesce(nullif(v_meta ->> 'size', '')::bigint, p_tamano),
          coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'),
          (select nombre from perfiles where id = auth.uid()))
  returning * into v_doc;
  return jsonb_build_object('ok', true, 'doc', to_jsonb(v_doc));
end $$;

-- ---- 5) Cambiar el nombre, el tipo o la fecha (el archivo no se cambia: se sube otro) ----
create or replace function public.perfil_doc_editar(p_id bigint, p_tipo text, p_nombre text, p_fecha date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nombre text; v_doc perfil_documentos;
begin
  if not public.es_talento_humano() then raise exception 'Solo Talento humano cambia la papelería.'; end if;
  select * into v_doc from perfil_documentos where id = p_id for update;
  if not found then raise exception 'El documento no existe.'; end if;
  if v_doc.quitado_en is not null then raise exception 'Ese documento ya se quitó.'; end if;
  if length(btrim(coalesce(p_tipo, ''))) not between 2 and 60 then raise exception 'Elige el tipo de documento.'; end if;
  v_nombre := public._perfil_doc_nombre(p_nombre);
  if not public._perfil_doc_fecha_ok(p_fecha) then raise exception 'La fecha del documento no es válida.'; end if;
  if exists (select 1 from perfil_documentos where cedula = v_doc.cedula and id <> p_id and quitado_en is null
             and lower(btrim(nombre)) = lower(v_nombre)) then
    raise exception 'Esta persona ya tiene un documento llamado «%»: ponle un nombre que los distinga (por ejemplo con la fecha o el año).', v_nombre;
  end if;
  update perfil_documentos
     set tipo = btrim(p_tipo), nombre = v_nombre, fecha_doc = p_fecha,
         editado_por = coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'), editado_en = now()
   where id = p_id
  returning * into v_doc;
  return jsonb_build_object('ok', true, 'doc', to_jsonb(v_doc));
end $$;

-- ---- 6) Quitar (no se borra: queda con el motivo) ----
create or replace function public.perfil_doc_quitar(p_id bigint, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_doc perfil_documentos;
begin
  if not public.es_talento_humano() then raise exception 'Solo Talento humano quita documentos.'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 5 then raise exception 'Escribe por qué se quita (mínimo 5 letras).'; end if;
  update perfil_documentos
     set quitado_en = now(), quitado_por = coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'),
         quitado_motivo = left(btrim(p_motivo), 300)
   where id = p_id and quitado_en is null
  returning * into v_doc;
  if not found then raise exception 'El documento no existe o ya se quitó.'; end if;
  return jsonb_build_object('ok', true, 'doc', to_jsonb(v_doc));
end $$;

revoke all on function public.perfil_doc_registrar(text, text, text, date, text, text, text, bigint) from public, anon;
revoke all on function public.perfil_doc_editar(bigint, text, text, date) from public, anon;
revoke all on function public.perfil_doc_quitar(bigint, text) from public, anon;
grant execute on function public.perfil_doc_registrar(text, text, text, date, text, text, text, bigint) to authenticated;
grant execute on function public.perfil_doc_editar(bigint, text, text, date) to authenticated;
grant execute on function public.perfil_doc_quitar(bigint, text) to authenticated;
