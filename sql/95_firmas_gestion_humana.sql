-- ============================================================================================
-- 95) Las firmas del certificado las administra también Gestión Humana
--
-- POR QUÉ: en sql/94 cambiar quién firma quedó reservado a administración. Pero quien expide los
-- certificados es Gestión Humana: dejarlos consultando una pantalla que no pueden usar obliga a
-- pedirle a otra persona algo que es parte de su propio trabajo, y mientras tanto los
-- certificados siguen saliendo sin firma o con el nombre de quien ya no está.
--
-- Queda igual que el resto del módulo: `es_talento_humano()` = administración + Gestión Humana.
-- El registro de quién hizo el cambio se sigue guardando en `creado_por`.
--
-- Se aplica sobre sql/94.
-- ============================================================================================

-- 1) La pantalla deja de mostrarse en modo consulta para Gestión Humana --------------------------
create or replace function public.certificado_firmantes_listar()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_editar', public.es_talento_humano(),
      'vigentes', (select coalesce(jsonb_object_agg(f.rol, to_jsonb(f)), '{}'::jsonb)
                     from public.certificado_firmantes f where f.vigente_hasta is null),
      'historial', (select coalesce(jsonb_agg(jsonb_build_object(
                       'id', h.id, 'rol', h.rol, 'nombre', h.nombre, 'cargo', h.cargo,
                       'desde', h.vigente_desde, 'hasta', h.vigente_hasta,
                       'tiene_firma', (h.firma is not null))
                       order by h.vigente_desde desc, h.id desc), '[]'::jsonb)
                     from public.certificado_firmantes h where h.vigente_hasta is not null))
  end;
$$;
revoke all on function public.certificado_firmantes_listar() from public, anon;
grant execute on function public.certificado_firmantes_listar() to authenticated;

-- 2) Corregir al titular actual ------------------------------------------------------------------
create or replace function public.certificado_firmante_actualizar(
  p_rol text, p_nombre text default null, p_cargo text default null,
  p_firma text default null, p_alto int default null, p_dx int default null, p_dy int default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), '')); v_id bigint;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para cambiar quien firma.');
  end if;
  select id into v_id from public.certificado_firmantes
   where rol = p_rol and vigente_hasta is null;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'Todavia no hay nadie asignado a esa firma.');
  end if;

  update public.certificado_firmantes set
    nombre     = coalesce(nullif(trim(p_nombre), ''), nombre),
    cargo      = coalesce(nullif(trim(p_cargo), ''), cargo),
    -- '' borra la firma a proposito; null la deja como estaba
    firma      = case when p_firma is null then firma when p_firma = '' then null else p_firma end,
    firma_alto = coalesce(p_alto, firma_alto),
    firma_dx   = coalesce(p_dx, firma_dx),
    firma_dy   = coalesce(p_dy, firma_dy)
  where id = v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.certificado_firmante_actualizar(text, text, text, text, int, int, int)
  from public, anon;
grant execute on function public.certificado_firmante_actualizar(text, text, text, text, int, int, int)
  to authenticated;

-- 3) Cambio de titular ---------------------------------------------------------------------------
create or replace function public.certificado_firmante_cambiar(
  p_rol text, p_nombre text, p_cargo text, p_desde date default null,
  p_firma text default null, p_alto int default null, p_dx int default null, p_dy int default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_yo text := lower(coalesce(auth.email(), ''));
  v_desde date := coalesce(p_desde, (now() at time zone 'America/Bogota')::date);
  v_id bigint;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para cambiar quien firma.');
  end if;
  if p_rol not in ('GERENTE', 'GESTION_HUMANA') then
    return jsonb_build_object('ok', false, 'error', 'Esa firma no existe.');
  end if;
  if coalesce(trim(p_nombre), '') = '' or coalesce(trim(p_cargo), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe el nombre y el cargo.');
  end if;

  -- Cerrar al anterior el día antes de que entre el nuevo.
  update public.certificado_firmantes
     set vigente_hasta = v_desde - 1
   where rol = p_rol and vigente_hasta is null;

  insert into public.certificado_firmantes
    (rol, nombre, cargo, firma, firma_alto, firma_dx, firma_dy, vigente_desde, creado_por)
  values (p_rol, trim(p_nombre), trim(p_cargo), nullif(p_firma, ''),
          coalesce(p_alto, 58), coalesce(p_dx, 0), coalesce(p_dy, 0), v_desde, v_yo)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'desde', v_desde);
end $$;
revoke all on function public.certificado_firmante_cambiar(text, text, text, date, text, int, int, int)
  from public, anon;
grant execute on function public.certificado_firmante_cambiar(text, text, text, date, text, int, int, int)
  to authenticated;

-- 4) Y los valores del año (teléfono, salario mínimo, auxilio) también ---------------------------
--    Son los otros datos que Gestión Humana necesita mantener al día para que el certificado
--    salga completo. Cambiarlos no da acceso a ningún dato de personas.
create or replace function public.certificado_config_guardar(p jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para cambiar estos datos.');
  end if;
  update public.certificado_config set
    ciudad             = coalesce(nullif(trim(p->>'ciudad'), ''), ciudad),
    telefono           = coalesce(nullif(trim(p->>'telefono'), ''), telefono),
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
