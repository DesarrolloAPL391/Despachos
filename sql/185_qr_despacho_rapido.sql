-- 185: ⚡ DESPACHO RÁPIDO CON EL QR DEL BUS (12/11/2026).
--
-- Pedido: "en el segundo viaje va a pedir el código QR del bus y del conductor (si no lo tiene, sigue igual: reporta para
-- no parar la operación). Lo nuevo: va a hacer despachos por medio de QR solo leyendo el QR del vehículo y el conductor lo
-- trae de la lectura del segundo; no es necesario que lo vuelva a escanear, o si lo colocó en la lista porque no tiene
-- código QR, queda organizado". Decisiones del usuario (12/11):
--   * del 3.er viaje en adelante leer el QR del bus es OPCIONAL (una forma rápida); la lista sigue disponible;
--   * si en la tarde cambia el conductor, se cambia desde la lista y queda MARCADO como cambio de conductor para el monitor;
--   * vale en Nuevo despacho y en las tablas de puesto (✈️).
-- Lo de la base (todo NUEVO; no cambia nada de lo que usa la app publicada):
--   * _conductor_viaje2(bus, fecha): el conductor del viaje del QR (despacho_qr_config.solo_viaje, hoy el 2.º) de ese bus
--     ese día. Primero la LECTURA de ese viaje (el carnet leído, o el que eligieron de la lista porque no tenía carnet); si
--     no la hay, el conductor que quedó en la fila de ese viaje (por hora de despacho, en todas las tablas).
--   * despacho_conductor_viaje2: lo mismo para la app (despachadores y administración).
--   * despacho_qr_rapido + despacho_qr_rapido_registrar: queda cada despacho rápido: el QR leído, el conductor del 2.º
--     viaje (lo vuelve a buscar la base, no se le cree al celular), con quién salió y si CAMBIÓ el conductor.
--     Aparte de despacho_qr a propósito: así el tablero del QR del 2.º viaje no cambia.
--   * despacho_qr_rapido_resumen: para la pantalla de control (administración: todas las rutas; el monitor: las suyas).
-- Al aplicar: una petición, con lock_timeout. No tiene llaves foráneas (no bloquea vehiculos ni despacho_qr).

-- ---------------------------------------------------------------- 1) la tabla
create table if not exists public.despacho_qr_rapido (
  id               bigint generated always as identity primary key,
  creado_en        timestamptz not null default now(),
  fecha            date not null,                 -- día del despacho (Colombia)
  tabla            text not null,                 -- 'despachos', la tabla de puesto, o 'mapa'
  fila_id          text,
  ruta_id          bigint,                        -- la de la fila (para que el monitor vea solo sus rutas)
  vehiculo_id      bigint,
  movil            text,
  viaje            smallint,                      -- el número de viaje de hoy del bus (lo contó la base al despachar)
  qr_texto         text,                          -- lo que trae el sticker
  coincide         boolean,                       -- el QR es de ese bus (lo calcula la base)
  leido_en         timestamptz,
  v2_origen        text,                          -- CARNET, LISTA (sin carnet), DESPACHO (sin lectura); null = no se encontró
  v2_dr_id         text,                          -- el conductor del 2.º viaje
  v2_nombre        text,
  v2_hora          text,
  cond_dr_id       text,                          -- con quién salió
  cond_nombre      text,
  cambio_conductor boolean not null default false,
  resultado        text,                          -- DESPACHADO, PENDIENTE SONAR, REGISTRADO, REALIZADO, CREADO
  sonar_regid      text,
  despachador_id   bigint,
  email            text not null,
  uid              uuid not null
);
create index if not exists despacho_qr_rapido_fecha on public.despacho_qr_rapido (fecha);
create index if not exists despacho_qr_rapido_fila on public.despacho_qr_rapido (tabla, fila_id);
alter table public.despacho_qr_rapido enable row level security;
revoke all on public.despacho_qr_rapido from anon, authenticated;   -- nadie la toca directo: solo por las funciones
drop policy if exists sin_vigilante on public.despacho_qr_rapido;
create policy sin_vigilante on public.despacho_qr_rapido as restrictive for all to authenticated
  using (not (select public.es_vigilante())) with check (not (select public.es_vigilante()));

-- ---------------------------------------------------------------- 2) el conductor del 2.º viaje (interna)
create or replace function public._conductor_viaje2(p_vehiculo_id bigint, p_fecha date)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_solo int; v_desde timestamptz; v_union text;
  q_id bigint; q_dr text; q_estado text; q_en timestamptz;
  f_tabla text; f_fila text; f_hora time; f_cond bigint;
  v_nombre text; v_dr text;
begin
  select c.solo_viaje, c.solo_viaje_desde into v_solo, v_desde from public.despacho_qr_config c where c.id = 1;
  v_solo := greatest(coalesce(v_solo, 2), 1);
  -- 1) la lectura del viaje del QR: desde que rige la regla, solo ese viaje registra lectura → la última de ese bus ese día
  select x.id, x.cond_dr_id, x.cond_estado, coalesce(x.leido_en, x.creado_en) into q_id, q_dr, q_estado, q_en
    from public.despacho_qr x
   where x.fecha = p_fecha and x.vehiculo_id = p_vehiculo_id and x.cond_dr_id is not null
     and x.creado_en >= coalesce(v_desde, '-infinity'::timestamptz)
   order by x.creado_en desc limit 1;
  if q_id is null then
    -- 2) sin esa lectura: el viaje N.º solo_viaje del bus (por hora de despacho, en todas las tablas) …
    select string_agg(format(
      $f$select %L::text tabla, x.id::text fila_id, coalesce(x.hora_real_despacho, x.hora) hora, x.conductor_id
           from public.%I x
          where x.fecha = $1 and x.vehiculo_id = $2
            and upper(coalesce(x.estado_despacho, '')) in ('SI', 'DESPACHADO', 'PENDIENTE SONAR', 'REALIZADO')$f$, t.tabla, t.tabla), ' union all ')
      into v_union
      from (select 'despachos' tabla union all select tabla from public.tablas_despacho where activo) t;
    execute format('select u.tabla, u.fila_id, u.hora, u.conductor_id from (%s) u order by u.hora nulls last, u.tabla, u.fila_id offset %s limit 1',
                   v_union, v_solo - 1)
      into f_tabla, f_fila, f_hora, f_cond using p_fecha, p_vehiculo_id;
    if f_fila is null then
      return jsonb_build_object('encontrado', false);
    end if;
    -- … con su lectura, si la tiene (la regla se prendió después de ese viaje) …
    select x.id, x.cond_dr_id, x.cond_estado, coalesce(x.leido_en, x.creado_en) into q_id, q_dr, q_estado, q_en
      from public.despacho_qr x
     where x.tabla = f_tabla and x.fila_id = f_fila and x.cond_dr_id is not null
     order by x.creado_en desc limit 1;
  end if;
  if q_id is not null then
    select btrim(s.nombre) into v_nombre from public.conductores_sonar s where s.dr_id = q_dr limit 1;
    return jsonb_build_object('encontrado', true, 'origen', case when q_estado = 'LEIDO' then 'CARNET' else 'LISTA' end,
      'dr_id', q_dr, 'nombre', v_nombre, 'hora', to_char(q_en at time zone 'America/Bogota', 'HH24:MI'), 'qr_id', q_id);
  end if;
  -- … y si no, el conductor que quedó en la fila (se busca en SONAR por el nombre)
  if f_cond is null then
    return jsonb_build_object('encontrado', false);
  end if;
  select btrim(c.nombre) into v_nombre from public.conductores c where c.id = f_cond;
  select s.dr_id into v_dr from public.conductores_sonar s
   where public._norm_alnum(s.nombre) = public._norm_alnum(v_nombre)
   order by (upper(coalesce(s.status, '')) = 'ENABLED') desc, s.id limit 1;
  return jsonb_build_object('encontrado', v_nombre is not null, 'origen', 'DESPACHO', 'dr_id', v_dr, 'nombre', v_nombre,
    'hora', to_char(f_hora, 'HH24:MI'));
end $$;
revoke all on function public._conductor_viaje2(bigint, date) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3) para la app: ¿con quién hizo el 2.º viaje este bus hoy?
create or replace function public.despacho_conductor_viaje2(p_vehiculo_id bigint, p_fecha date)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if auth.uid() is null or not (public.es_admin() or public.es_despachador()) then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  if p_vehiculo_id is null or p_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el bus o la fecha.');
  end if;
  return jsonb_build_object('ok', true) || public._conductor_viaje2(p_vehiculo_id, p_fecha);
end $$;
revoke all on function public.despacho_conductor_viaje2(bigint, date) from public, anon;
grant execute on function public.despacho_conductor_viaje2(bigint, date) to authenticated;

-- ---------------------------------------------------------------- 4) registrar un despacho rápido
create or replace function public.despacho_qr_rapido_registrar(
  p_tabla text, p_fila_id text, p_vehiculo_id bigint, p_qr_texto text, p_leido_en timestamptz,
  p_viaje integer, p_cond_dr_id text, p_resultado text, p_regid text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_movil text; v_existe boolean; v_ruta bigint; v_desp bigint; v_v2 jsonb; v_cond_nombre text; v_cambio boolean; v_id bigint;
begin
  if v_uid is null or not (public.es_admin() or public.es_despachador()) or not public.es_sesion_vigente() then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  if coalesce(btrim(p_qr_texto), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el texto del QR.');
  end if;
  if p_viaje is not null and (p_viaje < 1 or p_viaje > 60) then
    return jsonb_build_object('ok', false, 'error', 'Número de viaje inválido.');
  end if;
  -- la tabla: 'despachos', una tabla de despacho registrada, o 'mapa' (despacho sin fila)
  if p_tabla = 'mapa' then
    if p_fila_id is not null then return jsonb_build_object('ok', false, 'error', 'Un despacho del mapa no tiene fila.'); end if;
  elsif p_tabla = 'despachos' or exists (select 1 from public.tablas_despacho where tabla = p_tabla) then
    execute format('select true, x.ruta_id from public.%I x where x.id::text = $1', p_tabla) into v_existe, v_ruta using p_fila_id;
    if not coalesce(v_existe, false) then return jsonb_build_object('ok', false, 'error', 'No existe esa fila.'); end if;
  else
    return jsonb_build_object('ok', false, 'error', 'Tabla inválida.');
  end if;
  select btrim(numero) into v_movil from public.vehiculos where id = p_vehiculo_id;
  if v_movil is null then return jsonb_build_object('ok', false, 'error', 'Bus inválido.'); end if;
  select d.id into v_desp from public.despachadores d join public.perfiles p on lower(btrim(d.nombre)) = lower(btrim(p.nombre))
   where p.id = v_uid limit 1;
  if p_cond_dr_id is not null then
    select btrim(nombre) into v_cond_nombre from public.conductores_sonar where dr_id = p_cond_dr_id limit 1;
  end if;
  -- el conductor del 2.º viaje lo busca la base otra vez, y ella decide si cambió
  v_v2 := public._conductor_viaje2(p_vehiculo_id, v_hoy);
  v_cambio := coalesce((v_v2 ->> 'encontrado')::boolean, false) and p_cond_dr_id is not null and (
    case when v_v2 ->> 'dr_id' is not null then p_cond_dr_id is distinct from (v_v2 ->> 'dr_id')
         else public._norm_alnum(v_cond_nombre) is distinct from public._norm_alnum(v_v2 ->> 'nombre') end);
  insert into public.despacho_qr_rapido (fecha, tabla, fila_id, ruta_id, vehiculo_id, movil, viaje, qr_texto, coincide, leido_en,
                                         v2_origen, v2_dr_id, v2_nombre, v2_hora, cond_dr_id, cond_nombre, cambio_conductor,
                                         resultado, sonar_regid, despachador_id, email, uid)
  values (v_hoy, p_tabla, p_fila_id, v_ruta, p_vehiculo_id, v_movil, p_viaje, left(btrim(p_qr_texto), 300),
          public._qr_es_del_bus(p_qr_texto, p_vehiculo_id), coalesce(p_leido_en, now()),
          case when coalesce((v_v2 ->> 'encontrado')::boolean, false) then v_v2 ->> 'origen' end,
          v_v2 ->> 'dr_id', v_v2 ->> 'nombre', v_v2 ->> 'hora', p_cond_dr_id, v_cond_nombre, coalesce(v_cambio, false),
          left(p_resultado, 40), p_regid, v_desp, v_email, v_uid)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'cambio_conductor', coalesce(v_cambio, false));
end $$;
revoke all on function public.despacho_qr_rapido_registrar(text, text, bigint, text, timestamptz, integer, text, text, text) from public, anon;
grant execute on function public.despacho_qr_rapido_registrar(text, text, bigint, text, timestamptz, integer, text, text, text) to authenticated;

-- ---------------------------------------------------------------- 5) para la pantalla de control
create or replace function public.despacho_qr_rapido_resumen(p_desde date, p_hasta date, p_rutas bigint[] default null, p_ruta bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_admin boolean := public.es_admin();
  v_scope bigint[];
begin
  if not (v_admin or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y control.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 31 then
    return jsonb_build_object('ok', false, 'error', 'Elige un rango de hasta un mes.');
  end if;
  if v_admin then
    v_scope := case when cardinality(p_rutas) > 0 then p_rutas end;      -- null = todas
  else
    v_scope := public.rutas_auditor();
    if coalesce(cardinality(v_scope), 0) = 0 then
      return jsonb_build_object('ok', true, 'sin_rutas', true);
    end if;
  end if;
  return (
    with x as (
      select r.*, coalesce(ru.nombre, '(sin ruta)') ruta, coalesce(d.nombre, p.nombre, 'Cuenta sin nombre') despachador
        from public.despacho_qr_rapido r
        left join public.rutas ru on ru.id = r.ruta_id
        left join public.despachadores d on d.id = r.despachador_id
        left join public.perfiles p on p.id = r.uid
       where r.fecha between p_desde and p_hasta
         and (v_scope is null or r.ruta_id = any (v_scope))
         and (p_ruta is null or r.ruta_id = p_ruta))
    select jsonb_build_object('ok', true,
      'total', count(*),
      'con_v2', count(*) filter (where v2_origen is not null),
      'sin_v2', count(*) filter (where v2_origen is null),
      'cambios', count(*) filter (where cambio_conductor),
      'qr_otro_bus', count(*) filter (where coincide is false),
      'cambios_lista', (select coalesce(jsonb_agg(jsonb_build_object(
            'fecha', y.fecha, 'hora', to_char(y.creado_en at time zone 'America/Bogota', 'HH24:MI'), 'ruta', y.ruta, 'tabla', y.tabla,
            'movil', y.movil, 'viaje', y.viaje, 'v2_nombre', y.v2_nombre, 'v2_origen', y.v2_origen, 'v2_hora', y.v2_hora,
            'cond_nombre', y.cond_nombre, 'despachador', y.despachador) order by y.creado_en desc), '[]'::jsonb)
          from (select * from x where cambio_conductor order by creado_en desc limit 300) y))
    from x);
end $$;
revoke all on function public.despacho_qr_rapido_resumen(date, date, bigint[], bigint) from public, anon;
grant execute on function public.despacho_qr_rapido_resumen(date, date, bigint[], bigint) to authenticated;
