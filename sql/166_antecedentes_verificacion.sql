-- ============================================================================================
-- 166) Verificación de antecedentes obligatoria en cada ingreso
--      (hoja de vida FO-GH-03, sección 7 "Espacio exclusivo del empleador", sql/150)
--
-- PEDIDO (05/11/2026): "cuando una persona ingresa a la compañía se tiene que integrar un proceso
-- de verificación de antecedentes, verificado por la auxiliar de Gestión Humana; el proceso es
-- relativo y conlleva a que se incluya la investigación de manera obligatoria: fecha, documento
-- y observaciones si lo necesita".
--
-- CÓMO QUEDA:
--   * Por cada entidad (Procuraduría, Contraloría, Policía y, en cargos de conducción, SIMIT)
--     se exige resultado, fecha de verificación y el DOCUMENTO de la consulta. La observación es
--     opcional. El resultado es "relativo": tener antecedentes no bloquea, la investigación sí.
--   * Los documentos van al bucket privado `antecedentes` (v/<vinculación>/<entidad>-<n>.<ext>);
--     el espacio del empleador guarda la referencia (<entidad>_doc).
--   * La auxiliar FIRMA la verificación (quién, cuándo). Solo cuentas de Gestión Humana firman;
--     administración la ve. Si después cambia un resultado, una fecha o un documento, la firma
--     se cae y hay que volver a firmar.
--   * Decisión del usuario: obligatoria para los ingresos desde el 01/11/2026. En esos ingresos
--     el estado del proceso no puede quedar APROBADO sin la verificación firmada, y los que
--     están activos sin ella salen como pendientes (antecedentes_pendientes).
--   * Espejo en config.js: ANTECEDENTES_DESDE y antecedentesFaltan. Si cambia uno, cambia el otro.
-- ============================================================================================

-- 1) Desde qué ingreso es obligatoria --------------------------------------------------------------
create or replace function public._antec_desde()
returns date language sql immutable
as $$ select date '2026-11-01' $$;

-- SIMIT solo para cargos de conducción (lo dice el formato: "aplica para cargos de conducción").
create or replace function public._antec_conductor(p_tipo text, p_cargo text)
returns boolean language sql immutable
as $$ select coalesce(p_tipo, '') = 'CONDUCTOR' or coalesce(p_cargo, '') ~* 'conduct' $$;

-- Qué falta para poder firmar: "Procuraduría: documento", "SIMIT: fecha"…
create or replace function public._antec_faltan(p_sel jsonb, p_conductor boolean)
returns text[] language sql immutable
as $$
  select coalesce(array_agg(e.l || ': ' || c.l order by e.o, c.o), '{}')
    from (values (1, 'procuraduria', 'Procuraduría'), (2, 'contraloria', 'Contraloría'),
                 (3, 'policia', 'Policía'), (4, 'simit', 'SIMIT')) e(o, k, l)
   cross join (values (1, '_resultado', 'resultado'), (2, '_fecha', 'fecha'), (3, '_doc', 'documento')) c(o, s, l)
   where (e.k <> 'simit' or p_conductor)
     and case when c.s = '_doc' then jsonb_typeof(coalesce(p_sel, '{}'::jsonb) -> (e.k || '_doc')) is distinct from 'object'
              else nullif(btrim(coalesce(p_sel ->> (e.k || c.s), '')), '') is null end;
$$;

-- Lo que se firmó: si cambia, la firma ya no vale.
create or replace function public._antec_huella(p_sel jsonb)
returns text language sql immutable
as $$
  select string_agg(coalesce(p_sel ->> (k || '_resultado'), '') || '|' || coalesce(p_sel ->> (k || '_fecha'), '')
                    || '|' || coalesce(p_sel -> (k || '_doc') ->> 'path', ''), ';' order by k)
    from unnest(array['contraloria', 'policia', 'procuraduria', 'simit']) k;
$$;
revoke all on function public._antec_desde() from public, anon, authenticated;
revoke all on function public._antec_conductor(text, text) from public, anon, authenticated;
revoke all on function public._antec_faltan(jsonb, boolean) from public, anon, authenticated;
revoke all on function public._antec_huella(jsonb) from public, anon, authenticated;

-- 2) Los documentos de la consulta: bucket privado, solo Talento humano. No se borran ni se
--    reemplazan en sitio: cada documento nuevo es un archivo nuevo y queda el rastro.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('antecedentes', 'antecedentes', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists antec_docs_sel on storage.objects;
create policy antec_docs_sel on storage.objects for select to authenticated
  using (bucket_id = 'antecedentes' and (select public.es_talento_humano()));
drop policy if exists antec_docs_ins on storage.objects;
create policy antec_docs_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'antecedentes' and (select public.es_talento_humano())
              and name ~ '^v/[0-9]+/(procuraduria|contraloria|policia|simit)-[0-9]+\.(pdf|jpg|png|webp)$');

-- 3) Registrar el documento de una entidad (después de subirlo al bucket) ---------------------------
create or replace function public.perfil_antecedente_doc(
  p_vinculacion bigint, p_entidad text, p_path text, p_nombre text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_ant jsonb; v_json jsonb; v_quitada boolean;
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana adjunta los antecedentes.'; end if;
  if p_entidad not in ('procuraduria', 'contraloria', 'policia', 'simit') then raise exception 'Entidad no válida.'; end if;
  if coalesce(p_path, '') !~ ('^v/' || p_vinculacion || '/' || p_entidad || '-[0-9]+\.(pdf|jpg|png|webp)$') then
    raise exception 'Ruta del documento no válida.';
  end if;
  if not exists (select 1 from storage.objects where bucket_id = 'antecedentes' and name = p_path) then
    raise exception 'El documento no se subió. Intenta de nuevo.';
  end if;
  select seleccion into v_ant from perfil_vinculaciones where id = p_vinculacion for update;
  if v_ant is null then raise exception 'La vinculación no existe.'; end if;

  v_quitada := v_ant ? 'antecedentes_verificado_en';
  v_json := (v_ant - 'antecedentes_verificado_por' - 'antecedentes_verificado_nombre' - 'antecedentes_verificado_en')
    || jsonb_build_object(p_entidad || '_doc', jsonb_build_object(
         'path', p_path, 'nombre', left(coalesce(nullif(btrim(p_nombre), ''), 'documento'), 120),
         'por', coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'), 'en', now()));
  update perfil_vinculaciones set seleccion = v_json where id = p_vinculacion;
  return jsonb_build_object('ok', true, 'seleccion', v_json, 'verificacion_quitada', v_quitada);
end $$;
revoke all on function public.perfil_antecedente_doc(bigint, text, text, text) from public, anon;
grant execute on function public.perfil_antecedente_doc(bigint, text, text, text) to authenticated;

-- 4) Guardar la sección 7: igual que sql/150, más los documentos, la firma y la regla obligatoria ----
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
  v_vin  record;
  k      text;
  v      jsonb;
  v_txt  text;
  v_f    date;
  v_hoy  date := (now() at time zone 'America/Bogota')::date;
  v_quiere boolean := coalesce(p_datos ->> 'antecedentes_verificado', '') in ('true', 'SI');
  v_quitada boolean := false;
  v_falta text[];
begin
  if not public.es_talento_humano() then raise exception 'Solo Gestión Humana llena el espacio del empleador.'; end if;
  if p_datos is null or jsonb_typeof(p_datos) <> 'object' then raise exception 'Datos no válidos.'; end if;
  select id, seleccion, fecha_ingreso, tipo, cargo into v_vin from perfil_vinculaciones where id = p_vinculacion for update;
  if v_vin.id is null then raise exception 'La vinculación no existe.'; end if;
  v_ant := v_vin.seleccion;

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
      if k in ('procuraduria_fecha', 'contraloria_fecha', 'policia_fecha', 'simit_fecha') and v_f > v_hoy then
        raise exception 'La fecha de verificación de antecedentes no puede ser futura.';
      end if;
      v_txt := v_f::text;
    end if;
    v_json := v_json || jsonb_build_object(k, v_txt);
  end loop;
  if (v_json ->> 'estado') is not null and (v_json ->> 'estado') not in ('APROBADO', 'NO APROBADO') then
    raise exception 'El estado del proceso es APROBADO o NO APROBADO.';
  end if;

  -- Los documentos no vienen en el formulario: se conservan los que ya estaban.
  foreach k in array array['procuraduria', 'contraloria', 'policia', 'simit'] loop
    if jsonb_typeof(v_ant -> (k || '_doc')) = 'object' then
      v_json := v_json || jsonb_build_object(k || '_doc', v_ant -> (k || '_doc'));
    end if;
  end loop;

  -- La firma de Gestión Humana
  if v_quiere and v_ant ? 'antecedentes_verificado_en'
     and public._antec_huella(v_json) = public._antec_huella(v_ant) then
    -- Nada de lo firmado cambió: la firma se queda como estaba.
    v_json := v_json || jsonb_build_object(
      'antecedentes_verificado_por', v_ant -> 'antecedentes_verificado_por',
      'antecedentes_verificado_nombre', v_ant -> 'antecedentes_verificado_nombre',
      'antecedentes_verificado_en', v_ant -> 'antecedentes_verificado_en');
  elsif v_quiere and public.es_gestion_humana() then
    v_falta := public._antec_faltan(v_json, public._antec_conductor(v_vin.tipo, v_vin.cargo));
    if cardinality(v_falta) > 0 then
      raise exception 'Para firmar la verificación de antecedentes falta: %.', array_to_string(v_falta, ', ');
    end if;
    v_json := v_json || jsonb_build_object(
      'antecedentes_verificado_por', coalesce(nullif(auth.jwt() ->> 'email', ''), ''),
      'antecedentes_verificado_nombre', (select nombre from perfiles where id = auth.uid()),
      'antecedentes_verificado_en', now());
  elsif v_quiere and not (v_ant ? 'antecedentes_verificado_en') then
    raise exception 'La verificación de antecedentes la firma Gestión Humana.';
  else
    -- Se desmarcó, o administración cambió algo de lo firmado: la firma se cae.
    v_quitada := v_ant ? 'antecedentes_verificado_en';
  end if;

  -- Obligatoria desde _antec_desde(): sin la firma, el ingreso no se aprueba.
  if v_vin.fecha_ingreso >= public._antec_desde() and (v_json ->> 'estado') = 'APROBADO'
     and not (v_json ? 'antecedentes_verificado_en') then
    raise exception 'Para aprobar este ingreso falta la verificación de antecedentes firmada por Gestión Humana.';
  end if;

  v_json := v_json || jsonb_strip_nulls(jsonb_build_object('aspirante_id', v_ant -> 'aspirante_id'))
                   || jsonb_build_object('por', coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'), 'en', now());
  update perfil_vinculaciones set seleccion = v_json where id = p_vinculacion;
  return jsonb_build_object('ok', true, 'seleccion', v_json, 'verificacion_quitada', v_quitada);
end $$;
revoke all on function public.perfil_seleccion_guardar(bigint, jsonb) from public, anon;
grant execute on function public.perfil_seleccion_guardar(bigint, jsonb) to authenticated;

-- 5) Los ingresos activos que deben la verificación ------------------------------------------------
create or replace function public.antecedentes_pendientes()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object('ok', true, 'desde', public._antec_desde(), 'es_gh', public.es_gestion_humana(),
      'pendientes', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'nombre', p.nombre, 'cedula', v.cedula, 'cargo_perfil', p.cargo,
                 'vinculacion', jsonb_build_object('id', v.id, 'cedula', v.cedula, 'fecha_ingreso', v.fecha_ingreso,
                   'fecha_retiro', v.fecha_retiro, 'tipo', v.tipo, 'cargo', v.cargo, 'seleccion', v.seleccion),
                 'faltan', to_jsonb(public._antec_faltan(v.seleccion, public._antec_conductor(v.tipo, v.cargo))))
               order by v.fecha_ingreso desc, p.nombre)
          from perfil_vinculaciones v
          join perfilsociodemografico p on p.cedula = v.cedula
         where v.fecha_ingreso >= public._antec_desde()
           and v.fecha_retiro is null
           and not (v.seleccion ? 'antecedentes_verificado_en')), '[]'::jsonb))
  end;
$$;
revoke all on function public.antecedentes_pendientes() from public, anon;
grant execute on function public.antecedentes_pendientes() to authenticated;
