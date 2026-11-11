-- 179: FOTO DEL BUS + CARNET DEL CONDUCTOR EN CADA DESPACHO (sobre sql/178, ensayo en LOCAL, 11/11/2026).
--
-- Pedido: "también para que validen el QR del conductor, podemos hacer que tomen una foto al vehículo
-- para que la lectura sea inquebrantable, antifoto". Decisiones del usuario (11/11):
--   * Además del QR del bus se lee el QR del CARNET del conductor en cada despacho.
--   * La foto del bus se toma SEGUIDA del QR, con la misma cámara (nunca de la galería). La imagen lleva
--     pegado el recorte de donde se leyó el QR (delata una pantalla o una fotocopia), la hora y el GPS.
--   * Se compara el GPS del celular con el GPS del bus en SONAR: si están lejos, se despacha igual y
--     queda MARCADO para control (no se bloquea: hay buses con el GPS dañado o mudo).
--   * Sin QR del bus la foto sigue siendo obligatoria (salvo "La cámara no abre o no enfoca").
--
-- Lo que no se puede falsificar desde el celular es la POSICIÓN DEL BUS: la trae SONAR cada minuto
-- (ubicaciones, cron sync_ubicaciones). Por eso la base "sella" la foto en el momento en que llega:
-- guarda dónde estaba el celular, dónde estaba el bus en ese instante y la distancia. El sello se hace
-- al subir la foto (no al final del despacho), porque al despachar el bus ya puede ir saliendo.
-- Cada foto sirve para UN despacho y solo la puede usar quien la subió, para ese bus.
--
-- Nada de esto toca las 10 tablas de despacho (en uso): todo queda en despacho_qr y despacho_sello.

-- ---------------------------------------------------------------- 1) bucket de las fotos
-- Privado; solo JPEG chico (la app comprime a ~70 KB). Cada quien sube a su carpeta <uid>/...
-- Las ve solo administración (control), con URL firmada.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('despacho-fotos', 'despacho-fotos', false, 409600, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists despacho_fotos_ins on storage.objects;
create policy despacho_fotos_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'despacho-fotos' and (public.es_admin() or public.es_despachador())
              and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists despacho_fotos_sel on storage.objects;
create policy despacho_fotos_sel on storage.objects for select to authenticated
  using (bucket_id = 'despacho-fotos' and public.es_admin());

-- ---------------------------------------------------------------- 2) el sello de cada foto
create table if not exists public.despacho_sello (
  id            bigint generated always as identity primary key,
  creado_en     timestamptz not null default now(),   -- cuándo llegó a la base (lo pone la base)
  capturada_en  timestamptz,                          -- cuándo dice el celular que la tomó
  uid           uuid not null,
  email         text not null,
  vehiculo_id   bigint not null references public.vehiculos (id),
  movil         text,
  foto_path     text not null unique,                 -- una foto = un sello = un despacho
  cel_lat       double precision, cel_lon double precision, cel_precision_m integer,
  bus_lat       double precision, bus_lon double precision,
  bus_gps_en    timestamptz,                          -- hora del último reporte del bus (SONAR)
  distancia_m   integer,                              -- celular ↔ bus
  gps_estado    text not null check (gps_estado in ('CERCA', 'LEJOS', 'BUS_SIN_GPS', 'CEL_SIN_GPS', 'TARDE')),
  usado_en      timestamptz,
  despacho_qr_id bigint
);
create index if not exists despacho_sello_creado on public.despacho_sello (creado_en);
alter table public.despacho_sello enable row level security;
revoke all on public.despacho_sello from anon, authenticated;
drop policy if exists sin_vigilante on public.despacho_sello;
create policy sin_vigilante on public.despacho_sello as restrictive for all to authenticated
  using (not (select public.es_vigilante())) with check (not (select public.es_vigilante()));

-- ---------------------------------------------------------------- 3) lo nuevo en despacho_qr
alter table public.despacho_qr add column if not exists sello_id      bigint references public.despacho_sello (id);
alter table public.despacho_qr add column if not exists foto_path     text;
alter table public.despacho_qr add column if not exists foto_estado   text;    -- CON_FOTO, FALTA, NO_APLICA (cámara)
alter table public.despacho_qr add column if not exists distancia_m   integer;
alter table public.despacho_qr add column if not exists gps_estado    text;    -- el del sello
alter table public.despacho_qr add column if not exists cond_estado   text;    -- LEIDO, SIN_QR
alter table public.despacho_qr add column if not exists cond_qr_texto text;
alter table public.despacho_qr add column if not exists cond_dr_id    text;    -- conductor SONAR despachado
alter table public.despacho_qr add column if not exists cond_nombre   text;
alter table public.despacho_qr add column if not exists cond_coincide boolean; -- el carnet es de ese conductor (lo calcula la base)
alter table public.despacho_qr add column if not exists cond_motivo   text;

-- Distancia en metros entre dos puntos (haversine; no hace falta PostGIS)
create or replace function public._dist_m(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns integer language sql immutable
as $$
  select case when lat1 is null or lon1 is null or lat2 is null or lon2 is null then null else
    round(2 * 6371000 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2)
      + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2))))::integer end
$$;
revoke all on function public._dist_m(double precision, double precision, double precision, double precision) from public, anon, authenticated;

-- Margen para "lejos": 300 m + la precisión que reporta el celular (hasta 200 m más). El bus se
-- toma si reportó en los últimos 10 minutos; si no, no se puede comparar (BUS_SIN_GPS).
-- Si la foto llega más de 5 minutos después de tomada (el celular estaba sin señal), el bus ya se
-- movió y no se compara: queda TARDE, que también va a revisión.
-- ---------------------------------------------------------------- 4) sellar la foto al subirla
create or replace function public.despacho_foto_sellar(
  p_vehiculo_id bigint, p_foto_path text, p_lat double precision, p_lon double precision,
  p_precision_m integer, p_capturada_en timestamptz)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_movil text; b_lat double precision; b_lon double precision; b_en timestamptz; v_dist integer; v_estado text; v_id bigint;
begin
  if v_uid is null or not (public.es_admin() or public.es_despachador()) or not public.es_sesion_vigente() then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  select btrim(numero) into v_movil from public.vehiculos where id = p_vehiculo_id;
  if v_movil is null then return jsonb_build_object('ok', false, 'error', 'Bus inválido.'); end if;
  -- la foto: en su carpeta, subida por esta cuenta y recién subida (no una vieja)
  if coalesce(p_foto_path, '') = '' or split_part(p_foto_path, '/', 1) <> v_uid::text
     or not exists (select 1 from storage.objects o where o.bucket_id = 'despacho-fotos' and o.name = p_foto_path
                     and o.owner = v_uid and o.created_at > now() - interval '15 minutes') then
    return jsonb_build_object('ok', false, 'error', 'No llegó la foto del bus.');
  end if;
  if exists (select 1 from public.despacho_sello where foto_path = p_foto_path) then
    return jsonb_build_object('ok', false, 'error', 'Esa foto ya se usó.');
  end if;
  -- dónde está el bus AHORA según SONAR
  select u.latitude, u.longitude, (u.gps_gmt at time zone 'UTC') into b_lat, b_lon, b_en
    from public.ubicaciones u where btrim(u.movil) = v_movil
   order by u.gps_gmt desc nulls last limit 1;
  if p_capturada_en is not null and p_capturada_en < now() - interval '5 minutes' then
    v_estado := 'TARDE';
  elsif p_lat is null or p_lon is null then
    v_estado := 'CEL_SIN_GPS';
  elsif b_lat is null or b_en is null or b_en < now() - interval '10 minutes' then
    v_estado := 'BUS_SIN_GPS';
  else
    v_dist := public._dist_m(p_lat, p_lon, b_lat, b_lon);
    v_estado := case when v_dist > 300 + least(greatest(coalesce(p_precision_m, 0), 0), 200) then 'LEJOS' else 'CERCA' end;
  end if;
  if v_dist is null and p_lat is not null and b_lat is not null then
    v_dist := public._dist_m(p_lat, p_lon, b_lat, b_lon);   -- se guarda igual, como dato
  end if;
  insert into public.despacho_sello (capturada_en, uid, email, vehiculo_id, movil, foto_path, cel_lat, cel_lon, cel_precision_m,
                                     bus_lat, bus_lon, bus_gps_en, distancia_m, gps_estado)
  values (least(coalesce(p_capturada_en, now()), now()), v_uid, v_email, p_vehiculo_id, v_movil, p_foto_path, p_lat, p_lon, p_precision_m,
          b_lat, b_lon, b_en, v_dist, v_estado)
  returning id into v_id;
  -- al despachador no se le dice la distancia (no se le enseña a esquivar el control)
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;
revoke all on function public.despacho_foto_sellar(bigint, text, double precision, double precision, integer, timestamptz) from public, anon;
grant execute on function public.despacho_foto_sellar(bigint, text, double precision, double precision, integer, timestamptz) to authenticated;

-- ---------------------------------------------------------------- 5) el carnet
create or replace function public._qr_motivos_carnet()
returns text[] language sql immutable
as $$ select array['El conductor no tiene el carnet', 'Carnet dañado o ilegible', 'La cámara no abre o no enfoca'] $$;
revoke all on function public._qr_motivos_carnet() from public, anon, authenticated;

-- Texto normalizado para comparar nombres: sin tildes, solo letras y números, en mayúscula
create or replace function public._norm_alnum(p text)
returns text language sql immutable
as $$ select regexp_replace(upper(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑàèìòùÀÈÌÒÙ', 'aeiouunAEIOUUNaeiouAEIOU')), '[^A-Z0-9]', '', 'g') $$;
revoke all on function public._norm_alnum(text) from public, anon, authenticated;

-- ¿El carnet leído es de ese conductor (SONAR)? El QR del carnet trae el NOMBRE (así lo lee la app
-- desde v129); también se acepta la cédula o el código, o un JSON que los traiga.
create or replace function public._carnet_es_de(p_texto text, p_dr_id text)
returns boolean language plpgsql stable security definer set search_path to 'public'
as $$
declare c record; v_j jsonb; v_cands text[] := array[]::text[]; t text; n text; ced text; cod text;
begin
  if coalesce(btrim(p_texto), '') = '' or coalesce(p_dr_id, '') = '' then return null; end if;
  select nombre, cedula, codigo into c from public.conductores_sonar where dr_id = p_dr_id limit 1;
  if not found then return false; end if;
  begin v_j := p_texto::jsonb; exception when others then v_j := null; end;
  if v_j is not null and jsonb_typeof(v_j) = 'object' then
    select coalesce(array_agg(v), array[]::text[]) into v_cands from (
      select v_j ->> k v from unnest(array['nombre', 'name', 'conductor', 'cedula', 'documento', 'doc', 'codigo', 'id']) k) x where v is not null;
  end if;
  if cardinality(v_cands) = 0 then v_cands := array[p_texto]; end if;
  n := public._norm_alnum(c.nombre); ced := regexp_replace(coalesce(c.cedula, ''), '\D', '', 'g'); cod := public._norm_alnum(c.codigo);
  foreach t in array v_cands loop
    t := public._norm_alnum(t);
    if t = '' then continue; end if;
    if (n <> '' and (t = n or (length(n) >= 8 and position(n in t) > 0)))
       or (length(ced) >= 6 and t = ced) or (cod <> '' and t = cod) then
      return true;
    end if;
  end loop;
  return false;
end $$;
revoke all on function public._carnet_es_de(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- 6) registrar el despacho (reemplaza la de sql/178)
drop function if exists public.despacho_qr_registrar(text, text, bigint, text, text, text, timestamptz, text, text);
create or replace function public.despacho_qr_registrar(
  p_tabla text, p_fila_id text, p_vehiculo_id bigint, p_estado text, p_qr_texto text, p_motivo text,
  p_leido_en timestamptz, p_resultado text, p_regid text default null,
  p_sello_id bigint default null,
  p_cond_estado text default null, p_cond_qr_texto text default null, p_cond_dr_id text default null, p_cond_motivo text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_movil text; v_existe boolean; v_desp bigint; v_coincide boolean; v_id bigint;
  s_id bigint; s_uid uuid; s_veh bigint; s_usado timestamptz; s_creado timestamptz; s_foto text; s_dist integer; s_gps text;
  v_cond_nombre text; v_cond_coincide boolean;
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
  if p_cond_estado is not null and p_cond_estado not in ('LEIDO', 'SIN_QR') then
    return jsonb_build_object('ok', false, 'error', 'Estado del carnet inválido.');
  end if;
  if p_cond_estado = 'LEIDO' and coalesce(btrim(p_cond_qr_texto), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el texto del carnet.');
  end if;
  if p_cond_estado = 'SIN_QR' and not (p_cond_motivo = any (public._qr_motivos_carnet())) then
    return jsonb_build_object('ok', false, 'error', 'Motivo del carnet inválido.');
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
  -- el sello de la foto: de esta cuenta, de este bus, sin usar y de las últimas 3 horas
  if p_sello_id is not null then
    select id, uid, vehiculo_id, usado_en, creado_en, foto_path, distancia_m, gps_estado
      into s_id, s_uid, s_veh, s_usado, s_creado, s_foto, s_dist, s_gps
      from public.despacho_sello where id = p_sello_id for update;
    if s_id is null or s_uid <> v_uid or s_veh <> p_vehiculo_id or s_usado is not null
       or s_creado < now() - interval '3 hours' then
      return jsonb_build_object('ok', false, 'error', 'La foto no corresponde a este despacho.');
    end if;
  end if;
  select d.id into v_desp from public.despachadores d join public.perfiles p on lower(btrim(d.nombre)) = lower(btrim(p.nombre))
   where p.id = v_uid limit 1;
  v_coincide := case when p_estado = 'LEIDO' then public._qr_es_del_bus(p_qr_texto, p_vehiculo_id) end;
  if p_cond_dr_id is not null then
    select btrim(nombre) into v_cond_nombre from public.conductores_sonar where dr_id = p_cond_dr_id limit 1;
  end if;
  v_cond_coincide := case when p_cond_estado = 'LEIDO' then public._carnet_es_de(p_cond_qr_texto, p_cond_dr_id) end;
  insert into public.despacho_qr (fecha, tabla, fila_id, vehiculo_id, movil, estado, qr_texto, coincide, motivo, leido_en,
                                  resultado, sonar_regid, despachador_id, email, uid,
                                  sello_id, foto_path, foto_estado, distancia_m, gps_estado,
                                  cond_estado, cond_qr_texto, cond_dr_id, cond_nombre, cond_coincide, cond_motivo)
  values (v_hoy, p_tabla, p_fila_id, p_vehiculo_id, v_movil, p_estado, left(btrim(p_qr_texto), 300), v_coincide,
          case when p_estado = 'SIN_QR' then p_motivo end, coalesce(p_leido_en, now()), left(p_resultado, 40), p_regid,
          v_desp, v_email, v_uid,
          s_id, s_foto,
          case when s_id is not null then 'CON_FOTO'
               when p_estado = 'SIN_QR' and p_motivo = 'La cámara no abre o no enfoca' then 'NO_APLICA'
               else 'FALTA' end,
          s_dist, s_gps,
          p_cond_estado, left(btrim(p_cond_qr_texto), 300), p_cond_dr_id, v_cond_nombre, v_cond_coincide,
          case when p_cond_estado = 'SIN_QR' then p_cond_motivo end)
  returning id into v_id;
  if s_id is not null then
    update public.despacho_sello set usado_en = now(), despacho_qr_id = v_id where id = s_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'coincide', v_coincide, 'cond_coincide', v_cond_coincide);
end $$;
revoke all on function public.despacho_qr_registrar(text, text, bigint, text, text, text, timestamptz, text, text, bigint, text, text, text, text) from public, anon;
grant execute on function public.despacho_qr_registrar(text, text, bigint, text, text, text, timestamptz, text, text, bigint, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------- 7) control (reemplaza la de sql/178)
-- Suma: fotos (con / faltó), GPS (lejos / bus sin GPS / celular sin GPS), carnet (leído / sin carnet /
-- no era de ese conductor). "revisar" trae todo lo que control debe mirar, con la ruta de la foto.
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
  return (with q as (select * from public.despacho_qr where fecha between p_desde and p_hasta)
  select jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
    'lecturas', (select count(*) from q),
    'leidos', (select count(*) from q where estado = 'LEIDO'),
    'sin_qr', (select count(*) from q where estado = 'SIN_QR'),
    'no_coincide', (select count(*) from q where estado = 'LEIDO' and coincide is false),
    'por_motivo', (select coalesce(jsonb_object_agg(motivo, n), '{}'::jsonb) from (
                     select motivo, count(*) n from q where estado = 'SIN_QR' group by 1) m),
    'fotos', jsonb_build_object(
       'con_foto', (select count(*) from q where foto_estado = 'CON_FOTO'),
       'falta', (select count(*) from q where foto_estado = 'FALTA'),
       'lejos', (select count(*) from q where gps_estado = 'LEJOS'),
       'bus_sin_gps', (select count(*) from q where gps_estado = 'BUS_SIN_GPS'),
       'cel_sin_gps', (select count(*) from q where gps_estado = 'CEL_SIN_GPS'),
       'tarde', (select count(*) from q where gps_estado = 'TARDE')),
    'carnet', jsonb_build_object(
       'leidos', (select count(*) from q where cond_estado = 'LEIDO'),
       'sin_carnet', (select count(*) from q where cond_estado = 'SIN_QR'),
       'no_coincide', (select count(*) from q where cond_estado = 'LEIDO' and cond_coincide is false),
       'por_motivo', (select coalesce(jsonb_object_agg(cond_motivo, n), '{}'::jsonb) from (
                        select cond_motivo, count(*) n from q where cond_estado = 'SIN_QR' group by 1) m)),
    'por_despachador', (select coalesce(jsonb_agg(x order by x.sin_qr + x.lejos desc, x.total desc), '[]'::jsonb) from (
                          select coalesce(d.nombre, q.email) despachador, count(*) total,
                                 count(*) filter (where q.estado = 'SIN_QR') sin_qr,
                                 count(*) filter (where q.coincide is false) no_coincide,
                                 count(*) filter (where q.gps_estado = 'LEJOS') lejos,
                                 count(*) filter (where q.foto_estado = 'FALTA') sin_foto,
                                 count(*) filter (where q.cond_estado = 'SIN_QR') sin_carnet
                            from q left join public.despachadores d on d.id = q.despachador_id group by 1) x),
    'tablas', v_sin,
    'revisar', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', q.id, 'fecha', q.fecha, 'hora', to_char(q.creado_en at time zone 'America/Bogota', 'HH24:MI'), 'tabla', q.tabla,
                  'movil', q.movil, 'estado', q.estado, 'motivo', q.motivo, 'qr_texto', q.qr_texto, 'coincide', q.coincide,
                  'resultado', q.resultado, 'foto_path', q.foto_path, 'foto_estado', q.foto_estado,
                  'distancia_m', q.distancia_m, 'gps_estado', q.gps_estado,
                  'cond_estado', q.cond_estado, 'cond_nombre', q.cond_nombre, 'cond_coincide', q.cond_coincide, 'cond_motivo', q.cond_motivo,
                  'despachador', coalesce(d.nombre, q.email)) order by q.creado_en desc), '[]'::jsonb)
                  from q left join public.despachadores d on d.id = q.despachador_id
                 where q.estado = 'SIN_QR' or q.coincide is false or q.foto_estado = 'FALTA' or q.gps_estado in ('LEJOS', 'TARDE')
                    or q.cond_estado = 'SIN_QR' or q.cond_coincide is false),
    -- una muestra de las fotos buenas, para revisarlas a ojo de vez en cuando
    'muestra', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'hora', x.hora, 'movil', x.movil, 'foto_path', x.foto_path,
                   'distancia_m', x.distancia_m, 'despachador', x.despachador)), '[]'::jsonb) from (
                  select q.id, to_char(q.creado_en at time zone 'America/Bogota', 'DD/MM HH24:MI') hora, q.movil, q.foto_path, q.distancia_m,
                         coalesce(d.nombre, q.email) despachador
                    from q left join public.despachadores d on d.id = q.despachador_id
                   where q.foto_estado = 'CON_FOTO' and q.gps_estado = 'CERCA' order by random() limit 12) x)));
end $$;
revoke all on function public.despacho_qr_control(date, date) from public, anon;
grant execute on function public.despacho_qr_control(date, date) to authenticated;
