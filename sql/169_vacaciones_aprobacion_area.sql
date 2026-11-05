-- ===================================================================================
-- 169: VACACIONES · LA APROBACIÓN DEL ÁREA TAMBIÉN ES UN CHECK, Y EN ORDEN
-- ===================================================================================
-- Pedido del 05/11/2026: "¿cómo sería la aprobación por parte de las partes involucradas? Puede
-- ser por un check". Hasta sql/164 aprobaban en la app Gestión Humana, Gerencia y Nómina; el
-- afiliado, el jefe inmediato y el coordinador de ruta firmaban solo el formato impreso.
--
-- DECISIONES DEL USUARIO (AskUserQuestion, 05/11/2026):
--   * El AFILIADO aprueba las vacaciones de los conductores de SUS carros con su propia cuenta
--     (hay 53 afiliados con cuenta). Si no entra, Gestión Humana lo marca en su nombre con la
--     fecha y el soporte de la autorización (WhatsApp, carta).
--   * El JEFE INMEDIATO (administrativos) y el COORDINADOR DE RUTA (conductores de la empresa) los
--     marca Gestión Humana en su nombre: en la app no está quién es jefe de quién.
--   * ORDEN: primero el área, luego Gestión Humana, luego Gerencia (si aplica) y al final Nómina.
--
-- QUIÉN ES "EL ÁREA" DE CADA SOLICITUD (area_tipo, se fija al crearla):
--   AFILIADO     conductor de un afiliado (el mismo que no pasa por Gerencia: req_gerencia = false)
--   COORDINADOR  conductor de la flota de la empresa
--   JEFE         administrativos y despachadores
-- Al 05/11/2026 no hay ninguna solicitud radicada, así que no hay nada que migrar.
-- ===================================================================================

-- 1) Las columnas del área ------------------------------------------------------------------------
alter table public.vacaciones
  add column if not exists area_tipo      text check (area_tipo in ('AFILIADO', 'COORDINADOR', 'JEFE')),
  add column if not exists area_estado    text check (area_estado in ('APROBADO', 'NEGADO')),
  add column if not exists area_nota      text,
  add column if not exists area_por       text,
  add column if not exists area_en        timestamptz,
  add column if not exists area_fecha     date,        -- cuándo autorizó, si lo registró Gestión Humana
  add column if not exists area_en_nombre boolean,     -- true = lo marcó Gestión Humana en su nombre
  add column if not exists area_doc       jsonb;       -- soporte {path, nombre} en el bucket 'vacaciones'

create or replace function public._vac_area_tipo(p_tipo text, p_flota_propia boolean)
returns text
language sql immutable
as $$
  select case when coalesce(p_tipo, '') = 'CONDUCTOR' and p_flota_propia is false then 'AFILIADO'
              when coalesce(p_tipo, '') = 'CONDUCTOR' then 'COORDINADOR'
              else 'JEFE' end
$$;
revoke all on function public._vac_area_tipo(text, boolean) from public, anon, authenticated;

-- Se fija sola al crear la solicitud, sin tocar _vac_crear.
create or replace function public._vac_area_tipo_trg()
returns trigger
language plpgsql
as $$
begin
  new.area_tipo := coalesce(new.area_tipo, public._vac_area_tipo(new.tipo_personal, new.flota_propia));
  return new;
end $$;
drop trigger if exists vacaciones_area_tipo on public.vacaciones;
create trigger vacaciones_area_tipo before insert on public.vacaciones
  for each row execute function public._vac_area_tipo_trg();
update public.vacaciones set area_tipo = public._vac_area_tipo(tipo_personal, flota_propia) where area_tipo is null;

-- El estado ahora exige también al área (PostgreSQL 17: se cambia la expresión en sitio).
alter table public.vacaciones alter column estado set expression as (
  case when anulado_en is not null then 'ANULADO'
       when gh_estado = 'NEGADO' or ger_estado = 'NEGADO' or area_estado = 'NEGADO' then 'NEGADO'
       when gh_estado = 'APROBADO' and (ger_estado = 'APROBADO' or not req_gerencia)
            and (area_estado = 'APROBADO' or area_tipo is null) then 'APROBADO'
       when gh_estado is not null or ger_estado is not null or area_estado is not null then 'EN TRAMITE'
       else 'PENDIENTE' end);

-- 2) El afiliado: ¿este vehículo es suyo? --------------------------------------------------------
create or replace function public.es_vac_afiliado_de(p_vehiculo text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_afiliado() and nullif(btrim(coalesce(p_vehiculo, '')), '') is not null
     and btrim(p_vehiculo) = any (public.mis_moviles_afiliado());
$$;
revoke all on function public.es_vac_afiliado_de(text) from public, anon;
grant execute on function public.es_vac_afiliado_de(text) to authenticated;

-- Las solicitudes de los conductores de SUS carros. Por función y no por la tabla: el afiliado no
-- necesita ver los correos de quién firmó ni la ruta del soporte.
create or replace function public.vacaciones_afiliado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_afiliado() then jsonb_build_object('ok', false)
    else jsonb_build_object('ok', true, 'filas', coalesce((
      select jsonb_agg(to_jsonb(v) - array['gh_por', 'ger_por', 'nom_por', 'area_por', 'registrada_por', 'anulado_por',
                                           'area_doc', 'nom_nota'] order by v.radicado desc)
        from public.vacaciones v
       where v.area_tipo = 'AFILIADO' and btrim(coalesce(v.vehiculo, '')) = any (public.mis_moviles_afiliado())), '[]'::jsonb))
  end;
$$;
revoke all on function public.vacaciones_afiliado() from public, anon;
grant execute on function public.vacaciones_afiliado() to authenticated;

-- 3) El soporte cuando Gestión Humana marca en nombre del área -----------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vacaciones', 'vacaciones', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists vac_docs_sel on storage.objects;
create policy vac_docs_sel on storage.objects for select to authenticated
  using (bucket_id = 'vacaciones' and (select public.es_vac_ver()));
drop policy if exists vac_docs_ins on storage.objects;
create policy vac_docs_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'vacaciones' and (select public.es_talento_humano())
              and name ~ '^v/[0-9]+/area-[0-9]+\.(pdf|jpg|png|webp)$');

-- 4) Decidir, en orden ---------------------------------------------------------------------------
--    Se cambia la firma (fecha y soporte del área): se borra la de 4 parámetros para que PostgREST
--    no tenga dos candidatas. La app la llama con nombres, así que las llamadas de siempre sirven.
drop function if exists public.vacaciones_decidir(bigint, text, text, text);
create or replace function public.vacaciones_decidir(
  p_id bigint, p_instancia text, p_estado text, p_nota text default null,
  p_fecha date default null, p_doc_path text default null, p_doc_nombre text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  r      public.vacaciones%rowtype;
  v_yo   text := lower(coalesce(auth.email(), ''));
  v_nota text := nullif(btrim(coalesce(p_nota, '')), '');
  v_est  text := nullif(p_estado, 'PENDIENTE');      -- null = quitar la decisión
  v_hoy  date := (now() at time zone 'America/Bogota')::date;
  v_propia boolean;
  v_quien text;
  v_log  text;
begin
  if p_estado not in ('APROBADO', 'NEGADO', 'PENDIENTE') then
    return jsonb_build_object('ok', false, 'error', 'Decisión no válida.');
  end if;
  -- Negar sin decir por qué deja a la persona sin saber qué cambiar.
  if p_estado = 'NEGADO' and v_nota is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se niega: la persona lo ve al consultar.');
  end if;
  select * into r from public.vacaciones where id = p_id for update;
  if not found or r.anulado_en is not null or r.nom_en is not null then
    return jsonb_build_object('ok', false, 'error', 'No se puede: la solicitud no existe, está anulada o ya la recibió Nómina.');
  end if;

  if p_instancia = 'AREA' then
    if r.area_tipo is null then
      return jsonb_build_object('ok', false, 'error', 'Esta solicitud no lleva aprobación del área.');
    end if;
    v_quien := case r.area_tipo when 'AFILIADO' then 'del afiliado del vehículo' when 'COORDINADOR' then 'del coordinador de ruta'
                                else 'del jefe inmediato' end;
    v_propia := r.area_tipo = 'AFILIADO' and public.es_vac_afiliado_de(r.vehiculo);
    if not v_propia and not public.es_talento_humano() then
      return jsonb_build_object('ok', false, 'error', case when r.area_tipo = 'AFILIADO'
        then 'Esta casilla la marca el afiliado del vehículo, o Gestión Humana en su nombre.'
        else 'Esta casilla la marca Gestión Humana en nombre ' || v_quien || '.' end);
    end if;
    -- El orden: con Gestión Humana ya decidida, el área no se mueve debajo de ella.
    if r.gh_estado is not null then
      return jsonb_build_object('ok', false, 'error', 'Gestión Humana ya decidió: para cambiar lo del área, primero Gestión Humana quita la suya.');
    end if;
    if not v_propia and v_est is not null and coalesce(p_fecha, v_hoy) > v_hoy then
      return jsonb_build_object('ok', false, 'error', 'La fecha de la autorización no puede ser futura.');
    end if;
    if p_doc_path is not null and (v_propia
         or p_doc_path !~ ('^v/' || p_id || '/area-[0-9]+\.(pdf|jpg|png|webp)$')
         or not exists (select 1 from storage.objects where bucket_id = 'vacaciones' and name = p_doc_path)) then
      return jsonb_build_object('ok', false, 'error', 'El soporte no se subió bien. Intenta de nuevo.');
    end if;
    update public.vacaciones
       set area_estado    = v_est,
           area_nota      = case when v_est is null then null else v_nota end,
           area_por       = case when v_est is null then null else v_yo end,
           area_en        = case when v_est is null then null else now() end,
           area_en_nombre = case when v_est is null then null else not v_propia end,
           area_fecha     = case when v_est is null or v_propia then null else coalesce(p_fecha, v_hoy) end,
           area_doc       = case when v_est is null or p_doc_path is null then null
                                 else jsonb_build_object('path', p_doc_path,
                                        'nombre', left(coalesce(nullif(btrim(p_doc_nombre), ''), 'soporte'), 120)) end
     where id = p_id;
    v_log := r.area_tipo;
    if v_est is not null and not v_propia then
      v_nota := concat_ws(' · ', v_nota, 'Registrado por Gestión Humana en nombre ' || v_quien
                          || ' (autorizó el ' || to_char(coalesce(p_fecha, v_hoy), 'DD/MM/YYYY') || ')');
    end if;

  elsif p_instancia = 'GH' then
    if not public.es_talento_humano() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gestión Humana.');
    end if;
    if p_estado = 'APROBADO' and r.area_tipo is not null and r.area_estado is distinct from 'APROBADO' then
      return jsonb_build_object('ok', false, 'error', 'Primero aprueba ' || case r.area_tipo when 'AFILIADO' then 'el afiliado del vehículo'
        when 'COORDINADOR' then 'el coordinador de ruta' else 'el jefe inmediato' end || '.');
    end if;
    if v_est is null and r.ger_estado is not null then
      return jsonb_build_object('ok', false, 'error', 'Gerencia ya decidió: para quitar la de Gestión Humana, primero Gerencia quita la suya.');
    end if;
    update public.vacaciones
       set gh_estado = v_est,
           gh_nota = case when v_est is null then null else v_nota end,
           gh_por  = case when v_est is null then null else v_yo end,
           gh_en   = case when v_est is null then null else now() end
     where id = p_id;
    v_log := 'GH';

  elsif p_instancia = 'GERENCIA' then
    if not public.es_permiso_gerencia() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gerencia.');
    end if;
    if not r.req_gerencia then
      return jsonb_build_object('ok', false, 'error', 'Al conductor de un afiliado lo autoriza su afiliado, no Gerencia.');
    end if;
    if v_est is not null and r.gh_estado is distinct from 'APROBADO' then
      return jsonb_build_object('ok', false, 'error', 'Primero da su visto bueno Gestión Humana.');
    end if;
    update public.vacaciones
       set ger_estado = v_est,
           ger_nota = case when v_est is null then null else v_nota end,
           ger_por  = case when v_est is null then null else v_yo end,
           ger_en   = case when v_est is null then null else now() end
     where id = p_id;
    v_log := 'GERENCIA';
  else
    return jsonb_build_object('ok', false, 'error', 'Instancia no válida.');
  end if;

  insert into public.aprobaciones_log (modulo, registro_id, instancia, estado, nota, por)
  values ('VACACIONES', p_id, v_log, p_estado, v_nota, v_yo);
  return (select jsonb_build_object('ok', true, 'estado', v.estado) from public.vacaciones v where v.id = p_id);
end $$;
revoke all on function public.vacaciones_decidir(bigint, text, text, text, date, text, text) from public, anon;
grant execute on function public.vacaciones_decidir(bigint, text, text, text, date, text, text) to authenticated;

-- 5) Lo que necesita el menú: el afiliado también entra, y "lo mío" sigue el orden ----------------
create or replace function public.vacaciones_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_vac_ver() and not public.es_afiliado() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'es_gh', public.es_talento_humano(),
      'es_gerencia', public.es_permiso_gerencia(),
      'es_nomina', public.es_vac_nomina(),
      'es_afiliado', public.es_afiliado() and not public.es_vac_ver(),
      -- lo que le falta hacer a QUIEN está mirando, en el orden de las aprobaciones
      'mios', (select count(1) from public.vacaciones v
                where v.anulado_en is null and v.estado <> 'NEGADO'
                  and ((public.es_talento_humano() and v.gh_estado is null
                        and (v.area_estado = 'APROBADO' or v.area_tipo is null
                             or (v.area_tipo in ('JEFE', 'COORDINADOR') and v.area_estado is null)))
                    or (public.es_permiso_gerencia() and v.req_gerencia and v.ger_estado is null and v.gh_estado = 'APROBADO')
                    or (public.es_vac_nomina() and v.estado = 'APROBADO' and v.nom_en is null)
                    or (v.area_tipo = 'AFILIADO' and v.area_estado is null
                        and btrim(coalesce(v.vehiculo, '')) = any (public.mis_moviles_afiliado())
                        and public.es_afiliado()))),
      'total', (select count(1) from public.vacaciones))
  end;
$$;
revoke all on function public.vacaciones_estado() from public, anon;
grant execute on function public.vacaciones_estado() to authenticated;
