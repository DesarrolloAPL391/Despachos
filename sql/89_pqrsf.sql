-- ============================================================================================
-- 89) PQRSF: peticiones, quejas, reclamos, sugerencias y felicitaciones
--
-- Las PQRSF se radican hoy en AppSheet y viven en una hoja de Google publicada como CSV. Aquí
-- se traen a la base para consultarlas, medirlas y cruzarlas con el resto del sistema. La
-- radicación sigue donde está: este módulo NO reemplaza el formulario, lo lee.
--
-- Igual que con los siniestros (sql/79): la app baja el CSV, interpreta cada fila y la manda a
-- `pqrsf_cargar`. La llave es la `KEY` de AppSheet, así que volver a cargar actualiza lo que
-- cambió y no duplica nada. De cada fila se guarda además `datos_origen` con el CSV completo
-- tal como venía, para no perder ninguna columna aunque aquí no se use.
--
-- LO QUE SE CALCULA, en vez de creerle al archivo:
--   La hoja trae una columna "CUMPLIMIENTO" con cinco valores que se pisan entre sí (DESTIEMPO
--   y "RESPUESTA FUERA DE TIEMPO LIMITE" son lo mismo; OPORTUNO y CUMPLIO también) y que además
--   se contradice con la de envío: hay 89 filas marcadas CUMPLIO que dicen SIN RESPUESTA. Por
--   eso se conserva tal cual en `cumplimiento_origen` —para poder auditarla— pero el
--   cumplimiento que usan las pantallas se calcula con las fechas: si respondió después de la
--   fecha límite, es fuera de plazo. Sobre 2.516 PQRSF con las dos fechas, 1.399 (56%) salieron
--   tarde; el promedio de respuesta son 10,5 días y la mediana 6.
--
-- QUIÉN LA VE: administración, Gestión Humana, auditoría y las cuentas que radican (servicio al
-- cliente). Estas últimas se listan en `pqrsf_acceso`, que se crea VACÍA a propósito: los
-- correos se agregan aparte, porque este archivo vive en un repositorio público.
-- ============================================================================================

-- 1) La tabla -------------------------------------------------------------------------------
create table if not exists public.pqrsf (
  key                      text primary key,          -- KEY de AppSheet
  radicado                 text,                      -- "RADICADO # 1234"
  fecha_radicado           date,
  hora_recibido            time,
  -- vehículo al que se refiere la PQRSF (no todas traen uno)
  placa                    text,
  numero_interno           text,
  ruta                     text,
  propietario              text,
  identificacion           text,
  -- el suceso
  fecha_suceso             date,
  hora_suceso              time,
  direccion_suceso         text,
  descripcion              text,
  -- quién la puso
  usuario_nombre           text,
  usuario_correo           text,
  usuario_telefono         text,
  medio_recibido           text,                      -- TELEFONICO, CORREO, WHATSAAP, PAGINA WEB, PRESENCIAL
  -- clasificación
  tipo                     text,                      -- QUEJA, PETICION, RECLAMO, FELICITACION, SUGERENCIA
  motivo                   text,
  urgencia                 text,
  respuesta_personalizada  boolean,
  pruebas                  text,                      -- adjunto: sigue en AppSheet
  -- gestión
  responsable_radicacion   text,
  responsable_destino      text,
  respuesta                text,
  estado                   text,                      -- ABIERTA / CERRADA
  fecha_limite             date,
  fecha_respuesta          date,
  cumplimiento_origen      text,                      -- la columna del archivo, tal cual
  estado_envio             text,
  respuesta_servidor       text,
  -- proceso disciplinario al conductor, cuando lo hubo
  requiere_proceso         boolean,
  revision                 text,
  observaciones_correccion text,
  responsable_descargos    text,
  informe_tecnico          text,
  fecha_proceso            date,
  consecutivo_proceso      text,
  decision_final           text,
  estado_descargos         text,
  observacion              text,
  fecha_limite_descargos   date,
  -- quién manejaba: se resuelve después contra el viaje real (queda listo para eso)
  conductor                text,
  conductor_cedula         text,
  conductor_codigo         text,
  -- lo que se calcula con las fechas, no con la columna del archivo
  dias_respuesta integer generated always as (
    case when fecha_respuesta is not null and fecha_radicado is not null
         then fecha_respuesta - fecha_radicado end) stored,
  cumplimiento text generated always as (
    case when fecha_respuesta is null                then 'SIN RESPUESTA'
         when fecha_limite   is null                 then 'SIN PLAZO'
         when fecha_respuesta <= fecha_limite        then 'A TIEMPO'
         else                                             'FUERA DE PLAZO' end) stored,
  anio int generated always as (extract(year from fecha_radicado)::int) stored,
  datos_origen             jsonb,                     -- el CSV completo de esa fila
  creado_en                timestamptz not null default now(),
  actualizado_en           timestamptz not null default now()
);

comment on table  public.pqrsf is 'PQRSF radicadas en AppSheet, traidas desde la hoja publicada. La radicacion NO se hace aqui.';
comment on column public.pqrsf.cumplimiento is 'Calculado con las fechas: A TIEMPO / FUERA DE PLAZO / SIN RESPUESTA / SIN PLAZO.';
comment on column public.pqrsf.cumplimiento_origen is 'La columna CUMPLIMIENTO de la hoja, tal cual: se conserva para auditarla, no para medir.';

create index if not exists pqrsf_fecha_idx        on public.pqrsf (fecha_radicado desc);
create index if not exists pqrsf_tipo_idx         on public.pqrsf (tipo, fecha_radicado desc);
create index if not exists pqrsf_motivo_idx       on public.pqrsf (motivo, fecha_radicado desc);
create index if not exists pqrsf_ruta_idx         on public.pqrsf (ruta, fecha_radicado desc);
create index if not exists pqrsf_movil_idx        on public.pqrsf (numero_interno, fecha_radicado desc);
create index if not exists pqrsf_cumplimiento_idx on public.pqrsf (cumplimiento, fecha_radicado desc);
create index if not exists pqrsf_estado_idx       on public.pqrsf (estado, fecha_radicado desc);
create index if not exists pqrsf_cedula_idx       on public.pqrsf (conductor_cedula) where conductor_cedula is not null;

create or replace function public.pqrsf_antes_guardar()
returns trigger language plpgsql as $$
begin
  new.actualizado_en := now();
  return new;
end $$;
drop trigger if exists pqrsf_tg_guardar on public.pqrsf;
create trigger pqrsf_tg_guardar before update on public.pqrsf
  for each row execute function public.pqrsf_antes_guardar();

-- 2) De dónde se trae -------------------------------------------------------------------------
create table if not exists public.pqrsf_fuente (
  id             int primary key default 1,
  url            text not null,
  nota           text,
  ultima_carga   timestamptz,
  ultimo_total   int,
  actualizado_en timestamptz not null default now(),
  constraint pqrsf_fuente_una_fila check (id = 1)
);
comment on table public.pqrsf_fuente is 'Enlace CSV publicado de la hoja de PQRSF. El enlace NO va en el codigo.';

-- 3) Quién puede verlas -----------------------------------------------------------------------
--    Además de administración, Gestión Humana y auditoría, las cuentas de servicio al cliente
--    que radican. Se agregan por correo en esta tabla (queda vacía: los correos se cargan aparte).
create table if not exists public.pqrsf_acceso (
  email     text primary key,
  nota      text,
  creado_en timestamptz not null default now()
);
comment on table public.pqrsf_acceso is 'Correos de servicio al cliente con acceso a PQRSF. Se llena aparte: este archivo es publico.';

create or replace function public.es_pqrsf()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_admin()
      or public.es_gestion_humana()
      or public.es_auditor()
      or exists (select 1 from public.pqrsf_acceso a
                 where lower(a.email) = lower(coalesce(auth.email(), '')));
$$;
revoke all on function public.es_pqrsf() from public, anon;
grant execute on function public.es_pqrsf() to authenticated;

-- Quien además puede TRAER la hoja (auditoría solo mira)
create or replace function public.es_pqrsf_editor()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_admin()
      or public.es_gestion_humana()
      or exists (select 1 from public.pqrsf_acceso a
                 where lower(a.email) = lower(coalesce(auth.email(), '')));
$$;
revoke all on function public.es_pqrsf_editor() from public, anon;
grant execute on function public.es_pqrsf_editor() to authenticated;

-- 4) Permisos: la tabla es de solo lectura; todo lo que escribe pasa por las RPC --------------
alter table public.pqrsf        enable row level security;
alter table public.pqrsf_fuente enable row level security;
alter table public.pqrsf_acceso enable row level security;

drop policy if exists pqrsf_ver on public.pqrsf;
create policy pqrsf_ver on public.pqrsf
  for select to authenticated using ((select public.es_pqrsf()));

drop policy if exists pqrsf_fuente_ver on public.pqrsf_fuente;
create policy pqrsf_fuente_ver on public.pqrsf_fuente
  for select to authenticated using ((select public.es_pqrsf_editor()));

drop policy if exists pqrsf_acceso_admin on public.pqrsf_acceso;
create policy pqrsf_acceso_admin on public.pqrsf_acceso
  for all to authenticated
  using ((select public.es_admin())) with check ((select public.es_admin()));

revoke all on public.pqrsf        from public, anon;
revoke all on public.pqrsf_fuente from public, anon;
revoke all on public.pqrsf_acceso from public, anon;
grant select on public.pqrsf        to authenticated;
grant select on public.pqrsf_fuente to authenticated;
grant select, insert, update, delete on public.pqrsf_acceso to authenticated;

-- 5) Carga desde la app ------------------------------------------------------------------------
--    Recibe las filas ya interpretadas (la app lee el CSV y arma los tipos) y hace upsert por
--    `key`. Devuelve cuántas quedaron nuevas y cuántas se actualizaron.
create or replace function public.pqrsf_cargar(p_filas jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_nuevos int := 0; v_act int := 0; v_total int;
begin
  if not public.es_pqrsf_editor() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para traer las PQRSF.');
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'No llegaron filas.');
  end if;

  with datos as (
    select
      nullif(trim(f->>'key'), '')                     as key,
      nullif(trim(f->>'radicado'), '')                as radicado,
      nullif(f->>'fecha_radicado', '')::date          as fecha_radicado,
      nullif(f->>'hora_recibido', '')::time           as hora_recibido,
      nullif(trim(f->>'placa'), '')                   as placa,
      nullif(trim(f->>'numero_interno'), '')          as numero_interno,
      nullif(trim(f->>'ruta'), '')                    as ruta,
      nullif(trim(f->>'propietario'), '')             as propietario,
      nullif(trim(f->>'identificacion'), '')          as identificacion,
      nullif(f->>'fecha_suceso', '')::date            as fecha_suceso,
      nullif(f->>'hora_suceso', '')::time             as hora_suceso,
      nullif(trim(f->>'direccion_suceso'), '')        as direccion_suceso,
      nullif(trim(f->>'descripcion'), '')             as descripcion,
      nullif(trim(f->>'usuario_nombre'), '')          as usuario_nombre,
      nullif(trim(f->>'usuario_correo'), '')          as usuario_correo,
      nullif(trim(f->>'usuario_telefono'), '')        as usuario_telefono,
      nullif(trim(f->>'medio_recibido'), '')          as medio_recibido,
      nullif(trim(f->>'tipo'), '')                    as tipo,
      nullif(trim(f->>'motivo'), '')                  as motivo,
      nullif(trim(f->>'urgencia'), '')                as urgencia,
      case lower(coalesce(f->>'respuesta_personalizada', ''))
           when 'true' then true when 'false' then false else null end as respuesta_personalizada,
      nullif(trim(f->>'pruebas'), '')                 as pruebas,
      nullif(trim(f->>'responsable_radicacion'), '')  as responsable_radicacion,
      nullif(trim(f->>'responsable_destino'), '')     as responsable_destino,
      nullif(trim(f->>'respuesta'), '')               as respuesta,
      nullif(trim(f->>'estado'), '')                  as estado,
      nullif(f->>'fecha_limite', '')::date            as fecha_limite,
      nullif(f->>'fecha_respuesta', '')::date         as fecha_respuesta,
      nullif(trim(f->>'cumplimiento_origen'), '')     as cumplimiento_origen,
      nullif(trim(f->>'estado_envio'), '')            as estado_envio,
      nullif(trim(f->>'respuesta_servidor'), '')      as respuesta_servidor,
      case lower(coalesce(f->>'requiere_proceso', ''))
           when 'true' then true when 'false' then false else null end as requiere_proceso,
      nullif(trim(f->>'revision'), '')                as revision,
      nullif(trim(f->>'observaciones_correccion'), '') as observaciones_correccion,
      nullif(trim(f->>'responsable_descargos'), '')   as responsable_descargos,
      nullif(trim(f->>'informe_tecnico'), '')         as informe_tecnico,
      nullif(f->>'fecha_proceso', '')::date           as fecha_proceso,
      nullif(trim(f->>'consecutivo_proceso'), '')     as consecutivo_proceso,
      nullif(trim(f->>'decision_final'), '')          as decision_final,
      nullif(trim(f->>'estado_descargos'), '')        as estado_descargos,
      nullif(trim(f->>'observacion'), '')             as observacion,
      nullif(f->>'fecha_limite_descargos', '')::date  as fecha_limite_descargos,
      case when jsonb_typeof(f->'datos_origen') = 'object' then f->'datos_origen' else null end as datos_origen
    from jsonb_array_elements(p_filas) f
    where nullif(trim(f->>'key'), '') is not null
  ),
  guardado as (
    insert into public.pqrsf as p (
      key, radicado, fecha_radicado, hora_recibido, placa, numero_interno, ruta, propietario,
      identificacion, fecha_suceso, hora_suceso, direccion_suceso, descripcion, usuario_nombre,
      usuario_correo, usuario_telefono, medio_recibido, tipo, motivo, urgencia,
      respuesta_personalizada, pruebas, responsable_radicacion, responsable_destino, respuesta,
      estado, fecha_limite, fecha_respuesta, cumplimiento_origen, estado_envio, respuesta_servidor,
      requiere_proceso, revision, observaciones_correccion, responsable_descargos, informe_tecnico,
      fecha_proceso, consecutivo_proceso, decision_final, estado_descargos, observacion,
      fecha_limite_descargos, datos_origen)
    select
      d.key, d.radicado, d.fecha_radicado, d.hora_recibido, d.placa, d.numero_interno, d.ruta,
      d.propietario, d.identificacion, d.fecha_suceso, d.hora_suceso, d.direccion_suceso,
      d.descripcion, d.usuario_nombre, d.usuario_correo, d.usuario_telefono, d.medio_recibido,
      d.tipo, d.motivo, d.urgencia, d.respuesta_personalizada, d.pruebas, d.responsable_radicacion,
      d.responsable_destino, d.respuesta, d.estado, d.fecha_limite, d.fecha_respuesta,
      d.cumplimiento_origen, d.estado_envio, d.respuesta_servidor, d.requiere_proceso, d.revision,
      d.observaciones_correccion, d.responsable_descargos, d.informe_tecnico, d.fecha_proceso,
      d.consecutivo_proceso, d.decision_final, d.estado_descargos, d.observacion,
      d.fecha_limite_descargos, d.datos_origen
    from datos d
    on conflict (key) do update set
      radicado = excluded.radicado, fecha_radicado = excluded.fecha_radicado,
      hora_recibido = excluded.hora_recibido, placa = excluded.placa,
      numero_interno = excluded.numero_interno, ruta = excluded.ruta,
      propietario = excluded.propietario, identificacion = excluded.identificacion,
      fecha_suceso = excluded.fecha_suceso, hora_suceso = excluded.hora_suceso,
      direccion_suceso = excluded.direccion_suceso, descripcion = excluded.descripcion,
      usuario_nombre = excluded.usuario_nombre, usuario_correo = excluded.usuario_correo,
      usuario_telefono = excluded.usuario_telefono, medio_recibido = excluded.medio_recibido,
      tipo = excluded.tipo, motivo = excluded.motivo, urgencia = excluded.urgencia,
      respuesta_personalizada = excluded.respuesta_personalizada, pruebas = excluded.pruebas,
      responsable_radicacion = excluded.responsable_radicacion,
      responsable_destino = excluded.responsable_destino, respuesta = excluded.respuesta,
      estado = excluded.estado, fecha_limite = excluded.fecha_limite,
      fecha_respuesta = excluded.fecha_respuesta, cumplimiento_origen = excluded.cumplimiento_origen,
      estado_envio = excluded.estado_envio, respuesta_servidor = excluded.respuesta_servidor,
      requiere_proceso = excluded.requiere_proceso, revision = excluded.revision,
      observaciones_correccion = excluded.observaciones_correccion,
      responsable_descargos = excluded.responsable_descargos,
      informe_tecnico = excluded.informe_tecnico, fecha_proceso = excluded.fecha_proceso,
      consecutivo_proceso = excluded.consecutivo_proceso, decision_final = excluded.decision_final,
      estado_descargos = excluded.estado_descargos, observacion = excluded.observacion,
      fecha_limite_descargos = excluded.fecha_limite_descargos,
      datos_origen = excluded.datos_origen
    returning (xmax = 0) as es_nuevo
  )
  select count(1) filter (where es_nuevo), count(1) filter (where not es_nuevo)
    into v_nuevos, v_act
  from guardado;

  select count(1) into v_total from public.pqrsf;
  update public.pqrsf_fuente set ultima_carga = now(), ultimo_total = v_total, actualizado_en = now()
   where id = 1;

  return jsonb_build_object('ok', true, 'nuevos', coalesce(v_nuevos, 0),
                            'actualizados', coalesce(v_act, 0), 'total', v_total);
end $$;
revoke all on function public.pqrsf_cargar(jsonb) from public, anon;
grant execute on function public.pqrsf_cargar(jsonb) to authenticated;

-- 6) Estado del módulo (la pantalla lo usa para el botón de traer) ------------------------------
create or replace function public.pqrsf_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_pqrsf() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_cargar', public.es_pqrsf_editor(),
      'url',          (select url from public.pqrsf_fuente where id = 1),
      'ultima_carga', (select ultima_carga from public.pqrsf_fuente where id = 1),
      'total',        (select count(1) from public.pqrsf),
      'desde',        (select min(fecha_radicado) from public.pqrsf),
      'hasta',        (select max(fecha_radicado) from public.pqrsf),
      'abiertas',     (select count(1) from public.pqrsf where estado = 'ABIERTA'),
      'sin_respuesta',(select count(1) from public.pqrsf where cumplimiento = 'SIN RESPUESTA'),
      'fuera_plazo',  (select count(1) from public.pqrsf where cumplimiento = 'FUERA DE PLAZO'))
  end;
$$;
revoke all on function public.pqrsf_estado() from public, anon;
grant execute on function public.pqrsf_estado() to authenticated;

-- 7) El enlace de la hoja y los correos de servicio al cliente van APARTE, no en este archivo:
--    insert into public.pqrsf_fuente (id, url, nota) values (1, '<enlace CSV publicado>', 'Hoja PQRSF')
--      on conflict (id) do update set url = excluded.url, actualizado_en = now();
--    insert into public.pqrsf_acceso (email, nota) values ('<correo>', 'Servicio al cliente')
--      on conflict (email) do nothing;
