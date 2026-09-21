-- ============================================================================================
-- 93) Certificado laboral desde el Perfil sociodemográfico
--
-- QUÉ RESUELVE: hoy el certificado se hace a mano en Word, se copia el del anterior y se cambian
-- los datos. Eso produce los errores que tiene el modelo actual (dice "laborar" en vez de
-- "labora", y "Desempeñó" en pasado para gente que sigue trabajando). Generándolo desde el
-- perfil, los datos salen de la ficha de la persona y la redacción se ajusta sola según esté
-- ACTIVA o INACTIVA.
--
-- POR QUÉ ESTA TABLA: el certificado lleva el nombre del gerente y de quien lo firma, el
-- teléfono de contacto y los valores del año (salario mínimo y auxilio de transporte). Nada de
-- eso puede ir escrito en el código: este repositorio es PÚBLICO. Por eso vive aquí, detrás de
-- RLS, y la fila se llena con un insert aparte que NO se sube al repositorio.
--
-- Se aplica sobre sql/75 (perfil) y sql/78 (Gestión Humana).
-- ============================================================================================

-- 1) Lo que cambia con el tiempo o no puede ser público -----------------------------------------
create table if not exists public.certificado_config (
  id                  int primary key default 1 check (id = 1),
  empresa_nombre      text not null default 'AUTOBUSES EL POBLADO LAURELES S.A.',
  empresa_nit         text not null default 'NIT. 890.927.437-3',
  ciudad              text not null default 'Medellín',
  telefono            text,                    -- el que se imprime en "cualquier información..."
  firmante1_nombre    text,
  firmante1_cargo     text default 'Gerente General',
  firmante1_firma     text,                    -- imagen de la firma (data URI o URL); opcional
  firmante2_nombre    text,
  firmante2_cargo     text default 'Auxiliar de Vinculaciones',
  firmante2_firma     text,
  smmlv               numeric,                 -- salario mínimo del año en curso
  auxilio_transporte  numeric,                 -- auxilio de transporte del año en curso
  anio_valores        int,                     -- a qué año corresponden los dos valores de arriba
  nota_pie            text,                    -- línea extra opcional al final (ej. vigencia)
  actualizado_en      timestamptz not null default now(),
  actualizado_por     text
);
insert into public.certificado_config (id) values (1) on conflict (id) do nothing;

comment on table public.certificado_config is
  'Datos del certificado laboral que no pueden ir en el codigo (repo publico): firmantes, telefono y valores del ano.';

alter table public.certificado_config enable row level security;
drop policy if exists cert_cfg_ver on public.certificado_config;
create policy cert_cfg_ver on public.certificado_config
  for select to authenticated using ((select public.es_talento_humano()));
revoke all on public.certificado_config from public, anon;
grant select on public.certificado_config to authenticated;

-- 2) Bitácora: un certificado laboral es un documento con efectos, hay que saber quién lo expidió
create table if not exists public.certificados_expedidos (
  id            bigserial primary key,
  consecutivo   text unique,
  cedula        text not null,
  nombre        text,
  cargo         text,
  estado        text,          -- ACTIVO / INACTIVO al momento de expedirlo
  con_salario   boolean not null default true,
  dirigido_a    text,
  expedido_por  text not null,
  expedido_en   timestamptz not null default now()
);
create index if not exists cert_exp_cedula_idx on public.certificados_expedidos (cedula, expedido_en desc);
comment on table public.certificados_expedidos is
  'Quien expidio cada certificado laboral, a nombre de quien y cuando. No guarda el documento, solo el hecho.';

alter table public.certificados_expedidos enable row level security;
drop policy if exists cert_exp_ver on public.certificados_expedidos;
create policy cert_exp_ver on public.certificados_expedidos
  for select to authenticated using ((select public.es_talento_humano()));
revoke all on public.certificados_expedidos from public, anon;
grant select on public.certificados_expedidos to authenticated;
revoke all on sequence public.certificados_expedidos_id_seq from public, anon;

-- 3) Leer la configuración (y avisar si falta llenarla) ------------------------------------------
create or replace function public.certificado_config_leer()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else (select jsonb_build_object(
      'ok', true,
      'empresa_nombre', c.empresa_nombre, 'empresa_nit', c.empresa_nit,
      'ciudad', c.ciudad, 'telefono', c.telefono,
      'firmante1_nombre', c.firmante1_nombre, 'firmante1_cargo', c.firmante1_cargo,
      'firmante1_firma', c.firmante1_firma,
      'firmante2_nombre', c.firmante2_nombre, 'firmante2_cargo', c.firmante2_cargo,
      'firmante2_firma', c.firmante2_firma,
      'smmlv', c.smmlv, 'auxilio_transporte', c.auxilio_transporte, 'anio_valores', c.anio_valores,
      'nota_pie', c.nota_pie,
      'falta', (select coalesce(jsonb_agg(f), '[]'::jsonb) from (
                  select 'firmante1_nombre' as f where coalesce(c.firmante1_nombre, '') = ''
                  union all select 'telefono' where coalesce(c.telefono, '') = ''
                  union all select 'smmlv' where c.smmlv is null
                  union all select 'auxilio_transporte' where c.auxilio_transporte is null) s))
      from public.certificado_config c where c.id = 1)
  end;
$$;
revoke all on function public.certificado_config_leer() from public, anon;
grant execute on function public.certificado_config_leer() to authenticated;

-- 4) Guardar la configuración (solo administración) ----------------------------------------------
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

-- 5) Registrar que se expidió, y devolver el consecutivo -----------------------------------------
--    El consecutivo permite que alguien que recibe el certificado pueda verificarlo despues.
create or replace function public.certificado_registrar(
  p_cedula text, p_con_salario boolean default true, p_dirigido_a text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_yo text := lower(coalesce(auth.email(), ''));
  v_p record; v_n int; v_anio int := extract(year from (now() at time zone 'America/Bogota'))::int;
  v_cons text;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para expedir certificados.');
  end if;
  select cedula, nombre, cargo, estado into v_p
    from public.perfilsociodemografico where cedula = p_cedula limit 1;
  if v_p is null then
    return jsonb_build_object('ok', false, 'error', 'No se encontro a esa persona en el perfil.');
  end if;

  select count(1) + 1 into v_n from public.certificados_expedidos
   where extract(year from (expedido_en at time zone 'America/Bogota')) = v_anio;
  v_cons := 'CL-' || v_anio || '-' || lpad(v_n::text, 4, '0');

  insert into public.certificados_expedidos
    (consecutivo, cedula, nombre, cargo, estado, con_salario, dirigido_a, expedido_por)
  values (v_cons, v_p.cedula, v_p.nombre, v_p.cargo, v_p.estado,
          coalesce(p_con_salario, true), nullif(trim(coalesce(p_dirigido_a, '')), ''), v_yo);

  return jsonb_build_object('ok', true, 'consecutivo', v_cons);
end $$;
revoke all on function public.certificado_registrar(text, boolean, text) from public, anon;
grant execute on function public.certificado_registrar(text, boolean, text) to authenticated;

-- 6) LLENAR LA CONFIGURACIÓN: va en un archivo aparte, NO en el repositorio.
--    update public.certificado_config set
--      telefono = '...', firmante1_nombre = '...', firmante2_nombre = '...',
--      smmlv = ..., auxilio_transporte = ..., anio_valores = 2026
--    where id = 1;
