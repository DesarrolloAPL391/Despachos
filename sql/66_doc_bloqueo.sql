-- 66: BLOQUEO de despacho por DOCUMENTO VENCIDO (SOAT / tecnomecánica / tarjeta de operación)
-- con flujo de desbloqueo provisional + aprobación de operaciones.
--
-- Regla (molde = preventiva_suspendido, sql/62):
--   Un carro queda SUSPENDIDO para despacho si alguno de esos 3 documentos está VENCIDO
--   (vence < hoy Colombia) y NO tiene una solicitud de desbloqueo vigente.
--   El despachador sube la foto/PDF -> solicitud PENDIENTE -> DESBLOQUEO PROVISIONAL (puede despachar).
--   Operaciones APRUEBA (digita la nueva fecha -> actualiza la ficha, el vencido desaparece) o
--   RECHAZA (motivo -> se vuelve a bloquear hasta que suban de nuevo).
--   Auditor ve todo el proceso (solo lectura).

-- ---- 1) Tabla del proceso de desbloqueo ----
create table if not exists public.doc_desbloqueos (
  id              bigint generated always as identity primary key,
  vehiculo_id     bigint not null references public.parque_automotor(id) on delete cascade,
  numero_interno  text,
  placa           text,
  ruta            text,
  tipo            text not null check (tipo in ('soat','tecnomecanica','tarjeta_operacion')),
  vence_al_subir  date,          -- el vencimiento vencido que motivó el bloqueo (referencia)
  archivo_path    text,          -- foto/PDF que subió el despachador (bucket docs-vehiculos)
  archivo_nombre  text,
  observacion     text,          -- nota opcional del despachador
  estado          text not null default 'PENDIENTE' check (estado in ('PENDIENTE','APROBADO','RECHAZADO')),
  subido_por      text,          -- correo del despachador que subió
  subido_en       timestamptz not null default now(),
  revisado_por    text,          -- correo de operaciones que revisó
  revisado_en     timestamptz,
  nueva_fecha     date,          -- vigencia que confirma operaciones al aprobar
  nuevo_numero    text,
  motivo_rechazo  text
);
create index if not exists doc_desbloqueos_veh_idx    on public.doc_desbloqueos (vehiculo_id, tipo, subido_en desc);
create index if not exists doc_desbloqueos_estado_idx on public.doc_desbloqueos (estado, subido_en desc);

alter table public.doc_desbloqueos enable row level security;
-- Lectura: control (admin, operaciones, auditor) y los despachadores (para ver el estado de sus subidas).
drop policy if exists doc_desbloqueos_sel on public.doc_desbloqueos;
create policy doc_desbloqueos_sel on public.doc_desbloqueos
  for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones())
       or (select public.es_auditor()) or (select public.es_despachador()) );
-- Escritura: solo por los RPC (SECURITY DEFINER). Nada de INSERT/UPDATE directo.

-- ---- 2) Estado de bloqueo de un móvil (para el aviso del despacho) ----
create or replace function public.doc_bloqueo_estado(p_interno text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v     public.parque_automotor;
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_docs jsonb := '[]'::jsonb;
  v_bloq boolean := false;
  r record;
  v_last public.doc_desbloqueos;
  v_sit text;
begin
  select * into v from public.parque_automotor where numero_interno = p_interno::text limit 1;
  if v.id is null then return jsonb_build_object('bloqueado', false, 'docs', '[]'::jsonb); end if;
  for r in
    select * from (values
      ('soat','SOAT', v.vence_soat),
      ('tecnomecanica','Tecnomecánica', v.vence_tecnomecanica),
      ('tarjeta_operacion','Tarjeta de operación', v.vence_tarjeta_operacion)
    ) as x(tipo, label, venc)
  loop
    if r.venc is null or (r.venc - v_hoy) >= 0 then continue; end if;  -- vigente o sin fecha: no bloquea
    select * into v_last from public.doc_desbloqueos
      where vehiculo_id = v.id and tipo = r.tipo
      order by subido_en desc, id desc limit 1;
    if v_last.id is null then
      v_sit := 'vencido_sin_subir'; v_bloq := true;
    elsif v_last.estado = 'PENDIENTE' then
      v_sit := 'en_revision';               -- desbloqueo provisional
    elsif v_last.estado = 'APROBADO' then
      v_sit := 'aprobado';                  -- (normalmente ya no estaría vencido)
    else
      v_sit := 'rechazado'; v_bloq := true; -- operaciones rechazó: re-bloquea
    end if;
    v_docs := v_docs || jsonb_build_object(
      'tipo', r.tipo, 'label', r.label, 'vence', r.venc, 'dias', (r.venc - v_hoy),
      'situacion', v_sit, 'solicitud_id', v_last.id,
      'subido_por', v_last.subido_por, 'subido_en', v_last.subido_en,
      'motivo_rechazo', v_last.motivo_rechazo);
  end loop;
  return jsonb_build_object('bloqueado', v_bloq, 'interno', v.numero_interno, 'placa', v.placa,
    'ruta', v.ruta, 'vehiculo_id', v.id, 'docs', v_docs);
end $$;
revoke all on function public.doc_bloqueo_estado(text) from public;
grant execute on function public.doc_bloqueo_estado(text) to authenticated;

-- ---- 3) El despachador sube la foto/PDF -> solicitud PENDIENTE (desbloqueo provisional) ----
create or replace function public.doc_desbloqueo_subir(
  p_vehiculo_id bigint, p_tipo text, p_archivo_path text,
  p_archivo_nombre text default null, p_observacion text default null)
returns public.doc_desbloqueos
language plpgsql security definer set search_path to 'public'
as $$
declare v public.parque_automotor; v_row public.doc_desbloqueos; v_venc date;
        v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  if not (public.es_admin() or public.es_despachador()) then raise exception 'No autorizado'; end if;
  if p_tipo not in ('soat','tecnomecanica','tarjeta_operacion') then raise exception 'Tipo inválido: %', p_tipo; end if;
  if coalesce(p_archivo_path,'') = '' then raise exception 'Debe adjuntar el documento (foto o PDF).'; end if;
  select * into v from public.parque_automotor where id = p_vehiculo_id;
  if v.id is null then raise exception 'El vehículo no existe.'; end if;
  v_venc := case p_tipo when 'soat' then v.vence_soat when 'tecnomecanica' then v.vence_tecnomecanica else v.vence_tarjeta_operacion end;
  if v_venc is null or (v_venc - v_hoy) >= 0 then
    raise exception 'Ese documento no está vencido; no requiere desbloqueo.';
  end if;
  insert into public.doc_desbloqueos(vehiculo_id,numero_interno,placa,ruta,tipo,vence_al_subir,
      archivo_path,archivo_nombre,observacion,estado,subido_por)
    values (v.id, v.numero_interno, v.placa, v.ruta, p_tipo, v_venc,
      p_archivo_path, nullif(trim(p_archivo_nombre),''), nullif(trim(p_observacion),''),
      'PENDIENTE', coalesce(auth.email(),'sistema'))
    returning * into v_row;
  return v_row;
end $$;
revoke all on function public.doc_desbloqueo_subir(bigint,text,text,text,text) from public;
grant execute on function public.doc_desbloqueo_subir(bigint,text,text,text,text) to authenticated;

-- ---- 4) Operaciones revisa: APRUEBA (nueva vigencia) o RECHAZA (motivo) ----
create or replace function public.doc_desbloqueo_revisar(
  p_id bigint, p_aprobar boolean, p_nueva_fecha date default null,
  p_numero text default null, p_motivo text default null)
returns public.doc_desbloqueos
language plpgsql security definer set search_path to 'public'
as $$
declare v_row public.doc_desbloqueos; v_hoy date := (now() at time zone 'America/Bogota')::date; v_yo text;
begin
  if not (public.es_admin() or public.es_operaciones()) then raise exception 'Solo operaciones puede revisar el desbloqueo.'; end if;
  v_yo := coalesce(auth.email(),'sistema');
  select * into v_row from public.doc_desbloqueos where id = p_id for update;
  if v_row.id is null then raise exception 'La solicitud no existe.'; end if;
  if v_row.estado <> 'PENDIENTE' then raise exception 'La solicitud ya fue revisada (% por %).', v_row.estado, v_row.revisado_por; end if;

  if p_aprobar then
    if p_nueva_fecha is null then raise exception 'Debe indicar la nueva fecha de vencimiento para aprobar.'; end if;
    if p_nueva_fecha < v_hoy then raise exception 'La nueva fecha de vencimiento debe ser de hoy en adelante (hoy: %).', to_char(v_hoy,'DD/MM/YYYY'); end if;
    update public.doc_desbloqueos
       set estado='APROBADO', revisado_por=v_yo, revisado_en=now(),
           nueva_fecha=p_nueva_fecha, nuevo_numero=nullif(trim(p_numero),'')
     where id = p_id returning * into v_row;
    -- 1) actualizar la ficha del parque (esto limpia el vencido y queda en parque_auditoria)
    if v_row.tipo = 'soat' then
      update public.parque_automotor
         set vence_soat=p_nueva_fecha, num_soat=coalesce(nullif(trim(p_numero),''),num_soat) where id=v_row.vehiculo_id;
    elsif v_row.tipo = 'tecnomecanica' then
      update public.parque_automotor
         set vence_tecnomecanica=p_nueva_fecha, num_tecnomecanica=coalesce(nullif(trim(p_numero),''),num_tecnomecanica) where id=v_row.vehiculo_id;
    else
      update public.parque_automotor
         set vence_tarjeta_operacion=p_nueva_fecha, num_tarjeta_operacion=coalesce(nullif(trim(p_numero),''),num_tarjeta_operacion) where id=v_row.vehiculo_id;
    end if;
    -- 2) dejar el documento en el historial estándar (vehiculo_documentos), con el archivo que subió el despachador
    insert into public.vehiculo_documentos(vehiculo_id,tipo,fecha_vencimiento,fecha_anterior,numero,archivo_path,archivo_nombre,observacion,creado_por)
      values (v_row.vehiculo_id, v_row.tipo, p_nueva_fecha, v_row.vence_al_subir, nullif(trim(p_numero),''),
              v_row.archivo_path, v_row.archivo_nombre,
              'Desbloqueo aprobado por operaciones' || case when v_row.subido_por is not null then ' (subido por '||v_row.subido_por||')' else '' end,
              v_yo);
  else
    if coalesce(trim(p_motivo),'') = '' then raise exception 'Debe indicar el motivo del rechazo.'; end if;
    update public.doc_desbloqueos
       set estado='RECHAZADO', revisado_por=v_yo, revisado_en=now(), motivo_rechazo=trim(p_motivo)
     where id = p_id returning * into v_row;
  end if;
  return v_row;
end $$;
revoke all on function public.doc_desbloqueo_revisar(bigint,boolean,date,text,text) from public;
grant execute on function public.doc_desbloqueo_revisar(bigint,boolean,date,text,text) to authenticated;

-- ---- 5) Listado para el panel (operaciones revisa; auditor/despachador ven) ----
-- p_estado: 'PENDIENTE' | 'APROBADO' | 'RECHAZADO' | null (todas, recientes primero)
create or replace function public.doc_desbloqueos_listar(p_estado text default null, p_limite int default 300)
returns setof public.doc_desbloqueos
language sql stable security definer set search_path to 'public'
as $$
  select * from public.doc_desbloqueos
  where ( public.es_admin() or public.es_operaciones() or public.es_auditor() or public.es_despachador() )
    and (p_estado is null or estado = p_estado)
  order by (estado = 'PENDIENTE') desc, coalesce(revisado_en, subido_en) desc, id desc
  limit greatest(1, least(coalesce(p_limite,300), 1000));
$$;
revoke all on function public.doc_desbloqueos_listar(text,int) from public;
grant execute on function public.doc_desbloqueos_listar(text,int) to authenticated;

-- ---- 6) Contador de pendientes (para el badge del menú de operaciones) ----
create or replace function public.doc_desbloqueos_pendientes_n()
returns integer
language sql stable security definer set search_path to 'public'
as $$
  select case when (public.es_admin() or public.es_operaciones() or public.es_auditor())
              then (select count(*)::int from public.doc_desbloqueos where estado='PENDIENTE')
              else 0 end;
$$;
revoke all on function public.doc_desbloqueos_pendientes_n() from public;
grant execute on function public.doc_desbloqueos_pendientes_n() to authenticated;

-- ---- 7) Storage: el AUDITOR también puede firmar URLs del bucket docs-vehiculos (para ver el archivo) ----
-- (admin/despachador/operaciones ya tienen SELECT; operaciones pasa por es_despachador)
drop policy if exists docs_vehiculos_sel_auditor on storage.objects;
create policy docs_vehiculos_sel_auditor on storage.objects
  for select to authenticated
  using ( bucket_id = 'docs-vehiculos' and public.es_auditor() );
