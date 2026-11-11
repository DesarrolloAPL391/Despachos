-- 178: QR OBLIGATORIO EN CADA VIAJE DESPACHADO (ensayo en LOCAL, 11/11/2026).
--
-- Pedido: "cómo podemos obligar a los despachadores a leer código QR por viaje despachado, tanto por
-- tabla como por despacho libre, en todas las tablas; hagámoslo en local primero para ensayar".
-- Decisiones del usuario (11/11):
--   * Se lee SOLO el QR del bus (el sticker que imprime la app: trae la PLACA).
--   * Si no se puede leer (sticker dañado, bus sin sticker, cámara que no abre): se despacha igual con
--     un MOTIVO, sin foto, y queda marcado para control.
--   * En una fila de tabla, el bus leído TIENE QUE COINCIDIR con el de la fila; para despachar otro bus
--     hay que editar la fila primero. En el despacho libre el QR es el que dice qué bus sale.
--
-- Cada lectura queda en despacho_qr (tabla aparte: no se tocan las 10 tablas de despacho, que están
-- en uso, y la app publicada sigue igual mientras se ensaya). La base recalcula si el texto leído
-- corresponde al bus despachado (no se le cree al celular).
-- Nadie lee ni escribe la tabla directo: solo por las funciones.
-- Después, al publicar, se puede exigir también en la base (un trigger en las tablas de despacho que
-- no deje marcar despachado sin lectura); hoy no, porque la app publicada no lee el QR.

create table if not exists public.despacho_qr (
  id             bigint generated always as identity primary key,
  creado_en      timestamptz not null default now(),
  fecha          date not null,                 -- día del despacho (Colombia)
  tabla          text not null,                 -- 'despachos', la tabla de puesto, o 'mapa' (despacho sin fila)
  fila_id        text,                          -- id de la fila despachada (null: desde el mapa)
  vehiculo_id    bigint references public.vehiculos (id),
  movil          text,
  estado         text not null check (estado in ('LEIDO', 'SIN_QR')),
  qr_texto       text,                          -- lo que trae el sticker
  coincide       boolean,                       -- el texto leído es de ese bus (lo calcula la base)
  motivo         text,                          -- por qué no se leyó (SIN_QR)
  leido_en       timestamptz,                   -- cuándo se leyó en el celular
  resultado      text,                          -- DESPACHADO, PENDIENTE SONAR, REGISTRADO, REALIZADO, CREADO
  sonar_regid    text,
  despachador_id bigint,
  email          text not null,
  uid            uuid not null
);
create index if not exists despacho_qr_fecha on public.despacho_qr (fecha);
create index if not exists despacho_qr_fila on public.despacho_qr (tabla, fila_id);
alter table public.despacho_qr enable row level security;
revoke all on public.despacho_qr from anon, authenticated;
-- como todas las tablas (sql/177): el vigilante no la toca
drop policy if exists sin_vigilante on public.despacho_qr;
create policy sin_vigilante on public.despacho_qr as restrictive for all to authenticated
  using (not (select public.es_vigilante())) with check (not (select public.es_vigilante()));

-- Los motivos aceptados cuando no se lee el QR
create or replace function public._qr_motivos()
returns text[] language sql immutable
as $$ select array['Sticker dañado o ilegible', 'El bus no tiene sticker', 'La cámara no abre o no enfoca'] $$;
revoke all on function public._qr_motivos() from public, anon, authenticated;   -- solo la usa despacho_qr_registrar

-- ¿El texto del QR es de ese bus? Placa exacta, número exacto, o la placa dentro del texto (URL, JSON)
create or replace function public._qr_es_del_bus(p_texto text, p_vehiculo_id bigint)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select case when coalesce(p_texto, '') = '' then null else exists (
    select 1 from public.vehiculos v
     cross join lateral (select regexp_replace(upper(p_texto), '[^A-Z0-9]', '', 'g') t,
                                regexp_replace(upper(coalesce(v.placa, '')), '[^A-Z0-9]', '', 'g') p,
                                regexp_replace(upper(coalesce(v.numero, '')), '[^A-Z0-9]', '', 'g') n) x
     where v.id = p_vehiculo_id
       and ((x.p <> '' and x.t = x.p) or (x.n <> '' and x.t = x.n) or (length(x.p) >= 5 and position(x.p in x.t) > 0))) end;
$$;
revoke all on function public._qr_es_del_bus(text, bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------- registrar la lectura de un despacho
create or replace function public.despacho_qr_registrar(
  p_tabla text, p_fila_id text, p_vehiculo_id bigint, p_estado text, p_qr_texto text, p_motivo text,
  p_leido_en timestamptz, p_resultado text, p_regid text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_movil text; v_existe boolean; v_desp bigint; v_coincide boolean; v_id bigint;
begin
  if v_uid is null or not (public.es_admin() or public.es_despachador()) or not public.es_sesion_vigente() then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  if p_estado not in ('LEIDO', 'SIN_QR') then
    return jsonb_build_object('ok', false, 'error', 'Estado del QR inválido.');
  end if;
  if p_estado = 'LEIDO' and coalesce(btrim(p_qr_texto), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el texto del QR.');
  end if;
  if p_estado = 'SIN_QR' and not (p_motivo = any (public._qr_motivos())) then
    return jsonb_build_object('ok', false, 'error', 'Motivo inválido.');
  end if;
  -- la tabla: 'despachos', una tabla de despacho registrada, o 'mapa' (despacho sin fila)
  if p_tabla = 'mapa' then
    if p_fila_id is not null then return jsonb_build_object('ok', false, 'error', 'Un despacho del mapa no tiene fila.'); end if;
  elsif p_tabla = 'despachos' or exists (select 1 from public.tablas_despacho where tabla = p_tabla) then
    execute format('select exists (select 1 from public.%I where id::text = $1)', p_tabla) into v_existe using p_fila_id;
    if not coalesce(v_existe, false) then return jsonb_build_object('ok', false, 'error', 'No existe esa fila.'); end if;
  else
    return jsonb_build_object('ok', false, 'error', 'Tabla inválida.');
  end if;
  select btrim(numero) into v_movil from public.vehiculos where id = p_vehiculo_id;
  if v_movil is null then return jsonb_build_object('ok', false, 'error', 'Bus inválido.'); end if;
  select d.id into v_desp from public.despachadores d join public.perfiles p on lower(btrim(d.nombre)) = lower(btrim(p.nombre))
   where p.id = v_uid limit 1;
  v_coincide := case when p_estado = 'LEIDO' then public._qr_es_del_bus(p_qr_texto, p_vehiculo_id) end;
  insert into public.despacho_qr (fecha, tabla, fila_id, vehiculo_id, movil, estado, qr_texto, coincide, motivo, leido_en,
                                  resultado, sonar_regid, despachador_id, email, uid)
  values (v_hoy, p_tabla, p_fila_id, p_vehiculo_id, v_movil, p_estado, left(btrim(p_qr_texto), 300), v_coincide,
          case when p_estado = 'SIN_QR' then p_motivo end, coalesce(p_leido_en, now()), left(p_resultado, 40), p_regid,
          v_desp, v_email, v_uid)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'coincide', v_coincide);
end $$;
revoke all on function public.despacho_qr_registrar(text, text, bigint, text, text, text, timestamptz, text, text) from public, anon;
grant execute on function public.despacho_qr_registrar(text, text, bigint, text, text, text, timestamptz, text, text) to authenticated;

-- ---------------------------------------------------------------- control (administración, por ahora)
-- Por día: cuántos despachos se hicieron con QR, cuántos sin QR (y por qué), los que no coincidían,
-- por despachador, y cuántos despachos de las tablas NO tienen lectura (con la app publicada, que aún
-- no lee el QR, son todos: sirve para ver el antes y el después).
create or replace function public.despacho_qr_control(p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  t record; n_total bigint; n_sin bigint; v_sin jsonb := '[]'::jsonb;
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración.');
  end if;
  if p_hasta < p_desde or p_hasta - p_desde > 62 then
    return jsonb_build_object('ok', false, 'error', 'Elige un rango de hasta 2 meses.');
  end if;
  -- despachos marcados como hechos en cada tabla, y cuántos sin lectura de QR
  for t in select 'despachos' tabla, 'Despachos' label union all select tabla, label from public.tablas_despacho where activo loop
    execute format($q$
      select count(*), count(*) filter (where not exists (select 1 from public.despacho_qr q where q.tabla = %L and q.fila_id = x.id::text))
        from public.%I x
       where x.fecha between $1 and $2
         and upper(coalesce(x.estado_despacho, '')) in ('SI', 'DESPACHADO', 'PENDIENTE SONAR')$q$, t.tabla, t.tabla)
      into n_total, n_sin using p_desde, p_hasta;
    if n_total > 0 then
      v_sin := v_sin || jsonb_build_object('tabla', t.tabla, 'label', t.label, 'despachos', n_total, 'sin_lectura', n_sin);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
    'lecturas', (select count(*) from public.despacho_qr where fecha between p_desde and p_hasta),
    'leidos', (select count(*) from public.despacho_qr where fecha between p_desde and p_hasta and estado = 'LEIDO'),
    'sin_qr', (select count(*) from public.despacho_qr where fecha between p_desde and p_hasta and estado = 'SIN_QR'),
    'no_coincide', (select count(*) from public.despacho_qr where fecha between p_desde and p_hasta and estado = 'LEIDO' and coincide is false),
    'por_motivo', (select coalesce(jsonb_object_agg(motivo, n), '{}'::jsonb) from (
                     select motivo, count(*) n from public.despacho_qr where fecha between p_desde and p_hasta and estado = 'SIN_QR' group by 1) m),
    'por_despachador', (select coalesce(jsonb_agg(x order by x.sin_qr desc, x.total desc), '[]'::jsonb) from (
                          select coalesce(d.nombre, q.email) despachador, count(*) total,
                                 count(*) filter (where q.estado = 'SIN_QR') sin_qr,
                                 count(*) filter (where q.coincide is false) no_coincide
                            from public.despacho_qr q left join public.despachadores d on d.id = q.despachador_id
                           where q.fecha between p_desde and p_hasta group by 1) x),
    'tablas', v_sin,
    -- el detalle de lo que control debe revisar: sin QR y QR que no era del bus
    'revisar', (select coalesce(jsonb_agg(jsonb_build_object(
                  'fecha', q.fecha, 'hora', to_char(q.creado_en at time zone 'America/Bogota', 'HH24:MI'), 'tabla', q.tabla,
                  'movil', q.movil, 'estado', q.estado, 'motivo', q.motivo, 'qr_texto', q.qr_texto, 'resultado', q.resultado,
                  'despachador', coalesce(d.nombre, q.email)) order by q.creado_en desc), '[]'::jsonb)
                  from public.despacho_qr q left join public.despachadores d on d.id = q.despachador_id
                 where q.fecha between p_desde and p_hasta and (q.estado = 'SIN_QR' or q.coincide is false)));
end $$;
revoke all on function public.despacho_qr_control(date, date) from public, anon;
grant execute on function public.despacho_qr_control(date, date) to authenticated;
