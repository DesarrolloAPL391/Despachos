-- ============================================================================================
-- 94) Quién firma el certificado, con vigencia y firma escaneada
--
-- EL PROBLEMA: en sql/93 los firmantes eran dos campos sueltos en `certificado_config`. Eso
-- funciona hasta que cambia el gerente: hay que acordarse de ir a la base y cambiarlo, y mientras
-- tanto se siguen expidiendo certificados con el nombre del anterior.
--
-- CÓMO QUEDA: cada firma es un CARGO con un titular vigente. Cuando entra otra persona no se
-- borra la anterior: se le pone fecha de salida y empieza la nueva. El certificado siempre usa
-- al que esté vigente hoy, así que se actualiza solo. Y queda el registro de quién firmaba en
-- cada época, que es lo que permite responder "¿quién era el gerente cuando se expidió esto?".
--
-- LA FIRMA: se guarda la imagen ya recortada (PNG con fondo transparente) más su tamaño y
-- posición, para que salga siempre igual y no haya que reacomodarla cada vez.
--
-- Se aplica sobre sql/93.
-- ============================================================================================

create table if not exists public.certificado_firmantes (
  id            bigserial primary key,
  rol           text not null check (rol in ('GERENTE', 'GESTION_HUMANA')),
  nombre        text not null,
  cargo         text not null,
  firma         text,                    -- PNG en data URI, ya recortado
  firma_alto    int  not null default 58 check (firma_alto between 20 and 160),
  firma_dx      int  not null default 0  check (firma_dx between -120 and 120),
  firma_dy      int  not null default 0  check (firma_dy between -80 and 80),
  vigente_desde date not null default (now() at time zone 'America/Bogota')::date,
  vigente_hasta date,                    -- null = es el que firma hoy
  creado_en     timestamptz not null default now(),
  creado_por    text
);
-- Un solo titular vigente por cargo: es lo que hace que el certificado no tenga que elegir.
create unique index if not exists cert_firm_vigente_idx
  on public.certificado_firmantes (rol) where vigente_hasta is null;
create index if not exists cert_firm_rol_idx on public.certificado_firmantes (rol, vigente_desde desc);

comment on table public.certificado_firmantes is
  'Titular de cada firma del certificado laboral, con vigencia. El vigente (vigente_hasta null) es el que se imprime.';

alter table public.certificado_firmantes enable row level security;
drop policy if exists cert_firm_ver on public.certificado_firmantes;
create policy cert_firm_ver on public.certificado_firmantes
  for select to authenticated using ((select public.es_talento_humano()));
revoke all on public.certificado_firmantes from public, anon;
grant select on public.certificado_firmantes to authenticated;
revoke all on sequence public.certificado_firmantes_id_seq from public, anon;

-- 1) Listar: el vigente de cada cargo y el historial ---------------------------------------------
create or replace function public.certificado_firmantes_listar()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_editar', public.es_admin(),
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

-- 2) Corregir al titular actual (nombre mal escrito, firma nueva, reubicarla) ---------------------
create or replace function public.certificado_firmante_actualizar(
  p_rol text, p_nombre text default null, p_cargo text default null,
  p_firma text default null, p_alto int default null, p_dx int default null, p_dy int default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), '')); v_id bigint;
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion cambia quien firma.');
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

-- 3) Cambio de titular: entra otra persona al cargo ----------------------------------------------
--    No se pisa al anterior: se le cierra la vigencia el día antes y entra el nuevo.
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
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion cambia quien firma.');
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

-- 4) El certificado pasa a leer de aquí ----------------------------------------------------------
--    Se mantiene el mismo formato de respuesta para no romper lo que ya funciona: si todavía no
--    hay firmantes cargados, responde con lo que quedó en `certificado_config`.
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
      'ciudad', c.ciudad, 'telefono', c.telefono,
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
                   where coalesce((select nombre from g), c.firmante1_nombre, '') = ''
                  union all select 'telefono' where coalesce(c.telefono, '') = ''
                  union all select 'smmlv' where coalesce(c.smmlv, 0) = 0
                  union all select 'auxilio_transporte' where coalesce(c.auxilio_transporte, 0) = 0) s))
      from c)
  end;
$$;
revoke all on function public.certificado_config_leer() from public, anon;
grant execute on function public.certificado_config_leer() to authenticated;

-- 5) Arranque: si ya había firmantes en certificado_config, se traen como titulares vigentes -----
insert into public.certificado_firmantes (rol, nombre, cargo, firma, vigente_desde, creado_por)
select 'GERENTE', c.firmante1_nombre, coalesce(c.firmante1_cargo, 'Gerente General'),
       c.firmante1_firma, (now() at time zone 'America/Bogota')::date, 'migracion sql/94'
  from public.certificado_config c
 where coalesce(c.firmante1_nombre, '') <> ''
   and not exists (select 1 from public.certificado_firmantes where rol = 'GERENTE');

insert into public.certificado_firmantes (rol, nombre, cargo, firma, vigente_desde, creado_por)
select 'GESTION_HUMANA', c.firmante2_nombre, coalesce(c.firmante2_cargo, 'Coordinador de Gestión Humana'),
       c.firmante2_firma, (now() at time zone 'America/Bogota')::date, 'migracion sql/94'
  from public.certificado_config c
 where coalesce(c.firmante2_nombre, '') <> ''
   and not exists (select 1 from public.certificado_firmantes where rol = 'GESTION_HUMANA');
