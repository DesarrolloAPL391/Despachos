-- 140_liquidaciones_pantalla.sql
-- "lo quiero paginar" + "entrar y montar una foto de la liquidacion" (24/10/2026).
--
-- LA FOTO VA POR VEHICULO Y DIA, no por fila: un bus hace varias rutas el mismo dia (son
-- 28.919 filas pero solo ~16.000 dias-vehiculo), y el papel que se firma es el del dia. Por eso
-- la pantalla lista DIAS-VEHICULO y, al abrir uno, muestra sus rutas y deja montar la foto.
--
-- PAGINADO EN EL SERVIDOR, no en el navegador: son 29.000 filas y $2.454 millones de historial;
-- traerlas al celular para cortarlas alla seria absurdo. Los totales que se muestran arriba son
-- de TODO el filtro, no de la pagina que se esta viendo -- si no, el numero enganaria.
--
-- SOLO ADMINISTRACION, decidido con el usuario. La tabla ya tiene RLS de admin (sql/138); estas
-- funciones vuelven a validar por dentro porque son security definer.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

-- ---------------------------------------------------------------------------
-- 1) Donde viven las fotos
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('liquidaciones', 'liquidaciones', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists liq_fotos_admin on storage.objects;
create policy liq_fotos_admin on storage.objects
  for all to authenticated
  using (bucket_id = 'liquidaciones' and (select public.es_admin()))
  with check (bucket_id = 'liquidaciones' and (select public.es_admin()));

-- ---------------------------------------------------------------------------
-- 2) El soporte de cada dia-vehiculo
-- ---------------------------------------------------------------------------
create table if not exists public.liquidacion_fotos (
  id          bigserial primary key,
  movil       text not null,
  fecha       date not null,
  path        text not null,
  nota        text,
  subida_por  text,
  subida_en   timestamptz not null default now(),
  unique (movil, fecha)
);

comment on table public.liquidacion_fotos is 'Foto del papel de la liquidacion, una por vehiculo y dia (sql/140).';

create index if not exists liqfoto_fecha_idx on public.liquidacion_fotos (fecha desc);

alter table public.liquidacion_fotos enable row level security;
drop policy if exists liqfoto_admin on public.liquidacion_fotos;
create policy liqfoto_admin on public.liquidacion_fotos
  for all to authenticated
  using ((select public.es_admin())) with check ((select public.es_admin()));

-- ---------------------------------------------------------------------------
-- 3) El listado paginado (dias-vehiculo)
-- ---------------------------------------------------------------------------
create or replace function public.liquidaciones_listar(
  p_desde    date    default null,
  p_hasta    date    default null,
  p_movil    text    default null,
  p_cedula   text    default null,
  p_ruta     text    default null,
  p_punto    text    default null,
  p_sin_foto boolean default false,
  p_pagina   int     default 1,
  p_tam      int     default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_tam  int := least(greatest(coalesce(p_tam, 50), 10), 200);
  v_pag  int := greatest(coalesce(p_pagina, 1), 1);
  v_out  jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  with base as (
    select l.*
      from public.liquidaciones l
     where (p_desde  is null or l.fecha >= p_desde)
       and (p_hasta  is null or l.fecha <= p_hasta)
       and (p_movil  is null or btrim(p_movil) = '' or l.movil = btrim(p_movil))
       and (p_cedula is null or btrim(p_cedula) = '' or l.conductor_cedula = btrim(p_cedula))
       and (p_ruta   is null or btrim(p_ruta) = ''   or l.ruta = upper(btrim(p_ruta)))
       and (p_punto  is null or btrim(p_punto) = ''  or l.punto = p_punto)
  ),
  dias as (
    select b.movil, b.fecha,
           count(*)::int                    as filas,
           sum(b.viajes)::int               as viajes,
           sum(b.unidades)::int             as unidades,
           sum(b.total_liquidar)::int       as total_liquidar,
           sum(b.liquidar)::int             as liquidar,
           sum(b.dinero)::bigint            as dinero,
           string_agg(distinct b.ruta, ' · ' order by b.ruta)  as rutas,
           (array_agg(b.conductor order by b.conductor))[1]    as conductor,
           (array_agg(b.conductor_cedula order by b.conductor_cedula))[1] as cedula,
           count(*) filter (where b.conductor_cedula is null) as sin_cedula,
           count(*) filter (where b.cuadra is false)          as no_cuadran
      from base b
     group by b.movil, b.fecha
  ),
  conf as (
    select d.*, f.id as foto_id, f.path as foto_path, f.subida_por, f.nota
      from dias d
      left join public.liquidacion_fotos f on f.movil = d.movil and f.fecha = d.fecha
     where (not coalesce(p_sin_foto, false)) or f.id is null
  )
  select jsonb_build_object(
    'ok', true,
    'pagina', v_pag, 'tam', v_tam,
    'total_dias', (select count(*) from conf),
    'paginas', greatest(1, ceil((select count(*) from conf)::numeric / v_tam)::int),
    -- Los totales son del filtro completo, no de la pagina.
    'totales', (select jsonb_build_object(
                  'dias',     count(*),
                  'filas',    coalesce(sum(filas), 0),
                  'viajes',   coalesce(sum(viajes), 0),
                  'unidades', coalesce(sum(unidades), 0),
                  'liquidar', coalesce(sum(liquidar), 0),
                  'dinero',   coalesce(sum(dinero), 0),
                  'con_foto', count(*) filter (where foto_id is not null),
                  'sin_cedula', coalesce(sum(sin_cedula), 0),
                  'no_cuadran', coalesce(sum(no_cuadran), 0)) from conf),
    'filas', (select coalesce(jsonb_agg(jsonb_build_object(
                'movil', c.movil,
                'fecha', to_char(c.fecha, 'DD/MM/YYYY'),
                'fecha_iso', c.fecha,
                'rutas', c.rutas, 'viajes', c.viajes, 'unidades', c.unidades,
                'total_liquidar', c.total_liquidar, 'liquidar', c.liquidar, 'dinero', c.dinero,
                'conductor', c.conductor, 'cedula', c.cedula,
                'sin_cedula', c.sin_cedula > 0, 'no_cuadran', c.no_cuadran > 0,
                'foto', c.foto_path, 'foto_por', c.subida_por, 'foto_nota', c.nota
              ) order by c.fecha desc, c.movil), '[]'::jsonb)
              from (select * from conf order by fecha desc, movil
                     limit v_tam offset (v_pag - 1) * v_tam) c)
  ) into v_out;

  return v_out;
end $function$;

revoke all on function public.liquidaciones_listar(date, date, text, text, text, text, boolean, int, int) from public, anon;
grant execute on function public.liquidaciones_listar(date, date, text, text, text, text, boolean, int, int) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) El detalle de un dia-vehiculo (las rutas que hizo ese dia)
-- ---------------------------------------------------------------------------
create or replace function public.liquidaciones_dia(p_movil text, p_fecha date)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case when not (select public.es_admin())
              then jsonb_build_object('ok', false, 'error', 'Solo el administrador.')
  else jsonb_build_object(
    'ok', true,
    'movil', p_movil,
    'fecha', to_char(p_fecha, 'DD/MM/YYYY'),
    'foto', (select jsonb_build_object('path', f.path, 'por', f.subida_por, 'nota', f.nota,
                                       'cuando', to_char(f.subida_en at time zone 'America/Bogota',
                                                         'DD/MM/YYYY HH24:MI'))
               from public.liquidacion_fotos f
              where f.movil = p_movil and f.fecha = p_fecha),
    'filas', (select coalesce(jsonb_agg(jsonb_build_object(
                'key', l.key, 'ruta', l.ruta, 'punto', l.punto, 'viajes', l.viajes,
                'conductor', l.conductor, 'cedula', l.conductor_cedula,
                'unidades', l.unidades, 'descontar', l.descontar,
                'total_liquidar', l.total_liquidar, 'liquidar', l.liquidar,
                'dinero', l.dinero, 'cuadra', l.cuadra
              ) order by l.ruta), '[]'::jsonb)
              from public.liquidaciones l
             where l.movil = p_movil and l.fecha = p_fecha))
  end;
$function$;

revoke all on function public.liquidaciones_dia(text, date) from public, anon;
grant execute on function public.liquidaciones_dia(text, date) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) Registrar / quitar la foto
--    El archivo lo sube la app al bucket; aqui solo queda apuntado quien y cuando.
-- ---------------------------------------------------------------------------
create or replace function public.liquidacion_foto_guardar(
  p_movil text, p_fecha date, p_path text, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  if coalesce(btrim(p_path), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el archivo.');
  end if;
  -- Que no se registre una foto de un dia que no existe en la liquidacion: seria un soporte
  -- huerfano que nadie volveria a encontrar.
  if not exists (select 1 from public.liquidaciones
                  where movil = p_movil and fecha = p_fecha) then
    return jsonb_build_object('ok', false, 'error',
      'Ese vehiculo no tiene liquidacion en esa fecha.');
  end if;

  insert into public.liquidacion_fotos (movil, fecha, path, nota, subida_por)
  values (p_movil, p_fecha, btrim(p_path), nullif(btrim(p_nota), ''),
          coalesce(auth.jwt() ->> 'email', 'admin'))
  on conflict (movil, fecha) do update
    set path = excluded.path, nota = coalesce(excluded.nota, public.liquidacion_fotos.nota),
        subida_por = excluded.subida_por, subida_en = now();

  return jsonb_build_object('ok', true);
end $function$;

revoke all on function public.liquidacion_foto_guardar(text, date, text, text) from public, anon;
grant execute on function public.liquidacion_foto_guardar(text, date, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) Resumen para las tarjetas de arriba y los filtros
-- ---------------------------------------------------------------------------
create or replace function public.liquidaciones_resumen()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case when not (select public.es_admin())
              then jsonb_build_object('ok', false, 'error', 'Solo el administrador.')
  else jsonb_build_object(
    'ok', true,
    'filas',      (select count(*) from public.liquidaciones),
    'dias',       (select count(*) from (select 1 from public.liquidaciones
                     group by movil, fecha) d),
    'desde',      (select to_char(min(fecha), 'DD/MM/YYYY') from public.liquidaciones),
    'hasta',      (select to_char(max(fecha), 'DD/MM/YYYY') from public.liquidaciones),
    'dinero',     (select coalesce(sum(dinero), 0) from public.liquidaciones),
    'vehiculos',  (select count(distinct movil) from public.liquidaciones),
    'con_foto',   (select count(*) from public.liquidacion_fotos),
    'sin_cedula', (select count(*) from public.liquidaciones where conductor_cedula is null),
    'no_cuadran', (select count(*) from public.liquidaciones where cuadra is false),
    -- Los conductores cuyo nombre no se pudo cruzar con el perfil: hay que corregirlos en la
    -- hoja, no aqui. Se muestran para que alguien los arregle en el origen.
    'nombres_sin_cedula', (select coalesce(jsonb_agg(distinct conductor), '[]'::jsonb)
                             from public.liquidaciones where conductor_cedula is null),
    'rutas',      (select coalesce(jsonb_agg(distinct ruta order by ruta), '[]'::jsonb)
                     from public.liquidaciones where coalesce(ruta, '') <> ''),
    'puntos',     (select coalesce(jsonb_agg(distinct punto order by punto), '[]'::jsonb)
                     from public.liquidaciones where coalesce(punto, '') <> ''),
    'moviles',    (select coalesce(jsonb_agg(distinct movil order by movil), '[]'::jsonb)
                     from public.liquidaciones where coalesce(movil, '') <> ''),
    'ultima_sync', (select jsonb_build_object(
                      'cuando', to_char(procesado_en at time zone 'America/Bogota',
                                        'DD/MM/YYYY HH24:MI'),
                      'resultado', resultado)
                      from public.liquidaciones_fuente where id = 1))
  end;
$function$;

revoke all on function public.liquidaciones_resumen() from public, anon;
grant execute on function public.liquidaciones_resumen() to authenticated;

-- Comprobacion (solo lectura)
select 'bucket liquidaciones (privado)' as dato,
       (select case when public then 'PUBLICO - revisar' else 'si, privado' end
          from storage.buckets where id = 'liquidaciones') as valor
union all
select 'tabla liquidacion_fotos',
       (select case when count(*) > 0 then 'si' else 'NO' end::text
          from information_schema.tables
         where table_schema = 'public' and table_name = 'liquidacion_fotos')
union all
select 'funciones de la pantalla',
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('liquidaciones_listar', 'liquidaciones_dia',
                             'liquidacion_foto_guardar', 'liquidaciones_resumen')) || ' de 4';
