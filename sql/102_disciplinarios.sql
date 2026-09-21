-- ============================================================================================
-- 102) PROCESOS DISCIPLINARIOS
--
-- QUÉ RESUELVE: la hoja tiene 2.660 procesos desde 2020 en 134 columnas, de las cuales la mitad
-- es andamiaje de AppSheet (textos ya armados para las plantillas, campos de calendario
-- repetidos, control de correo y 20 columnas de testigos que casi nunca se llenan). Con eso
-- encima, lo importante no se ve: 1.503 procesos figuran "EN PROCESO" y 1.467 de ellos son de
-- hace más de 60 días. No hay 1.500 procesos vivos — hay procesos que nadie cerró.
--
-- CÓMO QUEDA: se guardan los ~32 campos con los que de verdad se gestiona, y la ETAPA se
-- CALCULA a partir de las fechas que ya existen, en vez de escribirse a mano:
--   POR CITAR → CITADO → POR DECIDIR (ya hubo descargos) → CON SANCION / SIN SANCION
-- Así "EN PROCESO" se abre solo y se ve dónde quedó frenado cada uno.
--
-- LA FALTA se guarda tal como viene Y agrupada: las 25 formas de escribirla son ~10 causas
-- ("NO LABORAR-NO LABORAR TURNOS" y "NO LABORAR/NO LABORAR TURNOS/.../ENTRE OTROS" son la
-- misma). El texto original nunca se toca; el grupo es lo que permite medir.
--
-- QUIÉN ENTRA: Gestión Humana y administración llevan el proceso; Gerencia consulta; el auditor
-- solo REPORTA el hecho (por RPC, sin leer la tabla: no tiene por qué ver sanciones ajenas).
--
-- EL ENLACE de la hoja NO va en el código — este repositorio es público. Vive en
-- disciplinarios_fuente, detrás de RLS, igual que en sql/79 (siniestros) y sql/89 (PQRSF).
-- ============================================================================================

-- 1) La tabla -------------------------------------------------------------------------------
create table if not exists public.disciplinarios (
  id                bigserial primary key,
  key_origen        text unique,            -- KEY de la hoja: por ahí se reconoce al re-traer
  radicado          int,
  -- Quién
  cedula            text,
  nombre            text,
  cargo             text,
  tipo_persona      text,                   -- CONDUCTOR / ADMINISTRATIVO / ...
  afiliado          text,
  vehiculo          text,
  ruta              text,
  placa             text,
  -- El hecho
  fecha_suceso      date,
  fecha_suceso_fin  date,
  hora_suceso       time,
  novedad           text,                   -- el relato de lo que pasó
  reporta_correo    text,
  fecha_informe     date,
  -- La citación a descargos
  citacion_enviada  date,
  citacion_fecha    date,
  citacion_hora     time,
  citacion_responsable text,
  citacion_estado   text,                   -- FIRMADO / ILOCALIZADO / SE NIEGA A FIRMAR
  motivo_descargos  text,
  -- La diligencia
  descargo_fecha    date,
  descargo_hora_ini time,
  descargo_hora_fin time,
  -- La decisión
  falta             text,                   -- tal como se escribió
  falta_grupo       text,                   -- la misma, agrupada, para poder medir
  sancion           text,
  sancion_dias      numeric,
  sancion_unidad    text,                   -- DIAS / MESES
  suspension_ini    date,
  suspension_fin    date,
  sancion_respuesta date,
  sancion_enviada   date,
  -- Control
  estado_hoja       text,                   -- ESTADO DEL PROCESO como venía (CANCELADO, REPROGRAMAR…)
  observacion       text,
  anulado_en        timestamptz,
  anulado_por       text,
  nota_anulacion    text,
  origen            text not null default 'APP',   -- APP | HOJA | REPORTE
  creado_en         timestamptz not null default now(),
  creado_por        text,
  creado_nombre     text,
  actualizado_en    timestamptz not null default now(),
  -- La etapa se calcula: es lo que las fechas ya dicen, no lo que alguien se acordó de escribir
  etapa text generated always as (
    case when anulado_en is not null                              then 'ANULADO'
         when upper(coalesce(estado_hoja, '')) like 'CANCELADO%'  then 'CANCELADO'
         when upper(coalesce(estado_hoja, '')) like 'REPROGRAMAR%' then 'REPROGRAMAR'
         when sancion is not null and upper(sancion) like 'NO GENERA%' then 'SIN SANCION'
         when sancion is not null and upper(sancion) not like 'PENDIENTE%' then 'CON SANCION'
         when descargo_fecha is not null                          then 'POR DECIDIR'
         when citacion_fecha is not null                          then 'CITADO'
         else 'POR CITAR' end) stored
);
create index if not exists disc_fecha_idx  on public.disciplinarios (fecha_suceso desc);
create index if not exists disc_etapa_idx  on public.disciplinarios (etapa, fecha_suceso desc);
create index if not exists disc_cedula_idx on public.disciplinarios (cedula, fecha_suceso desc);

comment on table public.disciplinarios is
  'Procesos disciplinarios. La etapa se calcula de las fechas; la falta se guarda literal y agrupada.';

-- 2) De dónde se traen (el enlace NO va en el código: este repo es público) --------------------
create table if not exists public.disciplinarios_fuente (
  id             int primary key default 1,
  url            text not null,
  nota           text,
  ultima_carga   timestamptz,
  ultimo_total   int,
  actualizado_en timestamptz not null default now(),
  constraint disciplinarios_fuente_una_fila check (id = 1)
);
comment on table public.disciplinarios_fuente is
  'Enlace CSV publicado de la hoja de procesos disciplinarios. Solo admin y Gestion Humana.';

-- 3) Quién entra ------------------------------------------------------------------------------
-- Gestión Humana y administración llevan el proceso.
create or replace function public.es_disc_gestion()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_talento_humano(); $$;
revoke all on function public.es_disc_gestion() from public, anon;
grant execute on function public.es_disc_gestion() to authenticated;

-- Gerencia (las mismas cuentas que firman los permisos, sql/97) solo consulta.
create or replace function public.es_disc_ver()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_talento_humano() or public.es_permiso_gerencia(); $$;
revoke all on function public.es_disc_ver() from public, anon;
grant execute on function public.es_disc_ver() to authenticated;

alter table public.disciplinarios        enable row level security;
alter table public.disciplinarios_fuente enable row level security;

drop policy if exists disc_ver on public.disciplinarios;
create policy disc_ver on public.disciplinarios for select to authenticated
  using ((select public.es_disc_ver()));
-- Sin políticas de escritura: se entra por las funciones, que sellan quién hizo qué.
-- El auditor NO lee esta tabla: reporta por RPC y ve solo lo suyo.

drop policy if exists disc_fuente_th on public.disciplinarios_fuente;
create policy disc_fuente_th on public.disciplinarios_fuente for all to authenticated
  using ((select public.es_disc_gestion())) with check ((select public.es_disc_gestion()));

revoke all on public.disciplinarios        from public, anon;
revoke all on public.disciplinarios_fuente from public, anon;
grant select on public.disciplinarios to authenticated;
grant select, insert, update on public.disciplinarios_fuente to authenticated;
revoke all on sequence public.disciplinarios_id_seq from public, anon;

-- 4) La falta, agrupada -------------------------------------------------------------------------
-- El texto original no se toca nunca. Esto es solo para poder contar: hoy hay 25 formas de
-- escribir lo mismo ("NO LABORAR-NO LABORAR TURNOS" vs "NO LABORAR/.../ENTRE OTROS").
create or replace function public.disc_falta_grupo(p_falta text)
returns text language sql immutable
as $$
  with t as (select upper(translate(coalesce(p_falta, ''), 'ÁÉÍÓÚÜÑ', 'AEIOUUN')) as f)
  select case
    when (select f from t) = '' then null
    when (select f from t) like '%NO LABORAR%'            then 'No laborar / no cubrir turnos'
    when (select f from t) like '%OBLIGACIONES CONTRACTUALES%' then 'Incumplir obligaciones'
    when (select f from t) like '%TAMIZAJE%'              then 'Tamizaje positivo'
    when (select f from t) like '%GUERREO%' or (select f from t) like '%RINA%'
      or (select f from t) like '%INCONVENIENTE COMPANEROS%' then 'Guerreo / riñas'
    when (select f from t) like '%LIQUIDAR%' or (select f from t) like '%CONSIGNACION%' then 'No liquidar / no consignar'
    when (select f from t) like '%MANIPULACI%'            then 'Manipular el sistema de control'
    when (select f from t) like '%COMPARENDO%' or (select f from t) like '%INFRACCI%'
      or (select f from t) like '%COLISI%'                then 'Comparendos / infracciones'
    when (select f from t) like '%EVASI%'                 then 'Evasión de pasajeros'
    when (select f from t) like '%PQR%'                   then 'PQRSF / mal servicio'
    when (select f from t) like '%TRAZADO%' or (select f from t) like '%VELOCIDAD%'
      or (select f from t) like '%ABANDONO DE RUTA%' or (select f from t) like '%VOLTEO%' then 'Trazado / velocidad / abandono'
    when (select f from t) like '%DESPACHO%' or (select f from t) like '%APLICACI%' then 'Mal despacho / error de aplicación'
    when (select f from t) like '%HURTO%' or (select f from t) like '%ENGANO%'
      or (select f from t) like '%ADULTERACION%'          then 'Engaño / hurto'
    when (select f from t) like 'NO APLICA%'              then 'No aplica'
    else 'Otras' end;
$$;
revoke all on function public.disc_falta_grupo(text) from public, anon;
grant execute on function public.disc_falta_grupo(text) to authenticated;

-- 5) Traer de la hoja ---------------------------------------------------------------------------
--    La app lee el CSV (el enlace sale de disciplinarios_fuente), lo interpreta y manda las filas
--    por lotes. Se reconoce por KEY: re-traer actualiza, no duplica.
create or replace function public.disciplinarios_cargar(p_filas jsonb)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_nuevos int := 0; v_upd int := 0; v_key text; v_existe boolean;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y Gestion Humana cargan los procesos.');
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'Se esperaba una lista de filas.');
  end if;

  for v_key in select f ->> 'key_origen' from jsonb_array_elements(p_filas) f loop
    if coalesce(trim(v_key), '') = '' then continue; end if;
    select exists(select 1 from public.disciplinarios where key_origen = v_key) into v_existe;
    if v_existe then v_upd := v_upd + 1; else v_nuevos := v_nuevos + 1; end if;
  end loop;

  insert into public.disciplinarios as d (
    key_origen, radicado, cedula, nombre, cargo, tipo_persona, afiliado, vehiculo, ruta, placa,
    fecha_suceso, fecha_suceso_fin, hora_suceso, novedad, reporta_correo, fecha_informe,
    citacion_enviada, citacion_fecha, citacion_hora, citacion_responsable, citacion_estado,
    motivo_descargos, descargo_fecha, descargo_hora_ini, descargo_hora_fin,
    falta, falta_grupo, sancion, sancion_dias, sancion_unidad,
    suspension_ini, suspension_fin, sancion_respuesta, sancion_enviada,
    estado_hoja, observacion, origen)
  select
    f ->> 'key_origen', nullif(f ->> 'radicado', '')::int,
    f ->> 'cedula', f ->> 'nombre', f ->> 'cargo', f ->> 'tipo_persona', f ->> 'afiliado',
    f ->> 'vehiculo', f ->> 'ruta', f ->> 'placa',
    nullif(f ->> 'fecha_suceso', '')::date, nullif(f ->> 'fecha_suceso_fin', '')::date,
    nullif(f ->> 'hora_suceso', '')::time, f ->> 'novedad', f ->> 'reporta_correo',
    nullif(f ->> 'fecha_informe', '')::date,
    nullif(f ->> 'citacion_enviada', '')::date, nullif(f ->> 'citacion_fecha', '')::date,
    nullif(f ->> 'citacion_hora', '')::time, f ->> 'citacion_responsable', f ->> 'citacion_estado',
    f ->> 'motivo_descargos',
    nullif(f ->> 'descargo_fecha', '')::date, nullif(f ->> 'descargo_hora_ini', '')::time,
    nullif(f ->> 'descargo_hora_fin', '')::time,
    f ->> 'falta', public.disc_falta_grupo(f ->> 'falta'),
    nullif(f ->> 'sancion', ''), nullif(f ->> 'sancion_dias', '')::numeric, f ->> 'sancion_unidad',
    nullif(f ->> 'suspension_ini', '')::date, nullif(f ->> 'suspension_fin', '')::date,
    nullif(f ->> 'sancion_respuesta', '')::date, nullif(f ->> 'sancion_enviada', '')::date,
    f ->> 'estado_hoja', f ->> 'observacion', 'HOJA'
  from jsonb_array_elements(p_filas) f
  where coalesce(trim(f ->> 'key_origen'), '') <> ''
  on conflict (key_origen) do update set
    radicado = excluded.radicado, cedula = excluded.cedula, nombre = excluded.nombre,
    cargo = excluded.cargo, tipo_persona = excluded.tipo_persona, afiliado = excluded.afiliado,
    vehiculo = excluded.vehiculo, ruta = excluded.ruta, placa = excluded.placa,
    fecha_suceso = excluded.fecha_suceso, fecha_suceso_fin = excluded.fecha_suceso_fin,
    hora_suceso = excluded.hora_suceso, novedad = excluded.novedad,
    reporta_correo = excluded.reporta_correo, fecha_informe = excluded.fecha_informe,
    citacion_enviada = excluded.citacion_enviada, citacion_fecha = excluded.citacion_fecha,
    citacion_hora = excluded.citacion_hora, citacion_responsable = excluded.citacion_responsable,
    citacion_estado = excluded.citacion_estado, motivo_descargos = excluded.motivo_descargos,
    descargo_fecha = excluded.descargo_fecha, descargo_hora_ini = excluded.descargo_hora_ini,
    descargo_hora_fin = excluded.descargo_hora_fin,
    falta = excluded.falta, falta_grupo = excluded.falta_grupo, sancion = excluded.sancion,
    sancion_dias = excluded.sancion_dias, sancion_unidad = excluded.sancion_unidad,
    suspension_ini = excluded.suspension_ini, suspension_fin = excluded.suspension_fin,
    sancion_respuesta = excluded.sancion_respuesta, sancion_enviada = excluded.sancion_enviada,
    estado_hoja = excluded.estado_hoja, observacion = excluded.observacion,
    actualizado_en = now();

  update public.disciplinarios_fuente
     set ultima_carga = now(),
         ultimo_total = (select count(1) from public.disciplinarios),
         actualizado_en = now()
   where id = 1;

  return jsonb_build_object('ok', true, 'nuevos', v_nuevos, 'actualizados', v_upd,
                            'total', (select count(1) from public.disciplinarios));
end $$;
revoke all on function public.disciplinarios_cargar(jsonb) from public, anon;
grant execute on function public.disciplinarios_cargar(jsonb) to authenticated;

-- 6) Gestionar el proceso ------------------------------------------------------------------------
-- Abrir (o corregir) el hecho.
create or replace function public.disc_guardar(
  p_id bigint, p_cedula text, p_fecha_suceso date, p_hora_suceso time, p_novedad text,
  p_vehiculo text default null, p_ruta text default null, p_observacion text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_quien text; v_nombre text; v_pnom text; v_pcargo text; v_ptipo text;
        v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y Gestion Humana abren un proceso.');
  end if;
  if v_ced = '' or p_fecha_suceso is null or coalesce(trim(p_novedad), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta la cedula, la fecha del suceso o el relato.');
  end if;
  select email, nombre into v_quien, v_nombre from (
    select u.email, pf.nombre from auth.users u
    left join public.perfiles pf on pf.id = u.id where u.id = auth.uid()) s;
  -- Los datos de la persona salen del perfil: no se vuelven a escribir a mano
  select nombre, cargo, tipo into v_pnom, v_pcargo, v_ptipo
    from public.perfilsociodemografico where cedula = v_ced limit 1;

  if p_id is null then
    insert into public.disciplinarios
      (cedula, nombre, cargo, tipo_persona, vehiculo, ruta, fecha_suceso, hora_suceso,
       novedad, observacion, reporta_correo, fecha_informe, origen, creado_por, creado_nombre)
    values (v_ced, v_pnom, v_pcargo, upper(coalesce(v_ptipo, '')), nullif(trim(coalesce(p_vehiculo, '')), ''),
            nullif(trim(coalesce(p_ruta, '')), ''), p_fecha_suceso, p_hora_suceso,
            trim(p_novedad), nullif(trim(coalesce(p_observacion, '')), ''), v_quien,
            (now() at time zone 'America/Bogota')::date, 'APP', v_quien, coalesce(v_nombre, v_quien))
    returning id into v_id;
  else
    update public.disciplinarios
       set cedula = v_ced, nombre = coalesce(v_pnom, nombre), cargo = coalesce(v_pcargo, cargo),
           fecha_suceso = p_fecha_suceso, hora_suceso = p_hora_suceso, novedad = trim(p_novedad),
           vehiculo = nullif(trim(coalesce(p_vehiculo, '')), ''), ruta = nullif(trim(coalesce(p_ruta, '')), ''),
           observacion = nullif(trim(coalesce(p_observacion, '')), ''), actualizado_en = now()
     where id = p_id and anulado_en is null
    returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'No se encontro ese proceso (o esta anulado).'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.disc_guardar(bigint, text, date, time, text, text, text, text) from public, anon;
grant execute on function public.disc_guardar(bigint, text, date, time, text, text, text, text) to authenticated;

-- Citar a descargos.
create or replace function public.disc_citar(
  p_id bigint, p_fecha date, p_hora time, p_responsable text default null,
  p_estado text default null, p_enviada date default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y Gestion Humana citan a descargos.');
  end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Falta la fecha de la diligencia.'); end if;
  update public.disciplinarios
     set citacion_fecha = p_fecha, citacion_hora = p_hora,
         citacion_responsable = nullif(trim(coalesce(p_responsable, '')), ''),
         citacion_estado = nullif(upper(trim(coalesce(p_estado, ''))), ''),
         citacion_enviada = coalesce(p_enviada, citacion_enviada, (now() at time zone 'America/Bogota')::date),
         estado_hoja = null,                 -- si venía "REPROGRAMAR", ya se reprogramó
         actualizado_en = now()
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro ese proceso (o esta anulado).'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.disc_citar(bigint, date, time, text, text, date) from public, anon;
grant execute on function public.disc_citar(bigint, date, time, text, text, date) to authenticated;

-- Registrar la diligencia de descargos.
create or replace function public.disc_descargos(
  p_id bigint, p_fecha date, p_hora_ini time default null, p_hora_fin time default null,
  p_motivo text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y Gestion Humana registran los descargos.');
  end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Falta la fecha de la diligencia.'); end if;
  update public.disciplinarios
     set descargo_fecha = p_fecha, descargo_hora_ini = p_hora_ini, descargo_hora_fin = p_hora_fin,
         motivo_descargos = coalesce(nullif(trim(coalesce(p_motivo, '')), ''), motivo_descargos),
         actualizado_en = now()
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro ese proceso (o esta anulado).'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.disc_descargos(bigint, date, time, time, text) from public, anon;
grant execute on function public.disc_descargos(bigint, date, time, time, text) to authenticated;

-- Decidir: la falta y la sanción (o que no la hay).
create or replace function public.disc_sancionar(
  p_id bigint, p_falta text, p_sancion text, p_dias numeric default null,
  p_unidad text default null, p_ini date default null, p_fin date default null,
  p_enviada date default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y Gestion Humana aplican la sancion.');
  end if;
  if coalesce(trim(p_sancion), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta decir que sancion se aplica.');
  end if;
  update public.disciplinarios
     set falta = coalesce(nullif(trim(coalesce(p_falta, '')), ''), falta),
         falta_grupo = public.disc_falta_grupo(coalesce(nullif(trim(coalesce(p_falta, '')), ''), falta)),
         sancion = trim(p_sancion), sancion_dias = p_dias,
         sancion_unidad = nullif(upper(trim(coalesce(p_unidad, ''))), ''),
         suspension_ini = p_ini, suspension_fin = p_fin,
         sancion_enviada = coalesce(p_enviada, (now() at time zone 'America/Bogota')::date),
         actualizado_en = now()
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro ese proceso (o esta anulado).'); end if;
  return (select jsonb_build_object('ok', true, 'etapa', etapa) from public.disciplinarios where id = p_id);
end $$;
revoke all on function public.disc_sancionar(bigint, text, text, numeric, text, date, date, date) from public, anon;
grant execute on function public.disc_sancionar(bigint, text, text, numeric, text, date, date, date) to authenticated;

-- Anular (el proceso no iba). No se borra: queda el rastro.
create or replace function public.disc_anular(p_id bigint, p_nota text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_quien text;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y Gestion Humana anulan un proceso.');
  end if;
  select email into v_quien from auth.users where id = auth.uid();
  update public.disciplinarios
     set anulado_en = now(), anulado_por = v_quien,
         nota_anulacion = nullif(trim(coalesce(p_nota, '')), ''), actualizado_en = now()
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro ese proceso (o ya estaba anulado).'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.disc_anular(bigint, text) from public, anon;
grant execute on function public.disc_anular(bigint, text) to authenticated;

-- 7) El auditor REPORTA el hecho ------------------------------------------------------------------
--    No lee la tabla (no tiene por qué ver sanciones ajenas): entrega el hecho y ve lo suyo.
create or replace function public.disc_reportar(
  p_cedula text, p_fecha_suceso date, p_hora_suceso time, p_novedad text,
  p_vehiculo text default null, p_ruta text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_quien text; v_nombre text; v_pnom text; v_pcargo text; v_ptipo text;
        v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
begin
  if not (public.es_auditor() or public.es_disc_gestion()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para reportar.');
  end if;
  if v_ced = '' or p_fecha_suceso is null or coalesce(trim(p_novedad), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta la cedula, la fecha del suceso o el relato.');
  end if;
  if p_fecha_suceso > (now() at time zone 'America/Bogota')::date then
    return jsonb_build_object('ok', false, 'error', 'La fecha del suceso no puede ser futura.');
  end if;
  select email, nombre into v_quien, v_nombre from (
    select u.email, pf.nombre from auth.users u
    left join public.perfiles pf on pf.id = u.id where u.id = auth.uid()) s;
  select nombre, cargo, tipo into v_pnom, v_pcargo, v_ptipo
    from public.perfilsociodemografico where cedula = v_ced limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Esa cedula no esta en el perfil de personal.');
  end if;

  insert into public.disciplinarios
    (cedula, nombre, cargo, tipo_persona, vehiculo, ruta, fecha_suceso, hora_suceso, novedad,
     reporta_correo, fecha_informe, origen, creado_por, creado_nombre)
  values (v_ced, v_pnom, v_pcargo, upper(coalesce(v_ptipo, '')),
          nullif(trim(coalesce(p_vehiculo, '')), ''), nullif(trim(coalesce(p_ruta, '')), ''),
          p_fecha_suceso, p_hora_suceso, trim(p_novedad), v_quien,
          (now() at time zone 'America/Bogota')::date, 'REPORTE', v_quien, coalesce(v_nombre, v_quien))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.disc_reportar(text, date, time, text, text, text) from public, anon;
grant execute on function public.disc_reportar(text, date, time, text, text, text) to authenticated;

-- Lo que reportó QUIEN pregunta (sin falta ni sanción: eso no es asunto del auditor).
create or replace function public.disc_mis_reportes()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select case when not (public.es_auditor() or public.es_disc_gestion()) then jsonb_build_object('ok', false)
    else jsonb_build_object('ok', true, 'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'fecha_suceso', d.fecha_suceso, 'hora_suceso', d.hora_suceso,
        'novedad', d.novedad, 'vehiculo', d.vehiculo, 'ruta', d.ruta,
        'nombre', d.nombre, 'etapa', case when d.etapa in ('POR CITAR') then 'Recibido' else 'En tramite' end,
        'creado_en', d.creado_en) order by d.creado_en desc)
      from public.disciplinarios d
      where lower(coalesce(d.creado_por, '')) = lower(coalesce(auth.email(), ''))
        and d.creado_en > now() - interval '180 days'), '[]'::jsonb))
  end;
$$;
revoke all on function public.disc_mis_reportes() from public, anon;
grant execute on function public.disc_mis_reportes() to authenticated;

-- 8) Contadores para el menú y la pantalla ---------------------------------------------------------
create or replace function public.disciplinarios_estado()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select case when not (public.es_disc_ver() or public.es_auditor()) then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'gestiona',   public.es_disc_gestion(),
      'solo_ver',   public.es_disc_ver() and not public.es_disc_gestion(),
      'reporta',    public.es_auditor() and not public.es_disc_ver(),
      'total',      (select count(1) from public.disciplinarios),
      'desde',      (select min(fecha_suceso) from public.disciplinarios),
      'hasta',      (select max(fecha_suceso) from public.disciplinarios),
      'por_citar',  (select count(1) from public.disciplinarios where etapa = 'POR CITAR'),
      'citados',    (select count(1) from public.disciplinarios where etapa = 'CITADO'),
      'por_decidir',(select count(1) from public.disciplinarios where etapa = 'POR DECIDIR'),
      -- lo que lleva más de 60 días sin moverse: el trabajo represado
      'viejos',     (select count(1) from public.disciplinarios
                      where etapa in ('POR CITAR', 'CITADO', 'POR DECIDIR', 'REPROGRAMAR')
                        and fecha_suceso < (now() at time zone 'America/Bogota')::date - 60),
      'ultima_carga', (select ultima_carga from public.disciplinarios_fuente where id = 1),
      'url',        (select case when public.es_disc_gestion()
                                 then (select url from public.disciplinarios_fuente where id = 1) end))
  end;
$$;
revoke all on function public.disciplinarios_estado() from public, anon;
grant execute on function public.disciplinarios_estado() to authenticated;

-- 9) El aviso de ✨ Novedades también cuenta este módulo ---------------------------------------
--    Misma función de sql/99 y sql/101, con un bloque más. Sigue devolviendo solo conteos.
create or replace function public.novedades_estado()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  with c as (select * from public.certificado_config where id = 1),
       g as (select * from public.certificado_firmantes where rol = 'GERENTE' and vigente_hasta is null),
       h as (select * from public.certificado_firmantes where rol = 'GESTION_HUMANA' and vigente_hasta is null),
       hoy as (select (now() at time zone 'America/Bogota')::date as d)
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'cert', jsonb_build_object(
        'titular1',  coalesce((select nombre from g), (select firmante1_nombre from c), '') <> '',
        'titular2',  coalesce((select nombre from h), (select firmante2_nombre from c), '') <> '',
        'firma1',    coalesce((select firma from g), (select firmante1_firma from c), '') <> '',
        'firma2',    coalesce((select firma from h), (select firmante2_firma from c), '') <> '',
        'telefono',  coalesce((select telefono from c), '') <> '',
        'smmlv',     coalesce((select smmlv from c), 0) > 0,
        'auxilio',   coalesce((select auxilio_transporte from c), 0) > 0,
        'anio',      (select anio_valores from c),
        'anio_hoy',  extract(year from (select d from hoy))::int,
        'expedidos', (select count(1) from public.certificados_expedidos)),
      'permisos', jsonb_build_object(
        'gerencia_n',  (select count(1) from public.permiso_gerencia),
        'total',       (select count(1) from public.permisos),
        'pendientes',  (select count(1) from public.permisos where estado in ('PENDIENTE', 'EN TRAMITE')),
        'sin_fecha_nac', (select count(1) from public.perfilsociodemografico
                           where coalesce(estado, '') = 'ACTIVO' and fecha_nacimiento is null)),
      'pqrsf', jsonb_build_object(
        'sin_responder', (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is null),
        'falta_cerrar',  (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is not null
                             and p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
      'oriental', jsonb_build_object(
        'puestos',   (select count(1) from public.puestos
                       where nombre ilike '%oriental%' and coalesce(activo, true)),
        'turno_hoy', (select count(1) from public.horarios
                       where fecha = (select d from hoy) and observacion ilike '%oriental%'),
        'checkins',  (select count(1) from public.oriental_checkin
                       where fecha = (select d from hoy))),
      'interv', jsonb_build_object(
        'total',      (select count(1) from public.intervenciones),
        'historico',  (select count(1) from public.intervenciones where origen = 'CARGA'),
        'por_cerrar', (select count(1) from public.intervenciones
                        where estado = 'PROGRAMADA' and fecha < (select d from hoy)),
        'revisar',    (select count(1) from public.intervenciones where revisar)),
      'disc', jsonb_build_object(
        'total',      (select count(1) from public.disciplinarios),
        'enlace',     coalesce((select url from public.disciplinarios_fuente where id = 1), '') <> '',
        'ultima_carga', (select ultima_carga from public.disciplinarios_fuente where id = 1),
        'abiertos',   (select count(1) from public.disciplinarios
                        where etapa in ('POR CITAR', 'CITADO', 'POR DECIDIR', 'REPROGRAMAR')),
        'viejos',     (select count(1) from public.disciplinarios
                        where etapa in ('POR CITAR', 'CITADO', 'POR DECIDIR', 'REPROGRAMAR')
                          and fecha_suceso < (select d from hoy) - 60)))
  end;
$$;
revoke all on function public.novedades_estado() from public, anon;
grant execute on function public.novedades_estado() to authenticated;
