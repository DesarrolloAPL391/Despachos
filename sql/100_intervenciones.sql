-- ============================================================================================
-- 100) INTERVENCIONES a los equipos del bus (GPS, sensores de pasajeros, cámaras, SIM)
--
-- QUÉ RESUELVE: hoy esto vive en una hoja de cálculo con 2.397 registros desde enero de 2023.
-- Ahí no se sabe qué hay citado para hoy, quién no llegó, ni qué carro es el que siempre vuelve
-- por lo mismo. Y el dato más caro está perdido dentro de la hoja: de cada ocho carros citados,
-- uno no entra a portería.
--
-- CÓMO QUEDA: el auditor CITA el carro (móvil, fecha, hora y motivo) y la intervención nace
-- PROGRAMADA. Cuando pasa, la CIERRA con lo que ocurrió — INGRESO, NO INGRESO o NO SE PRESENTO —
-- y la observación de lo que se hizo. De ahí salen solas la agenda del día, lo que quedó sin
-- cerrar y el cumplimiento de las citas.
--
-- LOS DATOS DEL CARRO NO SE VUELVEN A PEDIR: placa, ruta, propietario y contacto se copian del
-- parque automotor al crear la intervención. Se copian (no se consultan cada vez) a propósito:
-- un carro cambia de dueño y el histórico debe seguir diciendo quién era el dueño ESE día.
--
-- QUIÉN ENTRA: auditores registran y ven; administración todo; operaciones consulta; el afiliado
-- ve las de SUS carros. El motivo sigue siendo texto libre, como lo escriben hoy.
--
-- Se aplica sobre sql/43 (afiliado) y sql/60 (es_operaciones).
-- ============================================================================================

-- 1) La tabla ------------------------------------------------------------------------------------
create table if not exists public.intervenciones (
  id             bigserial primary key,
  fecha          date not null,                 -- día de la cita / de la intervención
  hora           time,
  movil          text not null,                 -- numero_interno del parque automotor
  -- Foto del carro al momento de la cita (no se re-consulta: el dueño de hoy no es el de 2023)
  placa          text,
  ruta           text,
  propietario    text,
  celular        text,
  correo         text,
  motivo         text not null,                 -- texto libre, como se escribe hoy
  -- El cierre
  resultado      text check (resultado in ('INGRESO', 'NO INGRESO', 'NO SE PRESENTO')),
  observacion    text,
  cerrado_en     timestamptz,
  cerrado_por    text,
  -- Anulación (una cita mal puesta no se borra: se anula y queda el rastro)
  anulado_en     timestamptz,
  anulado_por    text,
  nota_anulacion text,
  -- Trazabilidad
  revisar        boolean not null default false, -- llegó del histórico con algo dudoso
  origen         text not null default 'APP',    -- APP | CARGA
  creado_en      timestamptz not null default now(),
  creado_por     text,
  creado_nombre  text,
  estado text generated always as (
    case when anulado_en is not null then 'ANULADA'
         when resultado is null      then 'PROGRAMADA'
         else resultado end) stored
);
create index if not exists interv_fecha_idx  on public.intervenciones (fecha desc, hora);
create index if not exists interv_movil_idx  on public.intervenciones (movil, fecha desc);
create index if not exists interv_estado_idx on public.intervenciones (estado, fecha desc);
-- Para que recargar el histórico no duplique nada
create unique index if not exists interv_unica_idx
  on public.intervenciones (movil, fecha, coalesce(hora, time '00:00'), md5(lower(trim(motivo))));

comment on table public.intervenciones is
  'Intervenciones a los equipos del bus (GPS, sensores de pasajeros, camaras). El auditor cita y luego cierra con lo que paso.';

-- 2) Quién ve y quién registra --------------------------------------------------------------------
create or replace function public.es_interv_editor()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_admin() or public.es_auditor(); $$;
revoke all on function public.es_interv_editor() from public, anon;
grant execute on function public.es_interv_editor() to authenticated;

create or replace function public.es_interv_ver()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_admin() or public.es_auditor() or public.es_operaciones() or public.es_afiliado(); $$;
revoke all on function public.es_interv_ver() from public, anon;
grant execute on function public.es_interv_ver() to authenticated;

alter table public.intervenciones enable row level security;
revoke all on table public.intervenciones from anon;
grant select on table public.intervenciones to authenticated;
revoke all on sequence public.intervenciones_id_seq from public, anon;

-- El afiliado solo ve sus carros; los demás roles autorizados ven todo. Las funciones van
-- envueltas en (select ...) por [[rls-perf-funciones-envueltas]]: si no, se evalúan por fila.
drop policy if exists interv_ver on public.intervenciones;
create policy interv_ver on public.intervenciones for select to authenticated
  using (
    (select public.es_admin()) or (select public.es_auditor()) or (select public.es_operaciones())
    or ((select public.es_afiliado()) and trim(movil) = any (public.mis_moviles_afiliado()))
  );
-- Sin políticas de escritura: se entra por las funciones de abajo, que sellan quién hizo qué.

-- 3) Los datos del carro, para llenar el formulario solo -------------------------------------------
create or replace function public.interv_vehiculo(p_movil text)
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_interv_ver() then jsonb_build_object('ok', false)
    else coalesce((select jsonb_build_object(
      'ok', true, 'movil', v.numero_interno, 'placa', v.placa, 'ruta', v.ruta,
      'propietario', v.propietario, 'celular', v.telefono, 'correo', v.correo,
      'estado', v.estado, 'marca', v.marca, 'modelo', v.modelo)
      from public.parque_automotor v
      where trim(v.numero_interno) = trim(p_movil)
      order by (v.estado is distinct from 'Desvinculado') desc
      limit 1), jsonb_build_object('ok', true, 'movil', trim(p_movil), 'sin_ficha', true))
  end;
$$;
revoke all on function public.interv_vehiculo(text) from public, anon;
grant execute on function public.interv_vehiculo(text) to authenticated;

-- 4) Citar (o corregir la cita) --------------------------------------------------------------------
create or replace function public.interv_guardar(
  p_id bigint, p_movil text, p_fecha date, p_hora time, p_motivo text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_v public.parque_automotor%rowtype; v_id bigint; v_quien text; v_nombre text; v_mov text := trim(coalesce(p_movil, ''));
begin
  if not public.es_interv_editor() then
    return jsonb_build_object('ok', false, 'error', 'Solo los auditores y administracion registran intervenciones.');
  end if;
  if v_mov = '' or p_fecha is null or coalesce(trim(p_motivo), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el movil, la fecha o el motivo.');
  end if;
  if p_fecha < date '2015-01-01' or p_fecha > (now() at time zone 'America/Bogota')::date + 365 then
    return jsonb_build_object('ok', false, 'error', 'Esa fecha esta fuera de rango.');
  end if;

  select email, nombre into v_quien, v_nombre from (
    select u.email, p.nombre from auth.users u
    left join public.perfiles p on p.id = u.id
    where u.id = auth.uid()) s;

  select * into v_v from public.parque_automotor
   where trim(numero_interno) = v_mov
   order by (estado is distinct from 'Desvinculado') desc limit 1;

  if p_id is null then
    insert into public.intervenciones
      (fecha, hora, movil, placa, ruta, propietario, celular, correo, motivo,
       origen, creado_por, creado_nombre)
    values (p_fecha, p_hora, v_mov, v_v.placa, v_v.ruta, v_v.propietario, v_v.telefono, v_v.correo,
            trim(p_motivo), 'APP', v_quien, coalesce(v_nombre, v_quien))
    on conflict do nothing
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'Ese movil ya tiene esa misma cita ese dia y a esa hora.');
    end if;
  else
    update public.intervenciones
       set fecha = p_fecha, hora = p_hora, movil = v_mov, motivo = trim(p_motivo),
           placa = coalesce(placa, v_v.placa), ruta = coalesce(ruta, v_v.ruta),
           propietario = coalesce(propietario, v_v.propietario),
           celular = coalesce(celular, v_v.telefono), correo = coalesce(correo, v_v.correo),
           revisar = false
     where id = p_id and anulado_en is null
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'No se encontro esa intervencion (o esta anulada).');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.interv_guardar(bigint, text, date, time, text) from public, anon;
grant execute on function public.interv_guardar(bigint, text, date, time, text) to authenticated;

-- 5) Cerrar: qué pasó con la cita --------------------------------------------------------------------
create or replace function public.interv_cerrar(p_id bigint, p_resultado text, p_observacion text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_quien text; v_r text := upper(trim(coalesce(p_resultado, '')));
begin
  if not public.es_interv_editor() then
    return jsonb_build_object('ok', false, 'error', 'Solo los auditores y administracion cierran una intervencion.');
  end if;
  if v_r not in ('INGRESO', 'NO INGRESO', 'NO SE PRESENTO') then
    return jsonb_build_object('ok', false, 'error', 'Resultado no valido.');
  end if;
  select email into v_quien from auth.users where id = auth.uid();
  update public.intervenciones
     set resultado = v_r, observacion = nullif(trim(coalesce(p_observacion, '')), ''),
         cerrado_en = now(), cerrado_por = v_quien, revisar = false
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro esa intervencion (o esta anulada).'); end if;
  return jsonb_build_object('ok', true, 'estado', v_r);
end $$;
revoke all on function public.interv_cerrar(bigint, text, text) from public, anon;
grant execute on function public.interv_cerrar(bigint, text, text) to authenticated;

-- Volver a dejarla PROGRAMADA (se cerró por equivocación). Solo administración.
create or replace function public.interv_reabrir(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion reabre una intervencion cerrada.');
  end if;
  update public.intervenciones
     set resultado = null, observacion = null, cerrado_en = null, cerrado_por = null
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro esa intervencion.'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.interv_reabrir(bigint) from public, anon;
grant execute on function public.interv_reabrir(bigint) to authenticated;

-- Anular (la cita estaba mal puesta). No se borra: queda el rastro de quién y por qué.
create or replace function public.interv_anular(p_id bigint, p_nota text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare v_quien text;
begin
  if not public.es_interv_editor() then
    return jsonb_build_object('ok', false, 'error', 'Solo los auditores y administracion anulan una intervencion.');
  end if;
  select email into v_quien from auth.users where id = auth.uid();
  update public.intervenciones
     set anulado_en = now(), anulado_por = v_quien,
         nota_anulacion = nullif(trim(coalesce(p_nota, '')), '')
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro esa intervencion (o ya estaba anulada).'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.interv_anular(bigint, text) from public, anon;
grant execute on function public.interv_anular(bigint, text) to authenticated;

-- 6) Contadores para el menú -------------------------------------------------------------------------
create or replace function public.intervenciones_estado()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_interv_ver() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_editar', public.es_interv_editor(),
      'hoy',       (select count(1) from public.intervenciones
                     where fecha = (now() at time zone 'America/Bogota')::date and anulado_en is null),
      -- lo que ya pasó y nadie cerró: es el trabajo pendiente de verdad
      'por_cerrar',(select count(1) from public.intervenciones
                     where estado = 'PROGRAMADA' and fecha < (now() at time zone 'America/Bogota')::date),
      'revisar',   (select count(1) from public.intervenciones where revisar),
      'total',     (select count(1) from public.intervenciones))
  end;
$$;
revoke all on function public.intervenciones_estado() from public, anon;
grant execute on function public.intervenciones_estado() to authenticated;

-- 7) Carga del histórico (la hoja de cálculo) ---------------------------------------------------------
--    Solo administración. Recibe las filas tal como vienen del archivo y las endereza aquí, que es
--    donde queda documentado qué se corrigió:
--      · la ruta se unifica (133iiA → 133IIA, "133 -133D" → 133-133D, Integradas → INTEGRADAS);
--      · si la casilla de portería trae un motivo (filas corridas), ese texto se pega al motivo y
--        la fila queda marcada para revisar, sin inventarle un resultado;
--      · las fechas imposibles se conservan tal cual, pero marcadas;
--      · el contacto que falte se toma del parque automotor.
create or replace function public.interv_carga(p_filas jsonb)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  f jsonb; v_fecha date; v_hora time; v_mov text; v_ruta text; v_mot text; v_res text; v_por text;
  v_rev boolean; v_reg timestamptz; v_v public.parque_automotor%rowtype; v_n int := 0; v_dup int := 0; v_mal int := 0; v_marc int := 0; v_hoy date;
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion carga el historico.');
  end if;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  for f in select * from jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) loop
    v_rev := false;
    -- fecha dd/mm/aaaa (lo que exporta la hoja)
    begin
      v_fecha := to_date(nullif(trim(coalesce(f->>'fecha', '')), ''), 'DD/MM/YYYY');
    exception when others then v_fecha := null; end;
    begin
      v_hora := nullif(trim(coalesce(f->>'hora', '')), '')::time;
    exception when others then v_hora := null; end;

    begin
      v_reg := to_timestamp(nullif(trim(coalesce(f->>'registrado_en', '')), ''), 'DD/MM/YYYY HH24:MI:SS');
    exception when others then v_reg := null; end;

    v_mov := trim(coalesce(f->>'movil', ''));
    v_mot := trim(coalesce(f->>'motivo', ''));
    if v_fecha is null or v_mov = '' or v_mot = '' then v_mal := v_mal + 1; continue; end if;
    if v_fecha < date '2015-01-01' or v_fecha > v_hoy + 30 then v_rev := true; end if;

    -- Ruta: una sola forma de escribirla
    v_ruta := upper(trim(coalesce(f->>'ruta', '')));
    v_ruta := regexp_replace(v_ruta, '\s*-\s*', '-', 'g');
    v_ruta := regexp_replace(v_ruta, '\s+', ' ', 'g');
    v_ruta := nullif(v_ruta, '');

    -- Portería: solo tres respuestas válidas. Cualquier otra cosa es una fila corrida.
    v_por := upper(translate(trim(coalesce(f->>'porteria', '')), 'ÁÉÍÓÚ', 'AEIOU'));
    if v_por in ('INGRESO', 'NO INGRESO', 'NO SE PRESENTO') then
      v_res := v_por;
    else
      v_res := null;
      if v_por <> '' then v_mot := v_mot || ' · ' || trim(coalesce(f->>'porteria', '')); v_rev := true; end if;
      if v_por = '' then v_rev := true; end if;   -- sin respuesta: tampoco se sabe qué pasó
    end if;

    select * into v_v from public.parque_automotor
     where trim(numero_interno) = v_mov
     order by (estado is distinct from 'Desvinculado') desc limit 1;

    insert into public.intervenciones
      (fecha, hora, movil, placa, ruta, propietario, celular, correo, motivo,
       resultado, cerrado_en, cerrado_por, revisar, origen, creado_en, creado_por, creado_nombre)
    values (
      v_fecha, v_hora, v_mov, v_v.placa,
      coalesce(v_ruta, upper(trim(coalesce(v_v.ruta, '')))),
      coalesce(nullif(trim(coalesce(f->>'propietario', '')), ''), v_v.propietario),
      coalesce(nullif(trim(coalesce(f->>'celular', '')), ''), v_v.telefono),
      coalesce(nullif(trim(coalesce(f->>'correo', '')), ''), v_v.correo),
      v_mot,
      v_res,
      case when v_res is null then null
           else coalesce(v_reg, (v_fecha + coalesce(v_hora, time '00:00')) at time zone 'America/Bogota') end,
      case when v_res is null then null else nullif(trim(coalesce(f->>'usuario', '')), '') end,
      v_rev, 'CARGA',
      coalesce(v_reg, now()),
      nullif(trim(coalesce(f->>'usuario', '')), ''),
      nullif(trim(coalesce(f->>'usuario', '')), ''))
    on conflict do nothing;

    if found then
      v_n := v_n + 1;
      if v_rev then v_marc := v_marc + 1; end if;
    else
      v_dup := v_dup + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'cargadas', v_n, 'repetidas', v_dup,
                            'descartadas', v_mal, 'para_revisar', v_marc);
end $$;
revoke all on function public.interv_carga(jsonb) from public, anon;
grant execute on function public.interv_carga(jsonb) to authenticated;
