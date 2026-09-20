-- 76: ALERTA DE LICENCIA DE CONDUCCIÓN al despachar + actualización por medio de los despachadores.
--
-- Regla (decisión del usuario, 16/09/2026): SOLO ALERTA, NO bloquea el despacho.
--   * La licencia sale del PERFIL SOCIODEMOGRÁFICO (sql/75, archivo de Gestión Humana). El conductor
--     que se despacha es de SONAR (conductores_sonar.dr_id) y se cruza por CÉDULA.
--   * VENCIDA (vence < hoy Colombia)  -> alerta roja.   POR VENCER (<= 30 días) -> alerta amarilla.
--   * El despachador sube la FOTO de la licencia renovada (bucket privado docs-conductores) -> PENDIENTE.
--   * OPERACIONES o ADMIN revisan: APROBAR exige la nueva fecha de vencimiento y actualiza el perfil;
--     RECHAZAR exige motivo (el despachador vuelve a ver la alerta con el motivo).
--   * 🔔 Notificaciones lista los conductores habilitados en SONAR con licencia vencida o por vencer.
-- Los despachadores NUNCA leen el perfil: todo pasa por RPC SECURITY DEFINER que devuelven solo
-- nombre, código SONAR, fecha de vencimiento y categoría (sin cédula ni datos personales).

-- ---- 1) Solicitudes de actualización de licencia ----
create table if not exists public.licencia_actualizaciones (
  id               bigint generated always as identity primary key,
  cedula           text not null,
  dr_id            text,
  conductor_nombre text,
  vence_anterior   date,           -- vencimiento que tenía cuando se subió (identifica el "ciclo")
  archivo_path     text not null,  -- bucket docs-conductores
  archivo_nombre   text,
  observacion      text,
  estado           text not null default 'PENDIENTE' check (estado in ('PENDIENTE','APROBADO','RECHAZADO')),
  subido_por       text,
  subido_en        timestamptz not null default now(),
  revisado_por     text,
  revisado_en      timestamptz,
  nueva_fecha      date,
  nueva_categoria  text,
  nuevo_numero     text,
  motivo_rechazo   text
);
create index if not exists lic_act_cedula_idx on public.licencia_actualizaciones (cedula, subido_en desc);
create index if not exists lic_act_estado_idx on public.licencia_actualizaciones (estado, subido_en desc);

alter table public.licencia_actualizaciones enable row level security;
-- Lectura directa solo admin (trae la cédula). Despachadores/operaciones leen por el RPC de listado.
drop policy if exists lic_act_sel on public.licencia_actualizaciones;
create policy lic_act_sel on public.licencia_actualizaciones
  for select to authenticated using ((select public.es_admin()));
revoke all on public.licencia_actualizaciones from anon;

-- ---- 2) Bucket privado para las fotos de las licencias ----
insert into storage.buckets (id, name, public)
values ('docs-conductores', 'docs-conductores', false)
on conflict (id) do nothing;

drop policy if exists docs_cond_sel on storage.objects;
create policy docs_cond_sel on storage.objects for select to authenticated
  using (bucket_id = 'docs-conductores' and (public.es_admin() or public.es_despachador()));
drop policy if exists docs_cond_ins on storage.objects;
create policy docs_cond_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'docs-conductores' and (public.es_admin() or public.es_despachador()));
drop policy if exists docs_cond_upd on storage.objects;
create policy docs_cond_upd on storage.objects for update to authenticated
  using (bucket_id = 'docs-conductores' and public.es_admin());
drop policy if exists docs_cond_del on storage.objects;
create policy docs_cond_del on storage.objects for delete to authenticated
  using (bucket_id = 'docs-conductores' and public.es_admin());

-- ---- 3) Estado de la licencia de un conductor SONAR (para la alerta al despachar) ----
create or replace function public.licencia_estado(p_dr_id text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_hoy  date := (now() at time zone 'America/Bogota')::date;
  v_ced  text;
  v_nom  text;
  p      public.perfilsociodemografico;
  s      public.licencia_actualizaciones;
  v_dias int;
begin
  if not (public.es_admin() or public.es_despachador() or public.es_auditor()) then return null; end if;
  select regexp_replace(coalesce(cedula, ''), '\D', '', 'g'), nombre into v_ced, v_nom
    from conductores_sonar where dr_id::text = p_dr_id limit 1;
  if coalesce(v_ced, '') = '' then return jsonb_build_object('encontrado', false); end if;
  select * into p from perfilsociodemografico where cedula = v_ced;
  if p.id is null then return jsonb_build_object('encontrado', false, 'nombre', v_nom); end if;
  -- solicitud del MISMO ciclo (subida con el vencimiento que tiene hoy la licencia)
  select * into s from licencia_actualizaciones
   where cedula = v_ced and vence_anterior is not distinct from p.licencia_vencimiento
   order by subido_en desc limit 1;
  v_dias := p.licencia_vencimiento - v_hoy;
  return jsonb_build_object(
    'encontrado', true,
    'nombre', coalesce(v_nom, p.nombre),
    'activo', p.estado = 'ACTIVO',          -- estado en Gestión Humana (el archivo)
    'vence', p.licencia_vencimiento,
    'dias', v_dias,
    'categoria', p.categoria_licencia,
    'nivel', case when p.licencia_vencimiento is null then 'sin_dato'
                  when v_dias < 0 then 'vencida'
                  when v_dias <= 30 then 'por_vencer'
                  else 'vigente' end,
    'solicitud', case when s.id is null then null
                      else jsonb_build_object('estado', s.estado, 'subido_en', s.subido_en, 'subido_por', s.subido_por,
                                              'motivo_rechazo', s.motivo_rechazo) end);
end $$;
revoke all on function public.licencia_estado(text) from public, anon;
grant execute on function public.licencia_estado(text) to authenticated;

-- ---- 4) Conductores con licencia vencida o por vencer (🔔 Notificaciones) ----
-- Solo los HABILITADOS en SONAR (los que se pueden despachar). `activo` = estado en Gestión Humana:
-- despachadores/operaciones ven solo los activos; el admin ve además los inactivos aún habilitados en SONAR.
create or replace function public.licencias_alertas()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(x order by x.dias, x.nombre), '[]'::jsonb)
  from (
    select distinct on (p.cedula)
           s.dr_id::text as dr_id, s.nombre, s.codigo, p.licencia_vencimiento as vence, p.estado = 'ACTIVO' as activo,
           p.licencia_vencimiento - (now() at time zone 'America/Bogota')::date as dias,
           (select la.estado from licencia_actualizaciones la
             where la.cedula = p.cedula and la.vence_anterior is not distinct from p.licencia_vencimiento
             order by la.subido_en desc limit 1) as solicitud
      from conductores_sonar s
      join perfilsociodemografico p on p.cedula = regexp_replace(coalesce(s.cedula, ''), '\D', '', 'g')
     where s.status = 'ENABLED'
       and p.licencia_vencimiento <= (now() at time zone 'America/Bogota')::date + 30
       and (public.es_admin() or ((public.es_despachador() or public.es_auditor()) and p.estado = 'ACTIVO'))
     order by p.cedula, s.dr_id
  ) x
$$;
revoke all on function public.licencias_alertas() from public, anon;
grant execute on function public.licencias_alertas() to authenticated;

-- ---- 5) El despachador sube la licencia renovada ----
create or replace function public.licencia_actualizacion_subir(
  p_dr_id text, p_archivo_path text, p_archivo_nombre text, p_observacion text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_ced text;
  v_nom text;
  p     public.perfilsociodemografico;
  v_id  bigint;
begin
  if not (public.es_admin() or public.es_despachador()) then
    raise exception 'Solo despachadores, operaciones o admin suben licencias.';
  end if;
  if coalesce(p_archivo_path, '') = '' or position(p_dr_id || '/' in p_archivo_path) <> 1 then
    raise exception 'Adjunta la foto de la licencia.';
  end if;
  select regexp_replace(coalesce(cedula, ''), '\D', '', 'g'), nombre into v_ced, v_nom
    from conductores_sonar where dr_id::text = p_dr_id limit 1;
  select * into p from perfilsociodemografico where cedula = coalesce(v_ced, '');
  if p.id is null then raise exception 'Este conductor no está en el perfil sociodemográfico.'; end if;
  if p.licencia_vencimiento is not null and p.licencia_vencimiento > v_hoy + 30 then
    raise exception 'La licencia de este conductor está vigente (vence %).', to_char(p.licencia_vencimiento, 'DD/MM/YYYY');
  end if;
  if exists (select 1 from licencia_actualizaciones where cedula = p.cedula and estado = 'PENDIENTE') then
    raise exception 'Ya hay una licencia de este conductor en revisión.';
  end if;
  insert into licencia_actualizaciones (cedula, dr_id, conductor_nombre, vence_anterior, archivo_path, archivo_nombre,
                                        observacion, subido_por)
  values (p.cedula, p_dr_id, coalesce(v_nom, p.nombre), p.licencia_vencimiento, p_archivo_path, left(p_archivo_nombre, 200),
          nullif(left(btrim(coalesce(p_observacion, '')), 500), ''), coalesce(auth.email(), 'desconocido'))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.licencia_actualizacion_subir(text, text, text, text) from public, anon;
grant execute on function public.licencia_actualizacion_subir(text, text, text, text) to authenticated;

-- ---- 6) Listado para operaciones / admin (sin cédula) ----
create or replace function public.licencia_actualizaciones_listar(p_estado text default null)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', la.id, 'dr_id', la.dr_id, 'conductor_nombre', la.conductor_nombre, 'vence_anterior', la.vence_anterior,
           'vence_actual', p.licencia_vencimiento, 'categoria_actual', p.categoria_licencia,
           'archivo_path', la.archivo_path, 'archivo_nombre', la.archivo_nombre, 'observacion', la.observacion,
           'estado', la.estado, 'subido_por', la.subido_por, 'subido_en', la.subido_en,
           'revisado_por', la.revisado_por, 'revisado_en', la.revisado_en, 'nueva_fecha', la.nueva_fecha,
           'nueva_categoria', la.nueva_categoria, 'nuevo_numero', la.nuevo_numero, 'motivo_rechazo', la.motivo_rechazo)
         order by la.subido_en desc), '[]'::jsonb)
    from (select * from licencia_actualizaciones
           where (p_estado is null or estado = p_estado) and public.es_operaciones()
           order by subido_en desc limit 300) la
    left join perfilsociodemografico p on p.cedula = la.cedula
$$;
revoke all on function public.licencia_actualizaciones_listar(text) from public, anon;
grant execute on function public.licencia_actualizaciones_listar(text) to authenticated;

create or replace function public.licencia_actualizaciones_pendientes_n()
returns int
language sql stable security definer set search_path to 'public'
as $$
  select case when public.es_operaciones()
              then (select count(1)::int from licencia_actualizaciones where estado = 'PENDIENTE') else 0 end
$$;
revoke all on function public.licencia_actualizaciones_pendientes_n() from public, anon;
grant execute on function public.licencia_actualizaciones_pendientes_n() to authenticated;

-- ---- 7) Operaciones / admin aprueban (actualiza el perfil) o rechazan ----
create or replace function public.licencia_actualizacion_revisar(
  p_id bigint, p_aprobar boolean, p_nueva_fecha date, p_categoria text, p_numero text, p_motivo text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  a     public.licencia_actualizaciones;
  v_cat text := upper(nullif(btrim(coalesce(p_categoria, '')), ''));
  v_num text := nullif(regexp_replace(coalesce(p_numero, ''), '\s', '', 'g'), '');
begin
  if not public.es_operaciones() then raise exception 'Solo operaciones o admin revisan licencias.'; end if;
  select * into a from licencia_actualizaciones where id = p_id for update;
  if a.id is null then raise exception 'La solicitud no existe.'; end if;
  if a.estado <> 'PENDIENTE' then raise exception 'Esta licencia ya fue revisada (%).', a.estado; end if;

  if coalesce(p_aprobar, false) then
    if p_nueva_fecha is null or p_nueva_fecha <= v_hoy then
      raise exception 'Escribe la NUEVA fecha de vencimiento de la licencia (debe ser posterior a hoy).';
    end if;
    if v_cat is not null and v_cat !~ '^[ABC][1-3]$' then raise exception 'Categoría de licencia no válida.'; end if;
    update perfilsociodemografico set
      licencia_vencimiento = p_nueva_fecha,
      categoria_licencia   = coalesce(v_cat, categoria_licencia),
      numero_licencia      = coalesce(v_num, numero_licencia),
      adjuntos             = adjuntos || jsonb_build_object('licencia_renovada', a.archivo_path)
    where cedula = a.cedula;
    update licencia_actualizaciones set estado = 'APROBADO', revisado_por = coalesce(auth.email(), 'admin'), revisado_en = now(),
           nueva_fecha = p_nueva_fecha, nueva_categoria = v_cat, nuevo_numero = v_num
     where id = p_id;
    return jsonb_build_object('ok', true, 'estado', 'APROBADO');
  end if;

  if nullif(btrim(coalesce(p_motivo, '')), '') is null then raise exception 'Escribe el motivo del rechazo.'; end if;
  update licencia_actualizaciones set estado = 'RECHAZADO', revisado_por = coalesce(auth.email(), 'admin'), revisado_en = now(),
         motivo_rechazo = left(btrim(p_motivo), 500)
   where id = p_id;
  return jsonb_build_object('ok', true, 'estado', 'RECHAZADO');
end $$;
revoke all on function public.licencia_actualizacion_revisar(bigint, boolean, date, text, text, text) from public, anon;
grant execute on function public.licencia_actualizacion_revisar(bigint, boolean, date, text, text, text) to authenticated;
