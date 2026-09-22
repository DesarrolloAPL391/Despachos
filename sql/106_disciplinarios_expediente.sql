-- ===================================================================================
-- 106: DISCIPLINARIOS — el expediente completo (va después de sql/102 y sql/105).
-- ===================================================================================
-- Con sql/105 quedó la diligencia. Pero un proceso disciplinario no termina en la
-- diligencia: sigue con la decisión, la notificación de esa decisión, el reclamo que
-- el trabajador pueda presentar, y el archivo. Lo que faltaba, en orden:
--
-- 1. LA CITACIÓN SIN CONSTANCIA. Si el trabajador se negó a recibirla o no se le pudo
--    localizar, hoy solo queda escrita la palabra "ILOCALIZADO". Eso no prueba nada:
--    la constancia de que se le puso de presente la cita necesita testigos con nombre
--    y cédula. Sin eso, en un juzgado la empresa no puede demostrar que lo citó.
--
-- 2. LA DECISIÓN SIN MOTIVACIÓN. Hoy se guarda la falta y la sanción, y la carta dice
--    "analizados los hechos y la versión rendida" — sin decir qué se analizó. Una carta
--    de sanción que no responde los descargos es lo primero que se cae: si se oyó al
--    trabajador y después no se valoró lo que dijo, la diligencia fue un trámite.
--
-- 3. LOS ANTECEDENTES NO SE VEN AL DECIDIR. Hay 2.660 procesos guardados por cédula y
--    al momento de graduar la sanción no se muestra ninguno. La proporcionalidad se
--    sostiene precisamente en eso: tres días de suspensión por la primera falta y por
--    la quinta no se sostienen igual.
--
-- 4. LA SANCIÓN SIN NOTIFICAR. sancion_enviada era una fecha suelta. Una sanción que no
--    se notificó no empieza a correr, y la suspensión que se descuenta sin constancia
--    de entrega es un descuento que después hay que devolver.
--
-- 5. EL RECLAMO DEL TRABAJADOR. La columna sancion_respuesta existía desde la hoja y
--    nadie la escribía, porque no había dónde. Si el trabajador reclama y nadie le
--    responde, la sanción queda en el aire.
--
-- 6. LA EJECUCIÓN Y EL CIERRE. La suspensión tenía fechas pero nadie marcaba que se
--    cumplió, y el expediente no se archivaba nunca. De ahí los 1.467 procesos que
--    figuran vivos desde hace más de 60 días.
--
-- LO QUE NO SE TOCA: la etapa sigue calculándose de las fechas (sql/102) y el registro
-- rápido de la diligencia sigue existiendo, porque los procesos viejos solo necesitan
-- eso. Lo de aquí es para los que se llevan de principio a fin.
-- ===================================================================================

do $guard$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'disciplinarios_docs') then
    raise exception 'Falta ejecutar sql/105_disciplinarios_documentos.sql antes de este archivo.';
  end if;
end $guard$;

-- ---------- 1) Lo que le faltaba al proceso ----------
alter table public.disciplinarios
  -- La decisión, motivada y con responsable
  add column if not exists decision_en          date,
  add column if not exists decide_nombre        text,
  add column if not exists decide_cargo         text,
  add column if not exists consideraciones      text,   -- por qué se decide así
  add column if not exists valoracion_descargos text,   -- qué se valoró de lo que dijo el trabajador
  -- El reclamo del trabajador contra la decisión (sancion_respuesta guarda la fecha)
  add column if not exists recurso_texto        text,
  add column if not exists recurso_resuelto_en  date,
  add column if not exists recurso_resultado    text,   -- CONFIRMA / MODIFICA / REVOCA
  add column if not exists recurso_motivacion   text,
  add column if not exists sancion_revocada     text,   -- lo que decía la sanción antes de revocarse
  -- La ejecución de la sanción
  add column if not exists ejecutado_en         date,
  add column if not exists ejecucion_nota       text,
  -- El archivo del expediente
  add column if not exists cerrado_en           timestamptz,
  add column if not exists cerrado_por          text,
  add column if not exists cierre_nota          text;

comment on column public.disciplinarios.consideraciones is
  'Por qué se decide así. Es lo que sostiene la sancion: sin esto la carta no responde los descargos.';
comment on column public.disciplinarios.valoracion_descargos is
  'Qué se valoró de la version que rindió el trabajador en la diligencia.';

-- ---------- 2) Las constancias de entrega ----------
-- Cada vez que se le entrega un documento al trabajador, queda la constancia: cuándo,
-- por qué medio, cómo resultó y quién lo vio. Si se negó a firmar o no se le localizó,
-- los testigos son obligatorios — es lo único que prueba el intento.
create table if not exists public.disciplinarios_notificaciones (
  id            bigint generated always as identity primary key,
  proceso_id    bigint not null references public.disciplinarios(id) on delete cascade,
  tipo          text not null check (tipo in ('CITACION', 'SANCION', 'OTRO')),
  fecha         date not null,
  hora          time,
  medio         text not null check (medio in ('PERSONAL', 'CORREO', 'WHATSAPP', 'CORREO CERTIFICADO', 'TELEFONO')),
  resultado     text not null check (resultado in ('RECIBIDO Y FIRMADO', 'SE NIEGA A FIRMAR',
                                                  'SE NIEGA A RECIBIR', 'NO SE LOCALIZA', 'ENVIADO')),
  quien_entrega text,
  testigo1_nombre text,
  testigo1_cedula text,
  testigo2_nombre text,
  testigo2_cedula text,
  firma         text,          -- firma de quien recibe, hecha en pantalla (PNG data URI)
  nota          text,
  creado_en     timestamptz not null default now(),
  creado_por    text
);
create index if not exists disc_notif_proceso_idx
  on public.disciplinarios_notificaciones (proceso_id, tipo, fecha desc);

comment on table public.disciplinarios_notificaciones is
  'Constancias de entrega de la citacion y de la sancion. Con testigos obligatorios si se nego a recibir.';

alter table public.disciplinarios_notificaciones enable row level security;
drop policy if exists disc_notif_sel on public.disciplinarios_notificaciones;
create policy disc_notif_sel on public.disciplinarios_notificaciones for select to authenticated
  using ( (select public.es_disc_ver()) );
revoke insert, update, delete on public.disciplinarios_notificaciones from authenticated;

-- ---------- 3) Los documentos nuevos ----------
alter table public.disciplinarios_docs drop constraint if exists disciplinarios_docs_tipo_check;
alter table public.disciplinarios_docs add constraint disciplinarios_docs_tipo_check
  check (tipo in ('CITACION', 'ACTA', 'SANCION', 'NO_COMPARECENCIA', 'NOTIFICACION', 'RECURSO'));

-- Se reemplaza la de sql/105 para darle consecutivo a los dos tipos nuevos.
create or replace function public.disc_doc_registrar(p_id bigint, p_tipo text, p_datos jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_pref text; v_anio int; v_n int; v_cons text; v_correo text;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana generan estos documentos.');
  end if;
  v_pref := case upper(coalesce(p_tipo, ''))
              when 'CITACION' then 'CIT' when 'ACTA' then 'ACT'
              when 'SANCION' then 'SAN' when 'NO_COMPARECENCIA' then 'NCP'
              when 'NOTIFICACION' then 'NOT' when 'RECURSO' then 'REC' end;
  if v_pref is null then
    return jsonb_build_object('ok', false, 'error', 'Tipo de documento desconocido.');
  end if;

  v_anio := extract(year from (now() at time zone 'America/Bogota'))::int;
  select coalesce(max((regexp_replace(consecutivo, '^[A-Z]+-\d{4}-', ''))::int), 0) + 1
    into v_n
    from public.disciplinarios_docs
   where consecutivo like v_pref || '-' || v_anio || '-%';

  v_cons := v_pref || '-' || v_anio || '-' || lpad(v_n::text, 4, '0');
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');

  insert into public.disciplinarios_docs (proceso_id, tipo, consecutivo, datos, generado_por)
  values (p_id, upper(p_tipo), v_cons, p_datos, v_correo);

  return jsonb_build_object('ok', true, 'consecutivo', v_cons, 'generado_por', v_correo);
end $fn$;
revoke all on function public.disc_doc_registrar(bigint, text, jsonb) from public, anon;
grant execute on function public.disc_doc_registrar(bigint, text, jsonb) to authenticated;

-- ---------- 4) Registrar una entrega ----------
create or replace function public.disc_notificar(
  p_id bigint, p_tipo text, p_fecha date, p_medio text, p_resultado text,
  p_hora time default null, p_quien text default null,
  p_t1_nombre text default null, p_t1_cedula text default null,
  p_t2_nombre text default null, p_t2_cedula text default null,
  p_firma text default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text; v_tipo text; v_res text; v_hoy date; v_estado text;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana registran las entregas.');
  end if;
  if not exists (select 1 from public.disciplinarios where id = p_id and anulado_en is null) then
    return jsonb_build_object('ok', false, 'error', 'No existe ese proceso, o está anulado.');
  end if;

  v_tipo := upper(trim(coalesce(p_tipo, '')));
  v_res  := upper(trim(coalesce(p_resultado, '')));
  v_hoy  := (now() at time zone 'America/Bogota')::date;

  if p_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'Falta la fecha de la entrega.');
  end if;
  if p_fecha > v_hoy then
    return jsonb_build_object('ok', false, 'error', 'La fecha de entrega no puede ser posterior a hoy.');
  end if;

  -- Negarse a recibir es válido; que no quede constancia de quién lo vio, no.
  if v_res in ('SE NIEGA A FIRMAR', 'SE NIEGA A RECIBIR', 'NO SE LOCALIZA')
     and (nullif(trim(coalesce(p_t1_nombre, '')), '') is null
          or nullif(trim(coalesce(p_t1_cedula, '')), '') is null) then
    return jsonb_build_object('ok', false, 'error',
      'Si no recibió o no firmó, hace falta un testigo con nombre y cédula: es lo único que prueba el intento.');
  end if;

  -- La sanción no se notifica antes de decidirla.
  if v_tipo = 'SANCION' and not exists (
       select 1 from public.disciplinarios where id = p_id and sancion is not null) then
    return jsonb_build_object('ok', false, 'error', 'Todavía no hay decisión que notificar.');
  end if;

  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');

  insert into public.disciplinarios_notificaciones
    (proceso_id, tipo, fecha, hora, medio, resultado, quien_entrega,
     testigo1_nombre, testigo1_cedula, testigo2_nombre, testigo2_cedula, firma, nota, creado_por)
  values (p_id, v_tipo, p_fecha, p_hora, upper(trim(p_medio)), v_res,
          nullif(trim(coalesce(p_quien, '')), ''),
          nullif(trim(coalesce(p_t1_nombre, '')), ''), nullif(trim(coalesce(p_t1_cedula, '')), ''),
          nullif(trim(coalesce(p_t2_nombre, '')), ''), nullif(trim(coalesce(p_t2_cedula, '')), ''),
          nullif(p_firma, ''), nullif(trim(coalesce(p_nota, '')), ''), v_correo);

  -- El proceso guarda el resumen, en las mismas palabras que traía la hoja histórica.
  v_estado := case v_res
                when 'RECIBIDO Y FIRMADO' then 'FIRMADO'
                when 'NO SE LOCALIZA'     then 'ILOCALIZADO'
                when 'SE NIEGA A FIRMAR'  then 'SE NIEGA A FIRMAR'
                when 'SE NIEGA A RECIBIR' then 'SE NIEGA A FIRMAR'
                else null end;

  if v_tipo = 'CITACION' then
    update public.disciplinarios
       set citacion_enviada = coalesce(citacion_enviada, p_fecha),
           citacion_estado  = coalesce(v_estado, citacion_estado),
           citacion_responsable = coalesce(nullif(trim(coalesce(p_quien, '')), ''), citacion_responsable),
           actualizado_en = now()
     where id = p_id;
  elsif v_tipo = 'SANCION' then
    update public.disciplinarios
       set sancion_enviada = coalesce(sancion_enviada, p_fecha), actualizado_en = now()
     where id = p_id;
  end if;

  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_notificar(bigint, text, date, text, text, time, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.disc_notificar(bigint, text, date, text, text, time, text, text, text, text, text, text, text) to authenticated;

-- ---------- 5) Decidir, con motivación ----------
-- Esta es la versión completa. disc_sancionar (sql/102) se queda para los procesos
-- viejos que se están poniendo al día y solo necesitan el dato.
create or replace function public.disc_decidir(
  p_id bigint, p_falta text, p_sancion text,
  p_consideraciones text, p_decide_nombre text,
  p_dias numeric default null, p_unidad text default null,
  p_ini date default null, p_fin date default null,
  p_valoracion text default null, p_decide_cargo text default null,
  p_fecha date default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r public.disciplinarios%rowtype; v_fecha date; v_sancion text; v_hay_acta boolean;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana deciden el proceso.');
  end if;
  select * into r from public.disciplinarios where id = p_id and anulado_en is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No existe ese proceso, o está anulado.');
  end if;

  v_sancion := trim(coalesce(p_sancion, ''));
  v_fecha   := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);

  if v_sancion = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta decir qué se decide.');
  end if;

  -- No se sanciona sin haber oído: o hubo diligencia, o hay constancia cerrada de que
  -- no se presentó (art. 115 del CST). Esto es lo que hace válida la sanción.
  select (a.cerrada_en is not null) into v_hay_acta
    from public.disciplinarios_acta a where a.proceso_id = p_id;
  if r.descargo_fecha is null and coalesce(v_hay_acta, false) is not true then
    return jsonb_build_object('ok', false, 'error',
      'Antes de decidir hay que oír al trabajador: registra la diligencia de descargos, o cierra el acta '
      || 'como no comparecencia si no se presentó.');
  end if;

  if length(trim(coalesce(p_consideraciones, ''))) < 40 then
    return jsonb_build_object('ok', false, 'error',
      'Escribe las consideraciones de la decisión. Es lo que responde los descargos: una carta que no '
      || 'dice por qué se decidió así deja la diligencia como un trámite.');
  end if;
  if nullif(trim(coalesce(p_decide_nombre, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Falta quién toma la decisión.');
  end if;

  -- La suspensión necesita días y fechas, y no puede empezar antes de decidirse.
  if upper(v_sancion) like 'SUSPENSI%' then
    if coalesce(p_dias, 0) <= 0 then
      return jsonb_build_object('ok', false, 'error', 'Falta por cuántos días es la suspensión.');
    end if;
    if p_ini is null or p_fin is null then
      return jsonb_build_object('ok', false, 'error', 'Falta desde cuándo y hasta cuándo va la suspensión.');
    end if;
    if p_fin < p_ini then
      return jsonb_build_object('ok', false, 'error', 'La suspensión termina antes de empezar: revisa las fechas.');
    end if;
    if p_ini < v_fecha then
      return jsonb_build_object('ok', false, 'error',
        'La suspensión no puede empezar antes de la fecha de la decisión.');
    end if;
  end if;

  update public.disciplinarios set
    falta       = coalesce(nullif(trim(coalesce(p_falta, '')), ''), falta),
    falta_grupo = public.disc_falta_grupo(coalesce(nullif(trim(coalesce(p_falta, '')), ''), falta)),
    sancion     = v_sancion,
    sancion_dias   = case when upper(v_sancion) like 'NO GENERA%' then null else p_dias end,
    sancion_unidad = case when upper(v_sancion) like 'NO GENERA%' then null
                          else nullif(upper(trim(coalesce(p_unidad, ''))), '') end,
    suspension_ini = case when upper(v_sancion) like 'SUSPENSI%' then p_ini else null end,
    suspension_fin = case when upper(v_sancion) like 'SUSPENSI%' then p_fin else null end,
    decision_en   = v_fecha,
    decide_nombre = trim(p_decide_nombre),
    decide_cargo  = nullif(trim(coalesce(p_decide_cargo, '')), ''),
    consideraciones = trim(p_consideraciones),
    valoracion_descargos = nullif(trim(coalesce(p_valoracion, '')), ''),
    actualizado_en = now()
  where id = p_id;

  return (select jsonb_build_object('ok', true, 'etapa', etapa) from public.disciplinarios where id = p_id);
end $fn$;
revoke all on function public.disc_decidir(bigint, text, text, text, text, numeric, text, date, date, text, text, date) from public, anon;
grant execute on function public.disc_decidir(bigint, text, text, text, text, numeric, text, date, date, text, text, date) to authenticated;

-- ---------- 6) El reclamo del trabajador, y su respuesta ----------
create or replace function public.disc_recurso(p_id bigint, p_fecha date, p_texto text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana registran el reclamo.');
  end if;
  if nullif(trim(coalesce(p_texto, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe qué está reclamando el trabajador.');
  end if;
  if not exists (select 1 from public.disciplinarios
                  where id = p_id and anulado_en is null and sancion is not null) then
    return jsonb_build_object('ok', false, 'error', 'Este proceso todavía no tiene decisión que reclamar.');
  end if;
  update public.disciplinarios
     set sancion_respuesta = coalesce(p_fecha, (now() at time zone 'America/Bogota')::date),
         recurso_texto = trim(p_texto), actualizado_en = now()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_recurso(bigint, date, text) from public, anon;
grant execute on function public.disc_recurso(bigint, date, text) to authenticated;

create or replace function public.disc_recurso_resolver(
  p_id bigint, p_fecha date, p_resultado text, p_motivacion text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r public.disciplinarios%rowtype; v_res text;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana resuelven el reclamo.');
  end if;
  select * into r from public.disciplinarios where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe ese proceso.'); end if;
  if r.recurso_texto is null then
    return jsonb_build_object('ok', false, 'error', 'No hay reclamo registrado en este proceso.');
  end if;
  v_res := upper(trim(coalesce(p_resultado, '')));
  if v_res not in ('CONFIRMA', 'MODIFICA', 'REVOCA') then
    return jsonb_build_object('ok', false, 'error', 'El resultado debe ser CONFIRMA, MODIFICA o REVOCA.');
  end if;
  if length(trim(coalesce(p_motivacion, ''))) < 20 then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se resuelve así: es la respuesta al trabajador.');
  end if;

  update public.disciplinarios
     set recurso_resuelto_en = coalesce(p_fecha, (now() at time zone 'America/Bogota')::date),
         recurso_resultado = v_res, recurso_motivacion = trim(p_motivacion),
         -- Si se revoca, la sanción deja de existir: si no, nómina la seguiría aplicando.
         -- Lo que decía queda guardado, que para eso es un expediente.
         sancion_revocada = case when v_res = 'REVOCA' then sancion else sancion_revocada end,
         sancion        = case when v_res = 'REVOCA' then 'NO GENERA SANCIÓN' else sancion end,
         sancion_dias   = case when v_res = 'REVOCA' then null else sancion_dias end,
         suspension_ini = case when v_res = 'REVOCA' then null else suspension_ini end,
         suspension_fin = case when v_res = 'REVOCA' then null else suspension_fin end,
         actualizado_en = now()
   where id = p_id;

  return jsonb_build_object('ok', true, 'resultado', v_res,
    'nota', case when v_res = 'MODIFICA'
                 then 'Queda registrado. Vuelve a Decidir para dejar escrita la sanción que reemplaza la anterior.'
                 else null end);
end $fn$;
revoke all on function public.disc_recurso_resolver(bigint, date, text, text) from public, anon;
grant execute on function public.disc_recurso_resolver(bigint, date, text, text) to authenticated;

-- ---------- 7) La sanción se cumplió ----------
create or replace function public.disc_ejecutado(p_id bigint, p_fecha date default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana marcan el cumplimiento.');
  end if;
  update public.disciplinarios
     set ejecutado_en = coalesce(p_fecha, (now() at time zone 'America/Bogota')::date),
         ejecucion_nota = nullif(trim(coalesce(p_nota, '')), ''), actualizado_en = now()
   where id = p_id and anulado_en is null and sancion is not null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No hay una decisión que cumplir en este proceso.');
  end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_ejecutado(bigint, date, text) from public, anon;
grant execute on function public.disc_ejecutado(bigint, date, text) to authenticated;

-- ---------- 8) Archivar el expediente ----------
-- Cerrar no es un botón de cortesía: es lo que separa los procesos vivos de los que
-- nadie cerró. Por eso pide lo que faltaría para que el expediente quede completo.
create or replace function public.disc_cerrar(p_id bigint, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r public.disciplinarios%rowtype; v_correo text; v_hoy date; v_notif boolean;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana archivan el expediente.');
  end if;
  select * into r from public.disciplinarios where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe ese proceso, o está anulado.'); end if;
  if r.cerrado_en is not null then
    return jsonb_build_object('ok', false, 'error', 'Este expediente ya estaba archivado.');
  end if;
  if r.sancion is null then
    return jsonb_build_object('ok', false, 'error', 'Falta decidir el proceso antes de archivarlo.');
  end if;

  v_hoy := (now() at time zone 'America/Bogota')::date;

  if upper(r.sancion) not like 'NO GENERA%' then
    select exists (select 1 from public.disciplinarios_notificaciones
                    where proceso_id = p_id and tipo = 'SANCION') into v_notif;
    if not v_notif and r.sancion_enviada is null then
      return jsonb_build_object('ok', false, 'error',
        'Falta notificar la decisión al trabajador. Una sanción que no se notificó no empieza a correr.');
    end if;
  end if;

  if r.recurso_texto is not null and r.recurso_resuelto_en is null then
    return jsonb_build_object('ok', false, 'error',
      'El trabajador presentó un reclamo que todavía no se ha resuelto.');
  end if;

  if r.suspension_fin is not null and r.suspension_fin < v_hoy and r.ejecutado_en is null then
    return jsonb_build_object('ok', false, 'error',
      'La suspensión ya pasó y nadie marcó si se cumplió. Márcalo antes de archivar.');
  end if;

  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  update public.disciplinarios
     set cerrado_en = now(), cerrado_por = v_correo,
         cierre_nota = nullif(trim(coalesce(p_nota, '')), ''), actualizado_en = now()
   where id = p_id;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_cerrar(bigint, text) from public, anon;
grant execute on function public.disc_cerrar(bigint, text) to authenticated;

create or replace function public.disc_reabrir_expediente(p_id bigint, p_nota text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración reabre un expediente archivado.');
  end if;
  if nullif(trim(coalesce(p_nota, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se reabre: queda en el expediente.');
  end if;
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  update public.disciplinarios
     set cerrado_en = null, cerrado_por = null,
         observacion = coalesce(observacion || E'\n', '')
           || '[Expediente reabierto el ' || to_char(now() at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI')
           || ' por ' || v_correo || ': ' || trim(p_nota) || ']',
         actualizado_en = now()
   where id = p_id and cerrado_en is not null;
  if not found then return jsonb_build_object('ok', false, 'error', 'Ese expediente no está archivado.'); end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_reabrir_expediente(bigint, text) from public, anon;
grant execute on function public.disc_reabrir_expediente(bigint, text) to authenticated;

-- ---------- 9) El expediente de un proceso, completo ----------
-- Todo lo del proceso en una sola consulta: el acta, los documentos, las entregas, los
-- antecedentes de esa persona y los avisos de lo que quedó cojo. Los antecedentes van
-- aquí y no en el cliente porque exigen leer filas de OTRAS personas del expediente.
create or replace function public.disc_expediente(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare r public.disciplinarios%rowtype; v_acta jsonb; v_docs jsonb; v_notif jsonb;
        v_ant jsonb; v_avisos jsonb := '[]'::jsonb; v_hoy date; v_dias int;
        v_cerrada timestamptz; v_comp boolean; v_veces int;
begin
  if not public.es_disc_ver() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  select * into r from public.disciplinarios where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe ese proceso.'); end if;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  select to_jsonb(a), a.cerrada_en, a.comparecio into v_acta, v_cerrada, v_comp
    from public.disciplinarios_acta a where a.proceso_id = p_id;

  select jsonb_agg(jsonb_build_object('tipo', tipo, 'consecutivo', consecutivo,
                                      'generado_en', generado_en, 'generado_por', generado_por)
                   order by generado_en desc)
    into v_docs from public.disciplinarios_docs where proceso_id = p_id;

  select jsonb_agg(to_jsonb(n) order by n.fecha desc, n.id desc)
    into v_notif from public.disciplinarios_notificaciones n where n.proceso_id = p_id;

  -- Antecedentes: los demás procesos de la misma persona, ya decididos.
  if coalesce(r.cedula, '') <> '' then
    select jsonb_agg(x) into v_ant from (
      select jsonb_build_object('id', d.id, 'fecha_suceso', d.fecha_suceso, 'falta', d.falta,
                                'falta_grupo', d.falta_grupo, 'sancion', d.sancion,
                                'sancion_dias', d.sancion_dias, 'etapa', d.etapa) as x
        from public.disciplinarios d
       where d.cedula = r.cedula and d.id <> p_id and d.anulado_en is null
       order by d.fecha_suceso desc nulls last
       limit 25) t;

    -- Reincidencia en la MISMA causa: es lo que sostiene subir la sanción.
    select count(*) into v_veces
      from public.disciplinarios d
     where d.cedula = r.cedula and d.id <> p_id and d.anulado_en is null
       and d.falta_grupo is not null and d.falta_grupo = r.falta_grupo
       and d.sancion is not null and upper(d.sancion) not like 'NO GENERA%';
    if coalesce(v_veces, 0) > 0 then
      v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'info',
        'texto', 'Ya tiene ' || v_veces || ' sanción(es) anterior(es) por la misma causa.'));
    end if;
  end if;

  -- Inmediatez: una falta que se sanciona seis meses después ya no se sostiene igual.
  if r.sancion is null and r.fecha_suceso is not null then
    v_dias := v_hoy - r.fecha_suceso;
    if v_dias > 60 then
      v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'alto',
        'texto', 'El hecho ocurrió hace ' || v_dias || ' días y el proceso sigue sin decidir.'));
    end if;
  end if;

  -- Plazo de defensa: citar para el mismo día no deja preparar nada ni buscar acompañante.
  if r.citacion_enviada is not null and r.citacion_fecha is not null
     and r.citacion_fecha <= r.citacion_enviada then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'alto',
      'texto', 'La citación se entregó el mismo día de la diligencia: no hubo tiempo de preparar la defensa.'));
  end if;

  -- Citación sin constancia de entrega.
  if r.citacion_fecha is not null
     and not exists (select 1 from public.disciplinarios_notificaciones
                      where proceso_id = p_id and tipo = 'CITACION')
     and r.citacion_estado is null then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'medio',
      'texto', 'No hay constancia de cómo se entregó la citación.'));
  end if;

  -- Diligencia registrada pero sin acta: es el hueco que llenó sql/105.
  if r.descargo_fecha is not null and v_cerrada is null then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'medio',
      'texto', 'La diligencia está registrada pero el acta no está cerrada: no queda qué se dijo.'));
  end if;

  -- Decisión sin motivar (los procesos viejos y los que se decidieron por el camino corto).
  if r.sancion is not null and r.consideraciones is null then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'medio',
      'texto', 'La decisión no tiene consideraciones escritas: la carta no responde los descargos.'));
  end if;

  -- Sanción sin notificar.
  if r.sancion is not null and upper(r.sancion) not like 'NO GENERA%'
     and r.sancion_enviada is null
     and not exists (select 1 from public.disciplinarios_notificaciones
                      where proceso_id = p_id and tipo = 'SANCION') then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'alto',
      'texto', 'La decisión no se ha notificado al trabajador.'));
  end if;

  -- Reclamo sin responder.
  if r.recurso_texto is not null and r.recurso_resuelto_en is null then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'alto',
      'texto', 'El trabajador presentó un reclamo que no se ha resuelto.'));
  end if;

  -- Suspensión que ya pasó y nadie marcó.
  if r.suspension_fin is not null and r.suspension_fin < v_hoy and r.ejecutado_en is null then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object('nivel', 'medio',
      'texto', 'La suspensión ya pasó y no se marcó si se cumplió.'));
  end if;

  return jsonb_build_object('ok', true,
    'proceso', to_jsonb(r),
    'acta', v_acta,
    'acta_cerrada', (v_cerrada is not null),
    'acta_comparecio', v_comp,
    'docs', coalesce(v_docs, '[]'::jsonb),
    'notificaciones', coalesce(v_notif, '[]'::jsonb),
    'antecedentes', coalesce(v_ant, '[]'::jsonb),
    'avisos', v_avisos,
    'puede_editar', public.es_disc_gestion(),
    'es_admin', (select public.es_admin()),
    'hoy', v_hoy);
end $fn$;
revoke all on function public.disc_expediente(bigint) from public, anon;
grant execute on function public.disc_expediente(bigint) to authenticated;
