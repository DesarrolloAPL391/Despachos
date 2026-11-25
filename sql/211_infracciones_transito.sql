-- 211 · 🚓 Infracciones de tránsito (módulo 🛡️ Seguridad vial)
--
-- Pedido (25/11/2026): "tengo unos archivos que quiero montar en el módulo de seguridad vial: uno es un
-- archivo de infracciones de tránsito que llega cada mes, hay que hacer una función de importación; el
-- otro es una base de datos de histórico... es super importante que al importar la información quede en
-- el MISMO FORMATO del histórico".
--
-- Los dos formatos que llegan:
--   MENSUAL   hoja "INFRACCIONES" del archivo de tránsito: Fecha_Comparendo, Comparendo_Nro, Placa,
--             Código_Infracción, Infracción, Tipo_Comparendo, Cédula, Nombre_Infractor, ID_EMPRESA.
--   HISTORICO hoja "DATA GENERAL INFRACCIONES" (19 columnas): AÑO/MES/DIA DEL REPORTE, FECHA DE LA
--             INFRACCION, datos del conductor y su licencia, POSIBLE HORA, CODIGO DE LA INFRACCION,
--             PLACA, NRO. INT., RUTA, AFILIADO, TIPO DE COMPARENDO, NRO. COMPARENDO.
--
-- Cómo se pasa el MENSUAL al formato del histórico (comprobado con los 31 comparendos de octubre, que
-- ya estaban a mano en el histórico: coinciden fecha, hora, código, placa, año/mes/día):
--   AÑO / MES ("10_OCTUBRE") / DÍA ("VIERNES")  ← la fecha de la infracción (así está en las 1.804 filas)
--   FECHA DE LA INFRACCION y POSIBLE HORA       ← la fecha y la hora del comparendo
--   CONDUCTOR (código, cédula, nombre, ingreso, categoría, expedición y vencimiento de la licencia)
--                                               ← perfil sociodemográfico por la cédula del comparendo.
--     En «NN o Sticker» y «Electrónico» el comparendo no trae al conductor (la fotomulta le llega al
--     dueño): se busca en SONAR quién manejaba ese bus a esa hora (eventos_bus_conductor, sql/83).
--   NRO. INT., RUTA, AFILIADO                   ← parque automotor por la placa.
--   La descripción de la infracción (que el histórico no tenía) queda en el catálogo de códigos.
--
-- Lo que el histórico trae desordenado y aquí queda en un solo formato: "INFRACCION"/"INFRACCIÓN"/
-- "Infracción" → INFRACCIÓN; "C2" → C02; "09_septiembre" → 09_SEPTIEMBRE; "Laureles" → LAURELES;
-- fechas escritas como texto (d/mm/aaaa) → fecha.
--
-- OJO, números de comparendo de 20 dígitos: 135 filas del histórico los tienen guardados como NÚMERO
-- y Excel les borró los últimos dígitos (quedan varios comparendos distintos con el mismo número).
-- Se guardan tal cual con comparendo_impreciso = true y no entran en el control de repetidos por número.
-- Igual se marca el único número exacto que el histórico trae en DOS comparendos distintos (digitación).
--
-- Quién ve: seguridad vial y administración (es_seguridad_vial). Nadie escribe directo en las tablas:
-- solo por las funciones. Simular es lo de siempre (p_aplicar = false): no escribe nada.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------
-- Normalizadores (puros)
-- ---------------------------------------------------------------------------------------------
create or replace function public._inf_fecha(p text) returns date
language plpgsql immutable set search_path = public as $fn$
declare s text := btrim(coalesce(p, '')); m text[]; a int; b int; y int;
begin
  if s = '' then return null; end if;
  m := regexp_match(s, '^(\d{4})-(\d{1,2})-(\d{1,2})');
  if m is not null then return make_date(m[1]::int, m[2]::int, m[3]::int); end if;
  m := regexp_match(s, '^(\d{1,2})/+(\d{1,2})/+(\d{4})$');   -- "9//2025" también (error de digitación)
  if m is not null then
    a := m[1]::int; b := m[2]::int; y := m[3]::int;
    if b > 12 and a <= 12 then return make_date(y, a, b); end if;   -- venía mes/día
    return make_date(y, b, a);                                       -- día/mes (Colombia)
  end if;
  return null;
exception when others then return null;
end $fn$;

-- "08:15:29", " 08:15:29", "9:05:10 a. m.", "2024-02-05 10:56:37" → hora
create or replace function public._inf_hora(p text) returns time
language plpgsql immutable set search_path = public as $fn$
declare m text[]; h int;
begin
  m := regexp_match(lower(coalesce(p, '')), '(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap])?');
  if m is null then return null; end if;
  h := m[1]::int;
  if m[4] = 'p' and h < 12 then h := h + 12; elsif m[4] = 'a' and h = 12 then h := 0; end if;
  return make_time(h, m[2]::int, coalesce(m[3], '0')::int);
exception when others then return null;
end $fn$;

-- Cédula: solo dígitos, sin ceros a la izquierda. "NN…" (sin infractor) → null
create or replace function public._inf_ced(p text) returns text
language sql immutable set search_path = public as $fn$
  select case when coalesce(p, '') ~* '^\s*nn' then null
              else nullif(ltrim(regexp_replace(coalesce(p, ''), '\D', '', 'g'), '0'), '') end
$fn$;

create or replace function public._inf_placa(p text) returns text
language sql immutable set search_path = public as $fn$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '')
$fn$;

-- "C2" → "C02"
create or replace function public._inf_codigo(p text) returns text
language sql immutable set search_path = public as $fn$
  select case when s ~ '^[A-Z][0-9]$' then substr(s, 1, 1) || '0' || substr(s, 2) else nullif(s, '') end
  from (select upper(regexp_replace(coalesce(p, ''), '\s', '', 'g')) s) x
$fn$;

create or replace function public._inf_tipo(p text) returns text
language sql immutable set search_path = public as $fn$
  select case
    when k in ('INFRACCION', 'INFACCION') then 'INFRACCIÓN'
    when k = 'ELECTRONICO' then 'ELECTRÓNICO'
    when k = 'EDUCATIVO' then 'EDUCATIVO'
    when k in ('NN O STICKER', 'NN', 'STICKER') then 'NN O STICKER'
    when k = 'ACCIDENTE' then 'ACCIDENTE'
    else nullif(k, '') end
  from (select regexp_replace(upper(translate(btrim(coalesce(p, '')), 'áéíóúÁÉÍÓÚ', 'aeiouAEIOU')), '\s+', ' ', 'g') k) x
$fn$;

create or replace function public._inf_mes(d date) returns text
language sql immutable set search_path = public as $fn$
  select to_char(d, 'MM') || '_' || (array['ENERO','FEBRERO','MARZO','ABRIL','MAYO','JUNIO','JULIO','AGOSTO',
                                            'SEPTIEMBRE','OCTUBRE','NOVIEMBRE','DICIEMBRE'])[extract(month from d)::int]
$fn$;

create or replace function public._inf_dia(d date) returns text
language sql immutable set search_path = public as $fn$
  select (array['DOMINGO','LUNES','MARTES','MIÉRCOLES','JUEVES','VIERNES','SÁBADO'])[extract(dow from d)::int + 1]
$fn$;

-- Texto en mayúscula con un solo espacio ("08_ AGOSTO" → "08_AGOSTO" lo hace el llamador). Primero se
-- juntan los espacios y después se recorta: el histórico trae saltos de línea y espacios duros delante
-- del número interno ("⏎8184").
create or replace function public._inf_txt(p text) returns text
language sql immutable set search_path = public as $fn$
  select nullif(upper(btrim(regexp_replace(coalesce(p, ''), '[[:space:] ]+', ' ', 'g'))), '')
$fn$;

-- Número de comparendo: sin espacios, en mayúscula ("NO REGISTRA" se deja así)
create or replace function public._inf_comparendo(p text) returns text
language sql immutable set search_path = public as $fn$
  select case when s ~ '\d' then regexp_replace(s, '\s', '', 'g') else nullif(s, '') end
  from (select upper(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')) s) x
$fn$;

-- ---------------------------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------------------------
create table if not exists public.infracciones_codigos (
  codigo         text primary key,
  descripcion    text,
  actualizado_en timestamptz not null default now()
);

create table if not exists public.infracciones_lotes (
  id          bigint generated always as identity primary key,
  formato     text not null check (formato in ('HISTORICO', 'MENSUAL')),
  archivo     text,
  filas       int not null default 0,
  nuevas      int not null default 0,
  ya_estaban  int not null default 0,
  resumen     jsonb,
  cargado_por text,
  cargado_en  timestamptz not null default now()
);

create table if not exists public.infracciones_transito (
  id                      bigint generated always as identity primary key,
  -- las 19 columnas del histórico, en su orden
  anio_reporte            int  not null,
  mes_reporte             text not null,      -- "10_OCTUBRE"
  dia_reporte             text not null,      -- "VIERNES"
  fecha_infraccion        date not null,
  codigo_conductor        text,
  cedula_conductor        text,
  nombre_conductor        text,
  fecha_ingreso_conductor date,
  cat_licencia            text,
  licencia_expedicion     date,
  licencia_vencimiento    date,
  posible_hora            time,
  codigo_infraccion       text not null,
  placa                   text,
  numero_interno          text,
  ruta                    text,
  afiliado                text,
  tipo_comparendo         text not null,
  nro_comparendo          text not null,
  -- lo que el histórico de Excel no tenía
  infraccion              text,               -- descripción (del catálogo)
  comparendo_impreciso    boolean not null default false,
  cedula_infractor        text,               -- la del comparendo (en NN o Electrónico no es el conductor)
  nombre_infractor        text,
  conductor_segun         text not null default 'HISTORICO'
                          check (conductor_segun in ('HISTORICO', 'COMPARENDO', 'SONAR', 'MANUAL', 'SIN DATO')),
  origen                  text not null check (origen in ('HISTORICO', 'MENSUAL')),
  lote_id                 bigint references public.infracciones_lotes (id),
  creado_en               timestamptz not null default now(),
  actualizado_por         text,
  actualizado_en          timestamptz
);
-- Un comparendo (número exacto) entra una sola vez
create unique index if not exists infracciones_transito_comparendo_uq
  on public.infracciones_transito (nro_comparendo) where not comparendo_impreciso and nro_comparendo ~ '\d';
create index if not exists infracciones_transito_fecha_idx  on public.infracciones_transito (fecha_infraccion);
create index if not exists infracciones_transito_ced_idx    on public.infracciones_transito (cedula_conductor);
create index if not exists infracciones_transito_placa_idx  on public.infracciones_transito (placa);
create index if not exists infracciones_transito_codigo_idx on public.infracciones_transito (codigo_infraccion);
create index if not exists infracciones_transito_lote_idx   on public.infracciones_transito (lote_id);

alter table public.infracciones_codigos  enable row level security;
alter table public.infracciones_lotes    enable row level security;
alter table public.infracciones_transito enable row level security;

drop policy if exists inf_codigos_sel on public.infracciones_codigos;
create policy inf_codigos_sel on public.infracciones_codigos for select to authenticated
  using ((select public.es_seguridad_vial()));
drop policy if exists inf_lotes_sel on public.infracciones_lotes;
create policy inf_lotes_sel on public.infracciones_lotes for select to authenticated
  using ((select public.es_seguridad_vial()));
drop policy if exists inf_transito_sel on public.infracciones_transito;
create policy inf_transito_sel on public.infracciones_transito for select to authenticated
  using ((select public.es_seguridad_vial()));

revoke all on public.infracciones_codigos, public.infracciones_lotes, public.infracciones_transito from anon, public;
revoke insert, update, delete, truncate on public.infracciones_codigos, public.infracciones_lotes,
  public.infracciones_transito from authenticated;
grant select on public.infracciones_codigos, public.infracciones_lotes, public.infracciones_transito to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Importar (los dos formatos). La app lee el Excel y manda las filas tal cual vienen; AQUÍ se pasan
-- al formato del histórico, así el formato no depende de la app.
--   p_formato 'MENSUAL':   [{fecha, comparendo, comparendo_num, placa, codigo, infraccion, tipo, cedula, nombre}]
--   p_formato 'HISTORICO': [{anio, mes, dia, fecha, cod_conductor, ced_conductor, nom_conductor, fecha_ingreso,
--                            cat_licencia, lic_expedicion, lic_vencimiento, hora, codigo, placa, numero_interno,
--                            ruta, afiliado, tipo, comparendo, comparendo_num}]
--   comparendo_num = true cuando la celda de Excel era un NÚMERO (perdió dígitos).
-- Ya cargado = mismo número exacto; o, si el número es impreciso, misma fecha + código + placa + primeros
-- 15 dígitos (lo que Excel sí conserva).
-- ---------------------------------------------------------------------------------------------
create or replace function public.infracciones_importar(p_formato text, p_filas jsonb,
                                                        p_archivo text default null, p_aplicar boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_fmt  text := upper(btrim(coalesce(p_formato, '')));
  v_lote bigint;
  v_res  jsonb;
  v_ins  int := 0;
begin
  -- es_consola(): el SQL Editor / la API de administración (sin sesión de la app), para cargas a mano
  if not (public.es_seguridad_vial() or public.es_consola()) then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial y administración.');
  end if;
  if v_fmt not in ('MENSUAL', 'HISTORICO') then
    return jsonb_build_object('ok', false, 'error', 'Formato desconocido: ' || coalesce(p_formato, '(vacío)'));
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' or jsonb_array_length(p_filas) = 0 then
    return jsonb_build_object('ok', false, 'error', 'El archivo no trae filas.');
  end if;
  if jsonb_array_length(p_filas) > 5000 then
    return jsonb_build_object('ok', false, 'error', 'Máximo 5.000 filas por importación.');
  end if;
  -- una importación a la vez (dos al tiempo podrían meter el mismo comparendo)
  perform pg_advisory_xact_lock(hashtext('infracciones_importar'));

  drop table if exists _inf_tmp;
  create temp table _inf_tmp (
    fila int, estado text, anio_reporte int, mes_reporte text, dia_reporte text, fecha_infraccion date,
    codigo_conductor text, cedula_conductor text, nombre_conductor text, fecha_ingreso_conductor date,
    cat_licencia text, licencia_expedicion date, licencia_vencimiento date, posible_hora time,
    codigo_infraccion text, placa text, numero_interno text, ruta text, afiliado text, tipo_comparendo text,
    nro_comparendo text, infraccion text, comparendo_impreciso boolean, cedula_infractor text,
    nombre_infractor text, conductor_segun text, sonar_origen text, con_vehiculo boolean
  ) on commit drop;

  if v_fmt = 'MENSUAL' then
    insert into _inf_tmp
    with src as (
      select o.ord::int fila, o.v from jsonb_array_elements(p_filas) with ordinality o(v, ord)
    ),
    b as (
      select fila,
             public._inf_fecha(v->>'fecha') f,
             public._inf_hora(substring(coalesce(v->>'fecha', '') from 11)) h,
             public._inf_comparendo(v->>'comparendo') nro,
             coalesce((v->>'comparendo_num')::boolean, false) impreciso,
             public._inf_placa(v->>'placa') placa,
             public._inf_codigo(v->>'codigo') codigo,
             nullif(btrim(v->>'infraccion'), '') descripcion,
             public._inf_tipo(v->>'tipo') tipo,
             public._inf_ced(v->>'cedula') ced_inf,
             public._inf_txt(v->>'nombre') nom_inf
        from src
    ),
    veh as (
      select distinct on (public._inf_placa(placa)) public._inf_placa(placa) placa, numero_interno, ruta, propietario
        from public.parque_automotor where public._inf_placa(placa) is not null
       order by public._inf_placa(placa), (estado = 'Activo') desc, id desc
    ),
    per as (
      select distinct on (public._inf_ced(cedula)) public._inf_ced(cedula) ced, codigo, nombre, cargo, fecha_ingreso,
             categoria_licencia, licencia_expedicion, licencia_vencimiento
        from public.perfilsociodemografico where public._inf_ced(cedula) is not null
       order by public._inf_ced(cedula), (estado = 'ACTIVO') desc, fecha_ingreso desc nulls last
    ),
    -- NN o Sticker / Electrónico (o sin cédula): quién manejaba ese bus a esa hora según SONAR
    son as (
      select b.fila, c.conductor, c.origen, public._inf_ced(cs.cedula) ced
        from b
        cross join lateral (
          select d.mid from public.despachos_sonar d
           where d.fecha between b.f - 1 and b.f + 1 and d.mid is not null
             and public._inf_placa(d.placa) = b.placa
           order by abs(d.fecha - b.f) limit 1) m
        cross join lateral public.eventos_bus_conductor(m.mid, (b.f + b.h) at time zone 'America/Bogota') c
        left join lateral (
          select x.cedula from public.conductores_sonar x
           where upper(btrim(x.nombre)) = upper(btrim(c.conductor)) and public._inf_ced(x.cedula) is not null
           limit 1) cs on true
       where (b.tipo in ('NN O STICKER', 'ELECTRÓNICO') or b.ced_inf is null)
         and b.f is not null and b.h is not null and b.h <> time '00:00'
    ),
    r as (
      select b.*, v.numero_interno, v.ruta veh_ruta, v.propietario, (v.placa is not null) con_vehiculo,
             s.conductor son_nombre, s.origen son_origen, s.ced son_ced,
             case
               when b.tipo in ('NN O STICKER', 'ELECTRÓNICO') or b.ced_inf is null then
                 case when s.conductor is not null then 'SONAR'
                      when pc.ced is not null and pc.cargo ilike '%conductor%' then 'COMPARENDO'
                      else 'SIN DATO' end
               else 'COMPARENDO' end segun
        from b
        left join veh v on v.placa = b.placa
        left join son s on s.fila = b.fila
        left join per pc on pc.ced = b.ced_inf
    ),
    r2 as (
      select r.*, case r.segun when 'SONAR' then r.son_ced when 'COMPARENDO' then r.ced_inf end ced_cond
        from r
    )
    select r2.fila, null,
           extract(year from r2.f)::int, public._inf_mes(r2.f), public._inf_dia(r2.f), r2.f,
           p.codigo, r2.ced_cond,
           coalesce(public._inf_txt(p.nombre),
                    case r2.segun when 'SONAR' then public._inf_txt(r2.son_nombre)
                                  when 'COMPARENDO' then r2.nom_inf end),
           p.fecha_ingreso, public._inf_txt(p.categoria_licencia), p.licencia_expedicion, p.licencia_vencimiento,
           r2.h, r2.codigo, r2.placa, public._inf_txt(r2.numero_interno), public._inf_txt(r2.veh_ruta),
           public._inf_txt(r2.propietario), r2.tipo, r2.nro, r2.descripcion, r2.impreciso, r2.ced_inf, r2.nom_inf,
           r2.segun, r2.son_origen, r2.con_vehiculo
      from r2 left join per p on p.ced = r2.ced_cond;

  else  -- HISTORICO: se respeta lo que trae, solo se ordena el formato
    insert into _inf_tmp
    with src as (
      select o.ord::int fila, o.v from jsonb_array_elements(p_filas) with ordinality o(v, ord)
    ),
    b as (
      select fila, v, public._inf_fecha(v->>'fecha') f from src
    )
    select fila, null,
           coalesce(nullif(regexp_replace(coalesce(v->>'anio', ''), '\D', '', 'g'), '')::int, extract(year from f)::int),
           coalesce(nullif(replace(public._inf_txt(v->>'mes'), ' ', ''), ''), public._inf_mes(f)),
           coalesce(public._inf_txt(v->>'dia'), public._inf_dia(f)),
           f,
           public._inf_txt(v->>'cod_conductor'), public._inf_ced(v->>'ced_conductor'), public._inf_txt(v->>'nom_conductor'),
           public._inf_fecha(v->>'fecha_ingreso'), public._inf_txt(v->>'cat_licencia'),
           public._inf_fecha(v->>'lic_expedicion'), public._inf_fecha(v->>'lic_vencimiento'),
           public._inf_hora(v->>'hora'), public._inf_codigo(v->>'codigo'), public._inf_placa(v->>'placa'),
           public._inf_txt(v->>'numero_interno'), public._inf_txt(v->>'ruta'), public._inf_txt(v->>'afiliado'),
           public._inf_tipo(v->>'tipo'), public._inf_comparendo(v->>'comparendo'), null,
           coalesce((v->>'comparendo_num')::boolean, false), null, null,
           'HISTORICO', null, true
      from b;
  end if;

  create index on _inf_tmp (nro_comparendo);
  -- El histórico trae un número exacto en dos comparendos distintos (otra fecha, código y placa): error de
  -- digitación. Los dos entran, con el número marcado como no confiable, en vez de perder uno.
  if v_fmt = 'HISTORICO' then
    update _inf_tmp t set comparendo_impreciso = true
     where not t.comparendo_impreciso and t.nro_comparendo ~ '\d' and exists (
       select 1 from _inf_tmp o
        where o.nro_comparendo = t.nro_comparendo and o.fila <> t.fila
          and (o.fecha_infraccion is distinct from t.fecha_infraccion
               or o.codigo_infraccion is distinct from t.codigo_infraccion or o.placa is distinct from t.placa));
  end if;

  -- Estado de cada fila: error, repetida en el archivo, ya cargada o nueva
  update _inf_tmp set estado = case
      when fecha_infraccion is null then 'ERROR: fecha inválida'
      when nro_comparendo is null then 'ERROR: sin número de comparendo'
      when codigo_infraccion is null then 'ERROR: sin código de infracción'
      when tipo_comparendo is null then 'ERROR: sin tipo de comparendo'
    end;
  -- (1) mismo número exacto: va por el índice único
  update _inf_tmp t set estado = 'YA ESTABA'
   where t.estado is null and not t.comparendo_impreciso and t.nro_comparendo ~ '\d'
     and exists (select 1 from public.infracciones_transito i
                  where i.nro_comparendo = t.nro_comparendo and not i.comparendo_impreciso and i.nro_comparendo ~ '\d');
  -- (2) número impreciso o "NO REGISTRA" (de un lado o del otro): misma fecha + código + placa y los
  --     primeros 15 dígitos; sin número, además el mismo conductor. Va por el índice de fecha.
  update _inf_tmp t set estado = 'YA ESTABA'
   where t.estado is null and exists (
     select 1 from public.infracciones_transito i
      where i.fecha_infraccion = t.fecha_infraccion and i.codigo_infraccion = t.codigo_infraccion
        and i.placa is not distinct from t.placa
        and (t.comparendo_impreciso or i.comparendo_impreciso or t.nro_comparendo !~ '\d')
        and left(regexp_replace(i.nro_comparendo, '\D', '', 'g'), 15) = left(regexp_replace(t.nro_comparendo, '\D', '', 'g'), 15)
        and (t.nro_comparendo ~ '\d' or i.cedula_conductor is not distinct from t.cedula_conductor));
  -- (3) dentro del mismo archivo: la primera aparición entra, las demás no
  update _inf_tmp t set estado = 'REPETIDA EN EL ARCHIVO'
   where t.estado is null and exists (
     select 1 from _inf_tmp o
      where o.nro_comparendo = t.nro_comparendo and o.fila < t.fila and coalesce(o.estado, '') not like 'ERROR%'
        and ((not t.comparendo_impreciso and t.nro_comparendo ~ '\d' and not o.comparendo_impreciso)
          or (o.fecha_infraccion = t.fecha_infraccion and o.codigo_infraccion = t.codigo_infraccion
              and o.placa is not distinct from t.placa and o.cedula_conductor is not distinct from t.cedula_conductor)));
  update _inf_tmp set estado = 'NUEVA' where estado is null;

  v_res := jsonb_build_object(
    'ok', true, 'formato', v_fmt, 'aplicado', p_aplicar,
    'filas', (select count(*) from _inf_tmp),
    'nuevas', (select count(*) from _inf_tmp where estado = 'NUEVA'),
    'ya_estaban', (select count(*) from _inf_tmp where estado = 'YA ESTABA'),
    'repetidas', (select count(*) from _inf_tmp where estado = 'REPETIDA EN EL ARCHIVO'),
    'errores', (select count(*) from _inf_tmp where estado like 'ERROR%'),
    'imprecisos', (select count(*) from _inf_tmp where estado = 'NUEVA' and comparendo_impreciso),
    'sin_vehiculo', (select count(*) from _inf_tmp where estado = 'NUEVA' and numero_interno is null),
    'conductor', (select coalesce(jsonb_object_agg(conductor_segun, n), '{}') from (
                    select conductor_segun, count(*) n from _inf_tmp where estado = 'NUEVA' group by 1) x),
    'sin_perfil', (select count(*) from _inf_tmp where estado = 'NUEVA' and cedula_conductor is not null
                     and codigo_conductor is null and conductor_segun <> 'HISTORICO'),
    'desde', (select min(fecha_infraccion) from _inf_tmp where estado = 'NUEVA'),
    'hasta', (select max(fecha_infraccion) from _inf_tmp where estado = 'NUEVA'),
    'codigos_nuevos', (select coalesce(jsonb_agg(distinct t.codigo_infraccion), '[]') from _inf_tmp t
                        where t.estado = 'NUEVA'
                          and not exists (select 1 from public.infracciones_codigos c where c.codigo = t.codigo_infraccion)),
    'detalle', (select coalesce(jsonb_agg(jsonb_build_object(
                    'fila', fila, 'estado', estado, 'fecha', fecha_infraccion, 'hora', posible_hora,
                    'comparendo', nro_comparendo, 'placa', placa, 'movil', numero_interno, 'ruta', ruta,
                    'codigo', codigo_infraccion, 'tipo', tipo_comparendo, 'conductor', nombre_conductor,
                    'codigo_conductor', codigo_conductor, 'segun', conductor_segun, 'sonar', sonar_origen)
                    order by k, fila), '[]')
                  from (select *, case when estado like 'ERROR%' then 0 when estado = 'NUEVA' then 1 else 2 end k
                          from _inf_tmp order by k, fila limit 600) d)
  );

  if not p_aplicar then return v_res; end if;

  -- Catálogo: todos los códigos; la descripción la trae el mensual (la más reciente manda)
  insert into public.infracciones_codigos (codigo, descripcion)
  select codigo_infraccion, max(infraccion) from _inf_tmp
   where estado not like 'ERROR%' group by codigo_infraccion
  on conflict (codigo) do update
     set descripcion = coalesce(excluded.descripcion, public.infracciones_codigos.descripcion),
         actualizado_en = case when excluded.descripcion is distinct from public.infracciones_codigos.descripcion
                                    and excluded.descripcion is not null then now()
                               else public.infracciones_codigos.actualizado_en end;

  insert into public.infracciones_lotes (formato, archivo, filas, nuevas, ya_estaban, resumen, cargado_por)
  values (v_fmt, left(p_archivo, 200), (v_res->>'filas')::int, (v_res->>'nuevas')::int, (v_res->>'ya_estaban')::int,
          v_res - 'detalle', coalesce(auth.email(), current_user))
  returning id into v_lote;

  insert into public.infracciones_transito (
    anio_reporte, mes_reporte, dia_reporte, fecha_infraccion, codigo_conductor, cedula_conductor, nombre_conductor,
    fecha_ingreso_conductor, cat_licencia, licencia_expedicion, licencia_vencimiento, posible_hora, codigo_infraccion,
    placa, numero_interno, ruta, afiliado, tipo_comparendo, nro_comparendo, infraccion, comparendo_impreciso,
    cedula_infractor, nombre_infractor, conductor_segun, origen, lote_id)
  select t.anio_reporte, t.mes_reporte, t.dia_reporte, t.fecha_infraccion, t.codigo_conductor, t.cedula_conductor,
         t.nombre_conductor, t.fecha_ingreso_conductor, t.cat_licencia, t.licencia_expedicion, t.licencia_vencimiento,
         t.posible_hora, t.codigo_infraccion, t.placa, t.numero_interno, t.ruta, t.afiliado, t.tipo_comparendo,
         t.nro_comparendo, coalesce(t.infraccion, c.descripcion), t.comparendo_impreciso, t.cedula_infractor,
         t.nombre_infractor, t.conductor_segun, v_fmt, v_lote
    from _inf_tmp t left join public.infracciones_codigos c on c.codigo = t.codigo_infraccion
   where t.estado = 'NUEVA'
   order by t.fecha_infraccion, t.posible_hora nulls first, t.fila;
  get diagnostics v_ins = row_count;

  -- Las filas viejas sin descripción la toman del catálogo apenas un mensual la trae
  update public.infracciones_transito i set infraccion = c.descripcion
    from public.infracciones_codigos c
   where i.infraccion is null and c.codigo = i.codigo_infraccion and c.descripcion is not null;

  return v_res || jsonb_build_object('lote', v_lote, 'insertadas', v_ins);
end $fn$;

-- ---------------------------------------------------------------------------------------------
-- Corregir el conductor de una infracción (sobre todo NN o Sticker / Electrónico): por cédula del perfil
-- ---------------------------------------------------------------------------------------------
create or replace function public.infracciones_conductor_asignar(p_id bigint, p_cedula text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_ced text := public._inf_ced(p_cedula); v_n int;
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial y administración.');
  end if;
  if v_ced is null then return jsonb_build_object('ok', false, 'error', 'Escriba la cédula del conductor.'); end if;
  update public.infracciones_transito i
     set cedula_conductor = v_ced, codigo_conductor = p.codigo, nombre_conductor = public._inf_txt(p.nombre),
         fecha_ingreso_conductor = p.fecha_ingreso, cat_licencia = public._inf_txt(p.categoria_licencia),
         licencia_expedicion = p.licencia_expedicion, licencia_vencimiento = p.licencia_vencimiento,
         conductor_segun = 'MANUAL', actualizado_por = coalesce(auth.email(), current_user), actualizado_en = now()
    from (select * from public.perfilsociodemografico where public._inf_ced(cedula) = v_ced
           order by (estado = 'ACTIVO') desc, fecha_ingreso desc nulls last limit 1) p
   where i.id = p_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'Esa cédula no está en el perfil sociodemográfico, o la infracción no existe.');
  end if;
  return jsonb_build_object('ok', true);
end $fn$;

-- ---------------------------------------------------------------------------------------------
-- Deshacer una importación completa (archivo equivocado): solo administración
-- ---------------------------------------------------------------------------------------------
create or replace function public.infracciones_lote_borrar(p_lote bigint)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_n int;
begin
  if not (public.es_admin() or public.es_consola()) then return jsonb_build_object('ok', false, 'error', 'Solo administración.'); end if;
  delete from public.infracciones_transito where lote_id = p_lote;
  get diagnostics v_n = row_count;
  delete from public.infracciones_lotes where id = p_lote;
  return jsonb_build_object('ok', true, 'borradas', v_n);
end $fn$;

-- ---------------------------------------------------------------------------------------------
-- La vista: TODO en el formato del histórico (mismos encabezados y en el mismo orden), con lo nuevo al final
-- ---------------------------------------------------------------------------------------------
create or replace view public.infracciones_historico with (security_invoker = true) as
select i.anio_reporte            as "AÑO DEL REPORTE",
       i.mes_reporte             as "MES DEL REPORTE",
       i.dia_reporte             as "DIA DEL REPORTE",
       i.fecha_infraccion        as "FECHA DE LA INFRACCION",
       i.codigo_conductor        as "CODIGO DEL CONDUCTOR",
       i.cedula_conductor        as "ID. CONDUCTOR",
       i.nombre_conductor        as "NOMBRE CONDUCTOR",
       i.fecha_ingreso_conductor as "FECHA DE INGRESO DEL CONDUCTOR",
       i.cat_licencia            as "CAT. LICENCIA DE CONDUCCIÓN",
       i.licencia_expedicion     as "FCHA EXPEDICI",
       i.licencia_vencimiento    as "FECHA VENCIMIENTO",
       i.posible_hora            as "POSIBLE HORA",
       i.codigo_infraccion       as "CODIGO DE LA INFRACCION",
       i.placa                   as "PLACA",
       i.numero_interno          as "NRO. INT.",
       i.ruta                    as "RUTA",
       i.afiliado                as "AFILIADO",
       i.tipo_comparendo         as "TIPO DE COMPARENDO",
       i.nro_comparendo          as "NRO. COMPARENDO",
       coalesce(i.infraccion, c.descripcion) as "INFRACCIÓN",
       i.conductor_segun         as "CONDUCTOR SEGÚN",
       i.comparendo_impreciso    as "COMPARENDO IMPRECISO",
       i.origen                  as "ORIGEN",
       i.lote_id                 as "LOTE",
       i.id
  from public.infracciones_transito i
  left join public.infracciones_codigos c on c.codigo = i.codigo_infraccion
 order by i.fecha_infraccion, i.posible_hora nulls first, i.id;

revoke all on public.infracciones_historico from anon, public;
grant select on public.infracciones_historico to authenticated;

-- Permisos de las funciones: nunca anon (sql/123)
revoke all on function public.infracciones_importar(text, jsonb, text, boolean) from public, anon;
revoke all on function public.infracciones_conductor_asignar(bigint, text) from public, anon;
revoke all on function public.infracciones_lote_borrar(bigint) from public, anon;
grant execute on function public.infracciones_importar(text, jsonb, text, boolean) to authenticated;
grant execute on function public.infracciones_conductor_asignar(bigint, text) to authenticated;
grant execute on function public.infracciones_lote_borrar(bigint) to authenticated;
revoke all on function public._inf_fecha(text), public._inf_hora(text), public._inf_ced(text), public._inf_placa(text),
  public._inf_codigo(text), public._inf_tipo(text), public._inf_mes(date), public._inf_dia(date), public._inf_txt(text),
  public._inf_comparendo(text) from public, anon;
grant execute on function public._inf_fecha(text), public._inf_hora(text), public._inf_ced(text), public._inf_placa(text),
  public._inf_codigo(text), public._inf_tipo(text), public._inf_mes(date), public._inf_dia(date), public._inf_txt(text),
  public._inf_comparendo(text) to authenticated;
