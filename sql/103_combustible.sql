-- ===================================================================================
-- 103: COMBUSTIBLE — los tanqueos traídos del SCA (Speed Control Advanced) de la EDS.
-- ===================================================================================
-- APL tanquea en una estación AJENA. Aquí SOLO SE LEE.
--
-- NUNCA llamar TransactionMarkAsSend ni ElectronicInvoiceMarkAsSend.
--   En el SCA esos endpoints no "marcan" para nosotros: SACAN la transacción de la cola
--   de la estación. El contador de la EDS exporta sus ventas de esa misma cola. Si la
--   marcamos, a ellos les desaparece la venta y no van a saber por qué.
--   Por eso todo lo de aquí usa el endpoint POR RANGO DE FECHA, que no consume la cola.
--
-- Privacidad: la consulta por rango devuelve los tanqueos de TODOS los clientes de la
-- estación, no solo los nuestros. Se guardan únicamente los de placas del parque de APL
-- y el resto se descarta en el acto: esa información no es nuestra.
--
-- Autenticación: /api/Transactions/ va con usuario y clave (Basic). Los de
-- /api/TransactionsV2/ piden un token JWT de POST /Auth, y no los necesitamos: son los
-- de facturación electrónica, que le corresponden a la estación.

create extension if not exists http with schema extensions;

-- ---------- Credenciales: en Vault, NUNCA en este archivo (el repo es público) ----------
-- Pégalas una vez en el SQL Editor, reemplazando lo que va entre < >:
--   select vault.create_secret('https://main.speedsol.com/SCADEMOV7', 'SCA_URL');
--   select vault.create_secret('<usuario>', 'SCA_USER');
--   select vault.create_secret('<clave>',   'SCA_PASSWORD');
-- Para cambiarlas después:
--   select vault.update_secret((select id from vault.secrets where name='SCA_PASSWORD'), '<nueva>');

-- ---------- Cuál estación es la nuestra ----------
create table if not exists public.combustible_config (
  id               int primary key default 1 check (id = 1),
  id_punto_venta   int,                          -- idPointOfSale del SCA (lo da GetStationList)
  estacion         text,                         -- nombre, para mostrarlo
  lat              numeric,                      -- dónde queda: sirve para comprobar contra el GPS
  lon              numeric,                      --   que el bus estaba ahí a la hora del tanqueo
  radio_m          int     not null default 250, -- metros alrededor que cuentan como "en la estación"
  galones_max      numeric not null default 60,  -- un tanqueo mayor a esto es sospechoso
  rend_min         numeric not null default 3,   -- km/galón: por debajo, algo pasa
  rend_max         numeric not null default 14,  -- por encima, el odómetro miente
  actualizado_en   timestamptz not null default now()
);
insert into public.combustible_config (id) values (1) on conflict (id) do nothing;

-- ---------- Los tanqueos ----------
-- La clave natural es el Id del SCA: es el consecutivo de la venta en su base de datos.
create table if not exists public.combustible_tanqueos (
  id_sca            bigint primary key,           -- Id de la transacción en el SCA
  id_punto_venta    int,
  estacion          text,
  placa             text not null,
  movil             text,                         -- número interno, resuelto contra el parque
  inicio            timestamptz not null,         -- StartDate: cuándo empezó a caer el combustible
  fin               timestamptz,                  -- EndDate
  fecha             date generated always as ((inicio at time zone 'America/Bogota')::date) stored,
  cantidad          numeric not null,
  unidad            text,                         -- "L" o "G", según cómo venda la estación
  galones           numeric generated always as (
                      case when upper(coalesce(unidad, '')) = 'L'
                           then round(cantidad / 3.785411784, 3)
                           else round(cantidad, 3) end) stored,
  producto          text,
  precio            numeric,
  total             numeric,
  surtidor          text,                         -- DispenserName
  manguera          text,                         -- NozzleName
  odometro          numeric,                      -- lo que digitaron en la estación (suele venir 0)
  odometro_previo   numeric,
  rendimiento_sca   numeric,                      -- Performance: lo calcula el SCA si hay odómetro
  flota             text,
  cliente           text,
  identificador     text,                         -- EquipmentIdentifier (iButton / RFID / tag)
  numero_trans      bigint,                       -- TransactionNumber
  documento         text,                         -- DocumentNumber (la factura)
  crudo             jsonb,                        -- la fila completa, por si mañana sirve algo más
  traido_en         timestamptz not null default now()
);
create index if not exists comb_fecha_idx on public.combustible_tanqueos (fecha desc);
create index if not exists comb_movil_idx on public.combustible_tanqueos (movil, fecha desc);
create index if not exists comb_placa_idx on public.combustible_tanqueos (placa);

-- ---------- Quién ve qué ----------
alter table public.combustible_config   enable row level security;
alter table public.combustible_tanqueos enable row level security;

drop policy if exists comb_cfg_sel on public.combustible_config;
create policy comb_cfg_sel on public.combustible_config for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor()) );

drop policy if exists comb_cfg_all on public.combustible_config;
create policy comb_cfg_all on public.combustible_config for all to authenticated
  using ( (select public.es_admin()) ) with check ( (select public.es_admin()) );

-- Admin, operaciones y auditores ven todo. El afiliado ve SOLO sus carros.
drop policy if exists comb_sel on public.combustible_tanqueos;
create policy comb_sel on public.combustible_tanqueos for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor())
       or ( (select public.es_afiliado()) and movil = any (public.mis_moviles_afiliado()) ) );

-- Nadie escribe a mano: esto lo llena la función de abajo (security definer).
revoke insert, update, delete on public.combustible_tanqueos from authenticated;

-- ---------- Quién puede disparar la traída ----------
-- es_admin() lee el JWT del usuario logueado. Pero estas funciones también se llaman
-- desde donde NO hay JWT: el SQL Editor (tú, dueño de la base) y pg_cron (la traída
-- nocturna). Sin esto, el cron fallaría todas las noches con "Solo administración".
--
-- session_user es el rol con el que se ABRIÓ la conexión, no el que está activo: desde
-- la app siempre es 'authenticator' aunque la función corra como su dueño. Por eso sirve
-- para distinguir una conexión directa de DBA de una llamada de la aplicación.
-- Y se exige además que no haya sesión (auth.uid() is null): si hay usuario logueado,
-- manda es_admin() y nada más.
create or replace function public.sca_puede_traer()
returns boolean
language sql stable security definer set search_path = public as $fn$
  select (select public.es_admin())
      or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'));
$fn$;
revoke all on function public.sca_puede_traer() from public, anon;
grant execute on function public.sca_puede_traer() to authenticated;

-- ---------- Traer un rango del SCA ----------
-- Ojo con las fechas: en esta API el endDate es EXCLUSIVO. Para traer el día 15 hay que
-- pedir startDate=15 y endDate=16. Aquí ya va sumado, para que quien llame no se equivoque.
create or replace function public.sca_traer(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_pos int;
  v_d date; v_h date; v_resp extensions.http_response; v_arr jsonb;
  v_vistos int := 0; v_nuestros int := 0; v_nuevos int := 0; v_ajenos int := 0; v_sinplaca int := 0;
begin
  if not public.sca_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede traer los tanqueos.';
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SCA_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SCA_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SCA_PASSWORD';
  if v_url is null or v_usr is null or v_pwd is null then
    return jsonb_build_object('ok', false, 'error',
      'Faltan las credenciales del SCA en Vault (SCA_URL, SCA_USER, SCA_PASSWORD).');
  end if;

  select id_punto_venta into v_pos from public.combustible_config where id = 1;
  if v_pos is null then
    return jsonb_build_object('ok', false, 'error',
      'Falta el punto de venta. Ponlo en combustible_config; el número lo da GetStationList de la estación.');
  end if;

  -- Por defecto, los últimos 3 días: alcanza para recoger lo que entró tarde sin pedir de más.
  v_d := coalesce(p_desde, (now() at time zone 'America/Bogota')::date - 3);
  v_h := coalesce(p_hasta, (now() at time zone 'America/Bogota')::date);
  if v_h < v_d then return jsonb_build_object('ok', false, 'error', 'El rango está al revés.'); end if;
  if v_h - v_d > 92 then return jsonb_build_object('ok', false, 'error', 'Máximo 92 días por llamada.'); end if;

  perform set_config('http.timeout_msec', '120000', true);  -- el servidor del SCA se demora
  select * into v_resp from extensions.http((
    'GET',
    rtrim(v_url, '/') || '/api/Transactions/GetTransactionsByDateTimeRangeAsync'
      || '?startDate=' || to_char(v_d, 'YYYY-MM-DD')
      || '&endDate='   || to_char(v_h + 1, 'YYYY-MM-DD')      -- +1: el endDate es exclusivo
      || '&idPointOfSale=' || v_pos,
    array[ extensions.http_header('Authorization',
             'Basic ' || encode(convert_to(v_usr || ':' || v_pwd, 'UTF8'), 'base64')) ],
    null, null
  )::extensions.http_request);

  if v_resp.status = 401 then
    return jsonb_build_object('ok', false, 'error',
      'El SCA rechazó la credencial (401). Revisa SCA_USER y SCA_PASSWORD en Vault.');
  elsif v_resp.status = 404 then
    return jsonb_build_object('ok', false, 'error',
      'El SCA respondió 404. Casi siempre es el idPointOfSale: sin él, o con uno que no existe, '
      || 'contesta como si el endpoint no existiera.');
  elsif v_resp.status <> 200 then
    return jsonb_build_object('ok', false, 'error', 'SCA HTTP ' || v_resp.status,
      'detalle', left(coalesce(v_resp.content, ''), 300));
  end if;

  begin
    v_arr := v_resp.content::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'El SCA no devolvió JSON.',
      'detalle', left(coalesce(v_resp.content, ''), 300));
  end;
  if jsonb_typeof(v_arr) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'Se esperaba una lista de transacciones.');
  end if;
  select count(*) into v_vistos from jsonb_array_elements(v_arr);
  select count(*) into v_sinplaca from jsonb_array_elements(v_arr) t
   where nullif(trim(coalesce(t->>'EquipmentPlate', '')), '') is null;

  -- Solo lo de NUESTRAS placas. Lo de los demás clientes de la estación ni se guarda.
  create temp table _tq on commit drop as
  select (t->>'Id')::bigint id_sca,
         upper(regexp_replace(coalesce(t->>'EquipmentPlate', ''), '[^A-Za-z0-9]', '', 'g')) placa_norm,
         t
  from jsonb_array_elements(v_arr) t
  where nullif(trim(coalesce(t->>'EquipmentPlate', '')), '') is not null
    and (t->>'Id') ~ '^[0-9]+$'
    and (t->>'Quantity') ~ '^-?[0-9]+(\.[0-9]+)?$';

  with nuestros as (
    select distinct on (q.id_sca) q.id_sca, q.t, p.numero_interno
    from _tq q
    join public.parque_automotor p
      on upper(regexp_replace(coalesce(p.placa, ''), '[^A-Za-z0-9]', '', 'g')) = q.placa_norm
    order by q.id_sca, p.numero_interno
  ), ins as (
    insert into public.combustible_tanqueos as c (
      id_sca, id_punto_venta, estacion, placa, movil, inicio, fin, cantidad, unidad,
      producto, precio, total, surtidor, manguera, odometro, odometro_previo,
      rendimiento_sca, flota, cliente, identificador, numero_trans, documento, crudo)
    select n.id_sca,
           nullif(n.t->>'IdPointOfSale', '')::int,
           n.t->>'PointOfSale',
           upper(trim(n.t->>'EquipmentPlate')),
           n.numero_interno,
           (n.t->>'StartDate')::timestamp at time zone 'America/Bogota',
           nullif(n.t->>'EndDate', '')::timestamp at time zone 'America/Bogota',
           (n.t->>'Quantity')::numeric,
           nullif(n.t->>'MeasurementUnit', ''),
           n.t->>'ProductName',
           nullif(n.t->>'Price', '')::numeric,
           nullif(n.t->>'Total', '')::numeric,
           n.t->>'DispenserName',
           n.t->>'NozzleName',
           nullif(n.t->>'Odometer', '')::numeric,
           nullif(n.t->>'PreviousOdometer', '')::numeric,
           nullif(n.t->>'Performance', '')::numeric,
           n.t->>'Fleet',
           n.t->>'CustomerName',
           n.t->>'EquipmentIdentifier',
           nullif(n.t->>'TransactionNumber', '')::bigint,
           n.t->>'DocumentNumber',
           n.t
    from nuestros n
    on conflict (id_sca) do update set
      -- se repite la traída: pudo cambiar el documento, el odómetro o el valor
      documento       = excluded.documento,
      odometro        = excluded.odometro,
      odometro_previo = excluded.odometro_previo,
      rendimiento_sca = excluded.rendimiento_sca,
      total           = excluded.total,
      precio          = excluded.precio,
      crudo           = excluded.crudo
    returning (xmax = 0) as era_nuevo
  )
  select count(*), count(*) filter (where era_nuevo) into v_nuestros, v_nuevos from ins;

  v_ajenos := v_vistos - v_nuestros - v_sinplaca;

  return jsonb_build_object('ok', true,
    'desde', v_d, 'hasta', v_h,
    'trajo',     v_vistos,     -- lo que mandó la estación
    'nuestros',  v_nuestros,   -- lo que era de placas de APL
    'nuevos',    v_nuevos,     -- lo que no teníamos
    'de_otros',  v_ajenos,     -- de otros clientes de la estación: NO se guardó
    'sin_placa', v_sinplaca);
end $fn$;

revoke all on function public.sca_traer(date, date) from public, anon;
grant execute on function public.sca_traer(date, date) to authenticated;

comment on function public.sca_traer(date, date) is
  'Trae los tanqueos del SCA por rango y guarda SOLO los de placas del parque de APL. Nunca marca nada en el SCA.';

-- ---------- Probar sin escribir nada ----------
-- Hace TODO lo que hace sca_traer —conectarse, autenticarse, leer el JSON, convertir cada
-- campo— pero contra una tabla temporal que es copia exacta de la de verdad. Si las
-- conversiones fallan, fallan aquí y no ensucian nada.
--
-- En el ambiente de pruebas de Speed ninguna placa es de APL, así que sin ayuda diría
-- "0 nuestros" y no se probaría la parte que más importa. Para eso está p_placas: le dices
-- qué placas tratar como propias SOLO durante la prueba. sca_traer no tiene ese parámetro
-- a propósito: en producción la única fuente de verdad es el parque automotor.
create or replace function public.sca_probar(p_desde date, p_hasta date, p_placas text[] default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $fn$
declare
  v_url text; v_usr text; v_pwd text; v_pos int;
  v_t0 timestamptz; v_ms int; v_resp extensions.http_response; v_arr jsonb;
  v_vistos int; v_interp int; v_coinc int; v_placas jsonb; v_uni jsonb;
  v_ini text; v_fin text; v_gal numeric; v_muestra jsonb;
begin
  if not public.sca_puede_traer() then
    raise exception 'Solo administración puede probar la conexión con el SCA.';
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SCA_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SCA_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SCA_PASSWORD';
  if v_url is null or v_usr is null or v_pwd is null then
    return jsonb_build_object('ok', false, 'paso', 'credenciales',
      'error', 'Faltan SCA_URL, SCA_USER o SCA_PASSWORD en Vault.');
  end if;
  select id_punto_venta into v_pos from public.combustible_config where id = 1;
  if v_pos is null then
    return jsonb_build_object('ok', false, 'paso', 'configuracion',
      'error', 'Falta id_punto_venta en combustible_config.');
  end if;

  v_t0 := clock_timestamp();
  perform set_config('http.timeout_msec', '120000', true);
  begin
    select * into v_resp from extensions.http((
      'GET',
      rtrim(v_url, '/') || '/api/Transactions/GetTransactionsByDateTimeRangeAsync'
        || '?startDate=' || to_char(p_desde, 'YYYY-MM-DD')
        || '&endDate='   || to_char(p_hasta + 1, 'YYYY-MM-DD')
        || '&idPointOfSale=' || v_pos,
      array[ extensions.http_header('Authorization',
               'Basic ' || encode(convert_to(v_usr || ':' || v_pwd, 'UTF8'), 'base64')) ],
      null, null
    )::extensions.http_request);
  exception when others then
    return jsonb_build_object('ok', false, 'paso', 'conexion', 'error', sqlerrm,
      'pista', 'Si dice timeout: ese servidor se demora, y a veces no responde. Reintenta.');
  end;
  v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;

  if v_resp.status <> 200 then
    return jsonb_build_object('ok', false, 'paso', 'respuesta', 'http', v_resp.status, 'ms', v_ms,
      'detalle', left(coalesce(v_resp.content, ''), 300),
      'pista', case v_resp.status
                 when 401 then 'Credencial rechazada: revisa SCA_USER y SCA_PASSWORD.'
                 when 404 then 'Casi siempre falta o está mal el idPointOfSale.'
                 when 500 then 'El SCA reventó: suele ser un parámetro que él espera y no le llegó.'
                 else 'Revisa el detalle.' end);
  end if;

  begin
    v_arr := v_resp.content::jsonb;
  exception when others then
    return jsonb_build_object('ok', false, 'paso', 'json', 'ms', v_ms,
      'detalle', left(coalesce(v_resp.content, ''), 300));
  end;

  select count(*) into v_vistos from jsonb_array_elements(v_arr);
  select min(t->>'StartDate'), max(t->>'StartDate') into v_ini, v_fin
    from jsonb_array_elements(v_arr) t;
  -- Las placas, como máximo 20: si la estación atiende a muchos clientes, la lista no sirve de nada.
  select jsonb_agg(pl) into v_placas from (
    select distinct t->>'EquipmentPlate' pl from jsonb_array_elements(v_arr) t
    where nullif(trim(coalesce(t->>'EquipmentPlate', '')), '') is not null
    order by 1 limit 20) z;
  select jsonb_object_agg(u, c) into v_uni from (
    select coalesce(nullif(t->>'MeasurementUnit', ''), '(vacío)') u, count(*) c
    from jsonb_array_elements(v_arr) t group by 1) z;

  -- La copia exacta de la tabla real: mismos tipos, mismas columnas calculadas.
  create temp table _pr (like public.combustible_tanqueos including all) on commit drop;

  insert into _pr (
    id_sca, id_punto_venta, estacion, placa, movil, inicio, fin, cantidad, unidad,
    producto, precio, total, surtidor, manguera, odometro, odometro_previo,
    rendimiento_sca, flota, cliente, identificador, numero_trans, documento, crudo)
  select distinct on (nn.id_sca)
         nn.id_sca,
         nullif(nn.t->>'IdPointOfSale', '')::int,
         nn.t->>'PointOfSale',
         upper(trim(nn.t->>'EquipmentPlate')),
         nn.movil,
         (nn.t->>'StartDate')::timestamp at time zone 'America/Bogota',
         nullif(nn.t->>'EndDate', '')::timestamp at time zone 'America/Bogota',
         (nn.t->>'Quantity')::numeric,
         nullif(nn.t->>'MeasurementUnit', ''),
         nn.t->>'ProductName',
         nullif(nn.t->>'Price', '')::numeric,
         nullif(nn.t->>'Total', '')::numeric,
         nn.t->>'DispenserName',
         nn.t->>'NozzleName',
         nullif(nn.t->>'Odometer', '')::numeric,
         nullif(nn.t->>'PreviousOdometer', '')::numeric,
         nullif(nn.t->>'Performance', '')::numeric,
         nn.t->>'Fleet',
         nn.t->>'CustomerName',
         nn.t->>'EquipmentIdentifier',
         nullif(nn.t->>'TransactionNumber', '')::bigint,
         nn.t->>'DocumentNumber',
         nn.t
  from (
    select (t->>'Id')::bigint id_sca, t,
           coalesce(p.numero_interno, '(no está en el parque)') movil
    from jsonb_array_elements(v_arr) t
    left join public.parque_automotor p
      on upper(regexp_replace(coalesce(p.placa, ''), '[^A-Za-z0-9]', '', 'g'))
       = upper(regexp_replace(coalesce(t->>'EquipmentPlate', ''), '[^A-Za-z0-9]', '', 'g'))
    where (t->>'Id') ~ '^[0-9]+$'
      and (t->>'Quantity') ~ '^-?[0-9]+(\.[0-9]+)?$'
      and nullif(trim(coalesce(t->>'EquipmentPlate', '')), '') is not null
      and ( p.numero_interno is not null
         or upper(trim(t->>'EquipmentPlate')) = any (coalesce(p_placas, array[]::text[])) )
  ) nn
  order by nn.id_sca, (nn.movil = '(no está en el parque)');  -- gana el móvil real

  select count(*), round(sum(galones), 2) into v_interp, v_gal from _pr;
  select count(*) into v_coinc from _pr where movil <> '(no está en el parque)';
  select jsonb_agg(to_jsonb(m) - 'crudo') into v_muestra
    from (select * from _pr order by inicio limit 2) m;

  return jsonb_build_object(
    'ok', true,
    'http', v_resp.status,
    'ms', v_ms,
    'trajo', v_vistos,                    -- lo que mandó la estación en ese rango
    'placas', v_placas,
    'unidades', v_uni,
    'primera', v_ini, 'ultima', v_fin,    -- sirve para ver si el rango de fechas quedó bien
    'interpretadas', v_interp,            -- se transformaron sin error
    'en_el_parque', v_coinc,              -- de esas, cuántas son carros de APL de verdad
    'galones_total', v_gal,               -- ya convertidos desde litros
    'muestra', v_muestra,
    'nota', 'Prueba: no se guardó nada en combustible_tanqueos.');
end $fn$;

revoke all on function public.sca_probar(date, date, text[]) from public, anon;
grant execute on function public.sca_probar(date, date, text[]) to authenticated;

comment on function public.sca_probar(date, date, text[]) is
  'Prueba la conexión con el SCA y la conversión de cada campo contra una tabla temporal. No escribe nada.';
