-- ============================================================================================
-- 145 · CERTIFICADO LABORAL — enviarlo por WhatsApp
--
-- WhatsApp no deja adjuntar un archivo desde un enlace: `wa.me?text=…` manda texto y nada más.
-- Por eso el envío tiene dos caminos, y los dos terminan con el PDF en manos de la persona:
--   · desde el CELULAR, el navegador comparte el archivo al sistema y WhatsApp lo recibe
--     adjunto de verdad (no pasa por ningún servidor nuestro);
--   · desde el COMPUTADOR eso no existe, así que el PDF se guarda en un bucket privado y se
--     manda un enlace firmado que vence. El certificado lleva cédula y a veces el salario:
--     por eso el bucket es privado y el enlace tiene fecha de vencimiento, no es público.
--
-- Se aplica sobre sql/93 (certificado), sql/94 (firmantes) y sql/144 (formato 2026).
-- ============================================================================================

-- 1) Dónde se guarda el PDF ---------------------------------------------------------------------
-- Privado. Solo Talento Humano escribe y lee; el destinatario entra por el enlace firmado.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('certificados', 'certificados', false, 5242880, array['application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists cert_pdf_th on storage.objects;
create policy cert_pdf_th on storage.objects
  for all to authenticated
  using (bucket_id = 'certificados' and (select public.es_talento_humano()))
  with check (bucket_id = 'certificados' and (select public.es_talento_humano()));

-- 2) Qué se envió, a dónde y cuándo -------------------------------------------------------------
-- Un certificado laboral que sale de la empresa debe poder rastrearse: ya guardábamos quién lo
-- expidió; ahora también a qué número se mandó y si quedó archivado el PDF.
alter table public.certificados_expedidos
  add column if not exists archivo    text,         -- ruta dentro del bucket 'certificados'
  add column if not exists enviado_wa boolean not null default false,
  add column if not exists enviado_a  text,         -- número al que se mandó (null si se compartió)
  add column if not exists enviado_en timestamptz;

-- 3) El mensaje que acompaña al documento -------------------------------------------------------
-- Es una plantilla editable: el texto de la empresa no puede estar escrito en el código.
-- Marcas que se reemplazan: {nombre} {enlace} {dias} {telefono} {correo} {empresa}
alter table public.certificado_config
  add column if not exists wa_mensaje  text,
  add column if not exists wa_dias     int not null default 7
    check (wa_dias between 1 and 30);

comment on column public.certificado_config.wa_dias is
  'Dias que dura el enlace del PDF enviado por WhatsApp. Vencido, el enlace deja de abrir.';

-- 4) Registrar el envío --------------------------------------------------------------------------
-- No falla el envío por un problema de registro, pero sí deja constancia cuando se puede.
create or replace function public.certificado_envio_registrar(
  p_consecutivo text, p_archivo text default null, p_telefono text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), '')); v_n int;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para enviar certificados.');
  end if;
  update public.certificados_expedidos
     set archivo    = coalesce(nullif(trim(p_archivo), ''), archivo),
         enviado_wa = true,
         -- Se guardan solo los dígitos: el número llega de un campo que la gente escribe a mano.
         enviado_a  = coalesce(nullif(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), ''), enviado_a),
         enviado_en = now()
   where consecutivo = p_consecutivo;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'No existe ese certificado: ' || coalesce(p_consecutivo, ''));
  end if;
  return jsonb_build_object('ok', true, 'por', v_yo);
end $$;
revoke all on function public.certificado_envio_registrar(text, text, text) from public, anon;
grant execute on function public.certificado_envio_registrar(text, text, text) to authenticated;

-- 5) Leer y guardar: los dos campos nuevos -------------------------------------------------------
-- Se reescriben completas porque son las de sql/144 más `wa_mensaje` y `wa_dias`.
create or replace function public.certificado_config_leer()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with c as (select * from public.certificado_config where id = 1),
       g as (select * from public.certificado_firmantes where rol = 'GERENTE' and vigente_hasta is null),
       h as (select * from public.certificado_firmantes where rol = 'GESTION_HUMANA' and vigente_hasta is null)
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else (select jsonb_build_object(
      'ok', true,
      'empresa_nombre', c.empresa_nombre, 'empresa_nit', c.empresa_nit,
      'empresa_direccion', c.empresa_direccion, 'empresa_correo', c.empresa_correo,
      'empresa_web', c.empresa_web, 'empresa_whatsapp', c.empresa_whatsapp,
      'ciudad', c.ciudad, 'telefono', c.telefono, 'telefono_ext', c.telefono_ext,
      'correo_contacto', c.correo_contacto, 'suscrito_cargo', c.suscrito_cargo,
      'firma_rol', c.firma_rol,
      'wa_mensaje', c.wa_mensaje, 'wa_dias', c.wa_dias,
      'firmante1_nombre', coalesce((select nombre from g), c.firmante1_nombre),
      'firmante1_cargo',  coalesce((select cargo  from g), c.firmante1_cargo),
      'firmante1_firma',  coalesce((select firma  from g), c.firmante1_firma),
      'firmante1_alto',   coalesce((select firma_alto from g), 58),
      'firmante1_dx',     coalesce((select firma_dx from g), 0),
      'firmante1_dy',     coalesce((select firma_dy from g), 0),
      'firmante2_nombre', coalesce((select nombre from h), c.firmante2_nombre),
      'firmante2_cargo',  coalesce((select cargo  from h), c.firmante2_cargo),
      'firmante2_firma',  coalesce((select firma  from h), c.firmante2_firma),
      'firmante2_alto',   coalesce((select firma_alto from h), 58),
      'firmante2_dx',     coalesce((select firma_dx from h), 0),
      'firmante2_dy',     coalesce((select firma_dy from h), 0),
      'smmlv', c.smmlv, 'auxilio_transporte', c.auxilio_transporte, 'anio_valores', c.anio_valores,
      'nota_pie', c.nota_pie,
      'falta', (select coalesce(jsonb_agg(f), '[]'::jsonb) from (
                  select 'firmante1_nombre' as f
                   where c.firma_rol = 'GERENTE'
                     and coalesce((select nombre from g), c.firmante1_nombre, '') = ''
                  union all select 'firmante2_nombre'
                   where c.firma_rol = 'GESTION_HUMANA'
                     and coalesce((select nombre from h), c.firmante2_nombre, '') = ''
                  union all select 'suscrito_cargo'    where coalesce(c.suscrito_cargo, '') = ''
                  union all select 'telefono'          where coalesce(c.telefono, '') = ''
                  union all select 'correo_contacto'   where coalesce(c.correo_contacto, '') = ''
                  union all select 'empresa_direccion' where coalesce(c.empresa_direccion, '') = ''
                ) s))
      from c)
  end;
$$;
revoke all on function public.certificado_config_leer() from public, anon;
grant execute on function public.certificado_config_leer() to authenticated;

create or replace function public.certificado_config_guardar(p jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion cambia los datos del certificado.');
  end if;
  update public.certificado_config set
    ciudad             = coalesce(nullif(trim(p->>'ciudad'), ''), ciudad),
    telefono           = coalesce(nullif(trim(p->>'telefono'), ''), telefono),
    telefono_ext       = coalesce(nullif(trim(p->>'telefono_ext'), ''), telefono_ext),
    correo_contacto    = coalesce(nullif(trim(p->>'correo_contacto'), ''), correo_contacto),
    empresa_direccion  = coalesce(nullif(trim(p->>'empresa_direccion'), ''), empresa_direccion),
    empresa_correo     = coalesce(nullif(trim(p->>'empresa_correo'), ''), empresa_correo),
    empresa_web        = coalesce(nullif(trim(p->>'empresa_web'), ''), empresa_web),
    empresa_whatsapp   = coalesce(nullif(trim(p->>'empresa_whatsapp'), ''), empresa_whatsapp),
    suscrito_cargo     = coalesce(nullif(trim(p->>'suscrito_cargo'), ''), suscrito_cargo),
    firma_rol          = coalesce(nullif(trim(p->>'firma_rol'), ''), firma_rol),
    -- El mensaje sí se puede dejar en blanco a propósito (vuelve al texto por defecto de la app).
    wa_mensaje         = case when p ? 'wa_mensaje' then nullif(trim(p->>'wa_mensaje'), '') else wa_mensaje end,
    wa_dias            = coalesce((p->>'wa_dias')::int, wa_dias),
    firmante1_nombre   = coalesce(nullif(trim(p->>'firmante1_nombre'), ''), firmante1_nombre),
    firmante1_cargo    = coalesce(nullif(trim(p->>'firmante1_cargo'), ''), firmante1_cargo),
    firmante1_firma    = coalesce(nullif(trim(p->>'firmante1_firma'), ''), firmante1_firma),
    firmante2_nombre   = coalesce(nullif(trim(p->>'firmante2_nombre'), ''), firmante2_nombre),
    firmante2_cargo    = coalesce(nullif(trim(p->>'firmante2_cargo'), ''), firmante2_cargo),
    firmante2_firma    = coalesce(nullif(trim(p->>'firmante2_firma'), ''), firmante2_firma),
    smmlv              = coalesce((p->>'smmlv')::numeric, smmlv),
    auxilio_transporte = coalesce((p->>'auxilio_transporte')::numeric, auxilio_transporte),
    anio_valores       = coalesce((p->>'anio_valores')::int, anio_valores),
    nota_pie           = coalesce(p->>'nota_pie', nota_pie),
    actualizado_en     = now(), actualizado_por = v_yo
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.certificado_config_guardar(jsonb) from public, anon;
grant execute on function public.certificado_config_guardar(jsonb) to authenticated;
