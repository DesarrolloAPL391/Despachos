-- ============================================================================================
-- 167) Aprobación de ingresos: check list de requisitos + aprobaciones con casilla
--      (módulo de aprobados y rechazados). Va sobre sql/164 (bitácora) y sql/166 (antecedentes).
--
-- PEDIDO (05/11/2026): "las aprobaciones tienen que ser por medio de un check list y para eso
-- debemos crear un módulo de aprobados y rechazados".
-- DECISIONES DEL USUARIO:
--   * Las dos cosas: Gestión Humana chequea los REQUISITOS del ingreso y da su visto bueno; después
--     Gerencia, el afiliado y la Junta Directiva (si aplica) aprueban o rechazan con su casilla.
--   * El afiliado y la Junta autorizan por fuera (papel, WhatsApp, acta): Gestión Humana registra
--     su casilla en nombre de ellos, con la fecha de la autorización y, si lo tiene, el soporte.
--   * Aplica a los ingresos desde el 01/11/2026 (_antec_desde de sql/166).
--
-- CÓMO QUEDA (todo dentro de perfil_vinculaciones.seleccion, la sección 7 de la hoja de vida):
--   * apr_requisitos {clave: true}: lo que chequea Gestión Humana. Espejo de INGRESO_REQUISITOS en
--     config.js. La verificación de antecedentes no se chequea: sale de la firma de sql/166.
--   * apr_gh_*, apr_ger_*, apr_afi_*, apr_jun_*: estado (APROBADO/RECHAZADO), quién, nombre,
--     cuándo, nota y, para afiliado y Junta, la fecha de la autorización y el soporte.
--   * Orden lógico: el visto bueno de Gestión Humana exige los requisitos completos y los
--     antecedentes firmados; las demás instancias aprueban después de ese visto bueno. Si después
--     se desmarca un requisito o se cae la firma de antecedentes, el visto bueno se cae solo.
--   * Rechazar pide motivo. Una casilla se desmarca para corregir un error (PENDIENTE).
--   * El "Estado del proceso" (seleccion.estado) se CALCULA: APROBADO cuando aprueban todas las
--     instancias que aplican; NO APROBADO (rechazado) si alguna rechaza. Los campos de aprobación
--     del formato (aprob_gerencia, aprob_afiliado, aprob_junta y sus fechas) se llenan solos, así
--     el PDF de la hoja de vida sale completo.
--   * Cada decisión queda en aprobaciones_log (modulo INGRESOS).
-- ============================================================================================

-- 1) La bitácora de sql/164 recibe también los ingresos ----------------------------------------------
alter table public.aprobaciones_log drop constraint if exists aprobaciones_log_modulo_check;
alter table public.aprobaciones_log add constraint aprobaciones_log_modulo_check
  check (modulo in ('VACACIONES', 'PERMISOS', 'INGRESOS'));
-- (la política de lectura ya cubre a Talento humano y a Gerencia: es_permiso_ver)

-- 2) Reglas -------------------------------------------------------------------------------------------
-- Requisitos que chequea Gestión Humana (espejo de INGRESO_REQUISITOS en config.js).
create or replace function public._ing_requisitos(p_conductor boolean)
returns text[] language sql immutable
as $$
  select array['hoja_vida', 'referencias', 'entrevista', 'examen_medico', 'seguridad_social', 'contrato']
         || case when p_conductor then array['licencia', 'psicotecnicas', 'prueba_manejo'] else '{}'::text[] end;
$$;
create or replace function public._ing_requisitos_faltan(p_sel jsonb, p_conductor boolean)
returns text[] language sql immutable
as $$
  select coalesce(array_agg(k order by o), '{}')
    from unnest(public._ing_requisitos(p_conductor)) with ordinality r(k, o)
   where coalesce(p_sel -> 'apr_requisitos' ->> k, '') <> 'true';
$$;
-- Cómo se le dice a cada requisito en los mensajes (los mismos nombres de config.js).
create or replace function public._ing_requisito_nombre(p_k text)
returns text language sql immutable
as $$
  select case p_k
    when 'hoja_vida' then 'hoja de vida y documentos personales' when 'referencias' then 'referencias laborales'
    when 'entrevista' then 'entrevista' when 'examen_medico' then 'examen médico de ingreso'
    when 'seguridad_social' then 'afiliación a seguridad social' when 'contrato' then 'contrato firmado'
    when 'licencia' then 'licencia verificada en el RUNT' when 'psicotecnicas' then 'pruebas psicotécnicas'
    when 'prueba_manejo' then 'prueba de manejo' else p_k end;
$$;
-- El afiliado aprueba solo a los conductores de un carro que no es de la empresa (como en vacaciones).
create or replace function public._ing_afiliado(p_tipo text, p_propietario text)
returns text language sql immutable
as $$
  select case when coalesce(p_tipo, '') = 'CONDUCTOR' and nullif(btrim(p_propietario), '') is not null
                   and p_propietario !~* 'poblado\s*laureles' then btrim(p_propietario) end;
$$;
-- APROBADO cuando aprueban todas las instancias que aplican y los antecedentes están firmados;
-- NO APROBADO si alguna rechaza; si no, sigue en proceso (null).
create or replace function public._ing_estado(p_sel jsonb, p_afiliado boolean)
returns text language sql immutable
as $$
  select case
    when 'RECHAZADO' in (p_sel ->> 'apr_gh_estado', p_sel ->> 'apr_ger_estado',
                         case when p_afiliado then p_sel ->> 'apr_afi_estado' end,
                         case when (p_sel ->> 'apr_junta_aplica') = 'true' then p_sel ->> 'apr_jun_estado' end)
      then 'NO APROBADO'
    when (p_sel ->> 'apr_gh_estado') = 'APROBADO' and (p_sel ->> 'apr_ger_estado') = 'APROBADO'
     and (not p_afiliado or (p_sel ->> 'apr_afi_estado') = 'APROBADO')
     and ((p_sel ->> 'apr_junta_aplica') is distinct from 'true' or (p_sel ->> 'apr_jun_estado') = 'APROBADO')
     and p_sel ? 'antecedentes_verificado_en'
      then 'APROBADO'
  end;
$$;
-- Las claves de una instancia, para quitarlas de una vez.
create or replace function public._ing_sin(p_sel jsonb, p_pre text)
returns jsonb language sql immutable
as $$
  select p_sel - (p_pre || '_estado') - (p_pre || '_por') - (p_pre || '_nombre') - (p_pre || '_en')
               - (p_pre || '_nota') - (p_pre || '_fecha') - (p_pre || '_doc');
$$;
revoke all on function public._ing_requisitos(boolean) from public, anon, authenticated;
revoke all on function public._ing_requisitos_faltan(jsonb, boolean) from public, anon, authenticated;
revoke all on function public._ing_afiliado(text, text) from public, anon, authenticated;
revoke all on function public._ing_estado(jsonb, boolean) from public, anon, authenticated;
revoke all on function public._ing_sin(jsonb, text) from public, anon, authenticated;
revoke all on function public._ing_requisito_nombre(text) from public, anon, authenticated;

-- 3) Recalcular el estado del ingreso y llenar los campos del formato -----------------------------------
--    Lo llaman todas las funciones que tocan la sección 7. Si el visto bueno de Gestión Humana ya no
--    se sostiene (falta un requisito o se cayó la firma de antecedentes), se cae aquí, con su rastro.
create or replace function public._ing_aplicar(p_vinculacion bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v record; s jsonb; v_afi text; v_cond boolean; v_est text;
begin
  select pv.id, pv.seleccion, pv.fecha_ingreso, pv.tipo, pv.cargo,
         coalesce(nullif(pv.nombre_propietario, ''), p.nombre_propietario) propietario
    into v
    from perfil_vinculaciones pv left join perfilsociodemografico p on p.cedula = pv.cedula
   where pv.id = p_vinculacion;
  if v.id is null then return null; end if;
  s := v.seleccion;
  if v.fecha_ingreso is null or v.fecha_ingreso < public._antec_desde() then return s; end if;

  v_cond := public._antec_conductor(v.tipo, v.cargo);
  v_afi := public._ing_afiliado(v.tipo, v.propietario);
  if (s ->> 'apr_gh_estado') = 'APROBADO'
     and (cardinality(public._ing_requisitos_faltan(s, v_cond)) > 0 or not (s ? 'antecedentes_verificado_en')) then
    s := public._ing_sin(s, 'apr_gh');
    insert into aprobaciones_log (modulo, registro_id, instancia, estado, nota, por)
    values ('INGRESOS', p_vinculacion, 'GH', 'QUITADO',
            'Se cayó solo: falta un requisito o la firma de la verificación de antecedentes.', 'sistema');
  end if;
  if (s ->> 'apr_junta_aplica') is distinct from 'true' then s := public._ing_sin(s, 'apr_jun'); end if;
  if v_afi is null then s := public._ing_sin(s, 'apr_afi'); end if;

  v_est := public._ing_estado(s, v_afi is not null);
  s := s - 'estado' - 'aprob_gerencia' - 'aprob_gerencia_fecha' - 'aprob_afiliado' - 'aprob_afiliado_fecha'
         - 'aprob_junta' - 'aprob_junta_fecha'
    || jsonb_strip_nulls(jsonb_build_object(
         'estado', v_est,
         'aprob_gerencia', case when (s ->> 'apr_ger_estado') = 'APROBADO' then coalesce(s ->> 'apr_ger_nombre', s ->> 'apr_ger_por') end,
         'aprob_gerencia_fecha', case when (s ->> 'apr_ger_estado') = 'APROBADO' then ((s ->> 'apr_ger_en')::timestamptz at time zone 'America/Bogota')::date::text end,
         'aprob_afiliado', case when v_afi is null then 'NO APLICA' when (s ->> 'apr_afi_estado') = 'APROBADO' then v_afi end,
         'aprob_afiliado_fecha', case when (s ->> 'apr_afi_estado') = 'APROBADO' then s ->> 'apr_afi_fecha' end,
         'aprob_junta', case when (s ->> 'apr_junta_aplica') is distinct from 'true' then 'NO APLICA'
                             when (s ->> 'apr_jun_estado') = 'APROBADO' then 'JUNTA DIRECTIVA' end,
         'aprob_junta_fecha', case when (s ->> 'apr_jun_estado') = 'APROBADO' then s ->> 'apr_jun_fecha' end));
  update perfil_vinculaciones set seleccion = s where id = p_vinculacion;
  return s;
end $$;
revoke all on function public._ing_aplicar(bigint) from public, anon, authenticated;

-- 4) Gestión Humana chequea los requisitos (y dice si el ingreso pasa por la Junta) ------------------
create or replace function public.ingreso_requisitos_guardar(
  p_vinculacion bigint, p_requisitos jsonb, p_junta_aplica boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v record; s jsonb; v_req jsonb := '{}'::jsonb; k text; v_gh_antes text;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Los requisitos los chequea Gestión Humana.');
  end if;
  select id, seleccion, fecha_ingreso, tipo, cargo into v from perfil_vinculaciones where id = p_vinculacion for update;
  if v.id is null then return jsonb_build_object('ok', false, 'error', 'La vinculación no existe.'); end if;
  if v.fecha_ingreso is null or v.fecha_ingreso < public._antec_desde() then
    return jsonb_build_object('ok', false, 'error', 'Este ingreso es anterior al módulo de aprobación.');
  end if;
  foreach k in array public._ing_requisitos(public._antec_conductor(v.tipo, v.cargo)) loop
    if coalesce(p_requisitos ->> k, '') = 'true' then v_req := v_req || jsonb_build_object(k, true); end if;
  end loop;
  v_gh_antes := v.seleccion ->> 'apr_gh_estado';
  s := v.seleccion || jsonb_build_object('apr_requisitos', v_req, 'apr_junta_aplica', coalesce(p_junta_aplica, false),
         'apr_requisitos_por', lower(coalesce(auth.email(), '')), 'apr_requisitos_en', now());
  update perfil_vinculaciones set seleccion = s where id = p_vinculacion;
  s := public._ing_aplicar(p_vinculacion);
  return jsonb_build_object('ok', true, 'seleccion', s,
    'gh_quitado', coalesce(v_gh_antes = 'APROBADO', false) and (s ->> 'apr_gh_estado') is distinct from 'APROBADO');
end $$;
revoke all on function public.ingreso_requisitos_guardar(bigint, jsonb, boolean) from public, anon;
grant execute on function public.ingreso_requisitos_guardar(bigint, jsonb, boolean) to authenticated;

-- 5) Aprobar, rechazar o quitar la decisión de una instancia --------------------------------------
--    GH y GERENCIA las marca cada área; AFILIADO y JUNTA las registra Gestión Humana en su nombre.
create or replace function public.ingreso_decidir(
  p_vinculacion bigint, p_instancia text, p_estado text, p_nota text default null,
  p_fecha date default null, p_doc_path text default null, p_doc_nombre text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v record; s jsonb; v_pre text; v_cond boolean; v_afi text; v_falta text[];
  v_nota text := nullif(btrim(coalesce(p_nota, '')), '');
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_fecha date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
  v_yo text := lower(coalesce(auth.email(), ''));
begin
  if p_estado not in ('APROBADO', 'RECHAZADO', 'PENDIENTE') then
    return jsonb_build_object('ok', false, 'error', 'Decisión no válida.');
  end if;
  v_pre := case p_instancia when 'GH' then 'apr_gh' when 'GERENCIA' then 'apr_ger'
                            when 'AFILIADO' then 'apr_afi' when 'JUNTA' then 'apr_jun' end;
  if v_pre is null then return jsonb_build_object('ok', false, 'error', 'Instancia no válida.'); end if;
  if p_instancia = 'GERENCIA' and not public.es_permiso_gerencia() then
    return jsonb_build_object('ok', false, 'error', 'Esta casilla la marca Gerencia.');
  end if;
  if p_instancia <> 'GERENCIA' and not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Esta casilla la marca Gestión Humana.');
  end if;

  select pv.id, pv.seleccion, pv.fecha_ingreso, pv.tipo, pv.cargo,
         coalesce(nullif(pv.nombre_propietario, ''), p.nombre_propietario) propietario
    into v
    from perfil_vinculaciones pv left join perfilsociodemografico p on p.cedula = pv.cedula
   where pv.id = p_vinculacion
   for update of pv;
  if v.id is null then return jsonb_build_object('ok', false, 'error', 'La vinculación no existe.'); end if;
  if v.fecha_ingreso is null or v.fecha_ingreso < public._antec_desde() then
    return jsonb_build_object('ok', false, 'error', 'Este ingreso es anterior al módulo de aprobación.');
  end if;
  s := v.seleccion;
  v_cond := public._antec_conductor(v.tipo, v.cargo);
  v_afi := public._ing_afiliado(v.tipo, v.propietario);
  if p_instancia = 'AFILIADO' and v_afi is null then
    return jsonb_build_object('ok', false, 'error', 'Este ingreso no lo aprueba un afiliado.');
  end if;
  if p_instancia = 'JUNTA' and (s ->> 'apr_junta_aplica') is distinct from 'true' then
    return jsonb_build_object('ok', false, 'error', 'Este ingreso no pasa por la Junta Directiva.');
  end if;

  if p_estado = 'APROBADO' then
    if p_instancia = 'GH' then
      select coalesce(array_agg(public._ing_requisito_nombre(k)), '{}') into v_falta
        from unnest(public._ing_requisitos_faltan(s, v_cond)) k;
      if not (s ? 'antecedentes_verificado_en') then v_falta := array_prepend('verificación de antecedentes firmada', v_falta); end if;
      if cardinality(v_falta) > 0 then
        return jsonb_build_object('ok', false, 'error',
          'Para el visto bueno de Gestión Humana falta: ' || array_to_string(v_falta, ', ') || '.');
      end if;
    elsif (s ->> 'apr_gh_estado') is distinct from 'APROBADO' then
      return jsonb_build_object('ok', false, 'error', 'Primero Gestión Humana da su visto bueno con los requisitos completos.');
    end if;
  elsif p_estado = 'RECHAZADO' and v_nota is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe el motivo del rechazo.');
  end if;
  if p_instancia in ('AFILIADO', 'JUNTA') and p_estado <> 'PENDIENTE' and v_fecha > v_hoy then
    return jsonb_build_object('ok', false, 'error', 'La fecha de la autorización no puede ser futura.');
  end if;
  if p_doc_path is not null then
    if p_instancia not in ('AFILIADO', 'JUNTA')
       or p_doc_path !~ ('^v/' || p_vinculacion || '/aprob_' || lower(p_instancia) || '-[0-9]+\.(pdf|jpg|png|webp)$')
       or not exists (select 1 from storage.objects where bucket_id = 'antecedentes' and name = p_doc_path) then
      return jsonb_build_object('ok', false, 'error', 'El soporte no se subió bien. Intenta de nuevo.');
    end if;
  end if;

  s := public._ing_sin(s, v_pre);
  if p_estado <> 'PENDIENTE' then
    s := s || jsonb_strip_nulls(jsonb_build_object(
      v_pre || '_estado', p_estado, v_pre || '_por', v_yo,
      v_pre || '_nombre', (select nombre from perfiles where id = auth.uid()),
      v_pre || '_en', now(), v_pre || '_nota', v_nota,
      v_pre || '_fecha', case when p_instancia in ('AFILIADO', 'JUNTA') then v_fecha::text end,
      v_pre || '_doc', case when p_doc_path is not null then jsonb_build_object('path', p_doc_path,
                         'nombre', left(coalesce(nullif(btrim(p_doc_nombre), ''), 'soporte'), 120)) end));
  end if;
  update perfil_vinculaciones set seleccion = s where id = p_vinculacion;
  insert into aprobaciones_log (modulo, registro_id, instancia, estado, nota, por)
  values ('INGRESOS', p_vinculacion, p_instancia, p_estado, v_nota, v_yo);
  s := public._ing_aplicar(p_vinculacion);
  return jsonb_build_object('ok', true, 'estado', s ->> 'estado', 'seleccion', s);
end $$;
revoke all on function public.ingreso_decidir(bigint, text, text, text, date, text, text) from public, anon;
grant execute on function public.ingreso_decidir(bigint, text, text, text, date, text, text) to authenticated;

-- 6) El módulo: los ingresos desde _antec_desde() con sus requisitos y aprobaciones ----------------
create or replace function public.ingresos_aprobacion()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_permiso_ver() then jsonb_build_object('ok', false)
    else jsonb_build_object('ok', true, 'desde', public._antec_desde(),
      'es_th', public.es_talento_humano(), 'es_gerencia', public.es_permiso_gerencia(),
      'filas', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', x.id, 'cedula', x.cedula, 'nombre', x.nombre, 'cargo', x.cargo, 'tipo', x.tipo, 'area', x.area,
                 'fecha_ingreso', x.fecha_ingreso, 'fecha_retiro', x.fecha_retiro, 'conductor', x.cond,
                 'afiliado', public._ing_afiliado(x.tipo, x.propietario),
                 'antecedentes', x.seleccion ? 'antecedentes_verificado_en',
                 'antecedentes_faltan', cardinality(public._antec_faltan(x.seleccion, x.cond)),
                 'requisitos_faltan', to_jsonb(public._ing_requisitos_faltan(x.seleccion, x.cond)),
                 'estado', public._ing_estado(x.seleccion, public._ing_afiliado(x.tipo, x.propietario) is not null),
                 'vinculacion', jsonb_build_object('id', x.id, 'cedula', x.cedula, 'fecha_ingreso', x.fecha_ingreso,
                   'fecha_retiro', x.fecha_retiro, 'tipo', x.tipo, 'cargo', x.cargo, 'seleccion', x.seleccion))
               order by x.fecha_ingreso desc, x.nombre)
          from (select pv.id, pv.cedula, p.nombre, pv.cargo, pv.tipo, pv.area, pv.fecha_ingreso, pv.fecha_retiro, pv.seleccion,
                       public._antec_conductor(pv.tipo, pv.cargo) cond,
                       coalesce(nullif(pv.nombre_propietario, ''), p.nombre_propietario) propietario
                  from perfil_vinculaciones pv
                  join perfilsociodemografico p on p.cedula = pv.cedula
                 where pv.fecha_ingreso >= public._antec_desde()) x), '[]'::jsonb))
  end;
$$;
revoke all on function public.ingresos_aprobacion() from public, anon;
grant execute on function public.ingresos_aprobacion() to authenticated;

-- 7) Los soportes del afiliado y de la Junta van al mismo bucket privado de sql/166 -----------------
drop policy if exists antec_docs_ins on storage.objects;
create policy antec_docs_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'antecedentes' and (select public.es_talento_humano())
              and name ~ '^v/[0-9]+/(procuraduria|contraloria|policia|simit|aprob_afiliado|aprob_junta)-[0-9]+\.(pdf|jpg|png|webp)$');

-- 8) La sección 7 a mano (sql/166) ya no pisa lo del módulo -----------------------------------------
--    En los ingresos del módulo, el estado y los campos de aprobación los calcula _ing_aplicar: lo que
--    llegue escrito a mano en esos campos se ignora, y las claves apr_* se conservan.
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
  v_calculados text[] := array['estado','aprob_gerencia','aprob_gerencia_fecha','aprob_afiliado','aprob_afiliado_fecha',
    'aprob_junta','aprob_junta_fecha'];
  v_json jsonb := '{}'::jsonb;
  v_ant  jsonb;
  v_vin  record;
  v_mod  boolean;
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
  v_mod := v_vin.fecha_ingreso >= public._antec_desde();

  for k, v in select key, value from jsonb_each(p_datos) loop
    continue when not (k = any (v_campos));
    continue when v_mod and k = any (v_calculados);
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

  -- Lo que no viene en el formulario se conserva: documentos de antecedentes y todo lo del módulo.
  v_json := v_json || coalesce((select jsonb_object_agg(key, value) from jsonb_each(v_ant)
                                 where key like 'apr\_%' or (key like '%\_doc' and jsonb_typeof(value) = 'object')), '{}'::jsonb);

  -- La firma de Gestión Humana sobre los antecedentes (sql/166)
  if v_quiere and v_ant ? 'antecedentes_verificado_en'
     and public._antec_huella(v_json) = public._antec_huella(v_ant) then
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
    v_quitada := v_ant ? 'antecedentes_verificado_en';
  end if;

  v_json := v_json || jsonb_strip_nulls(jsonb_build_object('aspirante_id', v_ant -> 'aspirante_id'))
                   || jsonb_build_object('por', coalesce(nullif(auth.jwt() ->> 'email', ''), 'admin'), 'en', now());
  update perfil_vinculaciones set seleccion = v_json where id = p_vinculacion;
  v_json := coalesce(public._ing_aplicar(p_vinculacion), v_json);
  return jsonb_build_object('ok', true, 'seleccion', v_json, 'verificacion_quitada', v_quitada);
end $$;
revoke all on function public.perfil_seleccion_guardar(bigint, jsonb) from public, anon;
grant execute on function public.perfil_seleccion_guardar(bigint, jsonb) to authenticated;

-- Cambiar un documento de antecedentes también recalcula el ingreso (la firma se cae y con ella el
-- visto bueno de Gestión Humana).
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
  v_json := coalesce(public._ing_aplicar(p_vinculacion), v_json);
  return jsonb_build_object('ok', true, 'seleccion', v_json, 'verificacion_quitada', v_quitada);
end $$;
revoke all on function public.perfil_antecedente_doc(bigint, text, text, text) from public, anon;
grant execute on function public.perfil_antecedente_doc(bigint, text, text, text) to authenticated;
