-- 212 · 💥 Accidentes de tránsito (módulo 🛡️ Seguridad vial) — la otra hoja del archivo mensual de tránsito
--
-- Pedido (25/11/2026): "sí, impórtalo" — la hoja ACCIDENTES que llega en el mismo archivo mensual que las
-- infracciones (sql/211): Comparendo_Nro, Nro. Croquis, Dirección, Placa, Clase_Accidente, Gravedad_Accidente,
-- Cédula, Nombre_Infractor, Fecha_Accidente, ID_EMPRESA.
--
-- No hay histórico de accidentes en Excel: se guardan en el MISMO formato de las infracciones (AÑO / MES
-- "10_OCTUBRE" / DÍA "VIERNES" del reporte, conductor por cédula en el perfil, móvil/ruta/afiliado por placa en
-- el parque; sin cédula —"NN"— el conductor sale de SONAR). Se suma el cruce con los SINIESTROS que se reportan
-- en la app (sql/79): misma placa ±1 día. Un accidente de tránsito sin siniestro = no se reportó adentro.
--
-- La app sube las dos hojas del archivo en la misma importación. Ya cargado = mismo croquis y placa (sin croquis:
-- misma fecha, hora y placa). Quién ve: seguridad vial y administración. Solo se escribe por las funciones.

set lock_timeout = '5s';

-- Las importaciones de accidentes van al mismo registro de lotes (para «Deshacer»)
alter table public.infracciones_lotes drop constraint if exists infracciones_lotes_formato_check;
alter table public.infracciones_lotes add constraint infracciones_lotes_formato_check
  check (formato in ('HISTORICO', 'MENSUAL', 'ACCIDENTES'));

create table if not exists public.accidentes_transito (
  id                      bigint generated always as identity primary key,
  anio_reporte            int  not null,
  mes_reporte             text not null,
  dia_reporte             text not null,
  fecha_accidente         date not null,
  hora                    time,
  codigo_conductor        text,
  cedula_conductor        text,
  nombre_conductor        text,
  fecha_ingreso_conductor date,
  cat_licencia            text,
  licencia_expedicion     date,
  licencia_vencimiento    date,
  placa                   text not null,
  numero_interno          text,
  ruta                    text,
  afiliado                text,
  clase_accidente         text,               -- CHOQUE, ATROPELLO, OTRO…
  gravedad                text,               -- HERIDO, MUERTO, SOLO DAÑOS…
  nro_croquis             text,
  direccion               text,
  nro_comparendo          text,
  cedula_infractor        text,               -- lo que dice el reporte
  nombre_infractor        text,
  conductor_segun         text not null check (conductor_segun in ('REPORTE', 'SONAR', 'MANUAL', 'SIN DATO')),
  siniestro_key           text,               -- el siniestro reportado en la app (misma placa ±1 día), si lo hay
  lote_id                 bigint references public.infracciones_lotes (id),
  creado_en               timestamptz not null default now(),
  actualizado_por         text,
  actualizado_en          timestamptz
);
create unique index if not exists accidentes_transito_croquis_uq
  on public.accidentes_transito (nro_croquis, placa) where nro_croquis is not null;
create index if not exists accidentes_transito_fecha_idx on public.accidentes_transito (fecha_accidente);
create index if not exists accidentes_transito_ced_idx   on public.accidentes_transito (cedula_conductor);
create index if not exists accidentes_transito_lote_idx  on public.accidentes_transito (lote_id);

alter table public.accidentes_transito enable row level security;
drop policy if exists acc_transito_sel on public.accidentes_transito;
create policy acc_transito_sel on public.accidentes_transito for select to authenticated
  using ((select public.es_seguridad_vial()));
revoke all on public.accidentes_transito from anon, public;
revoke insert, update, delete, truncate on public.accidentes_transito from authenticated;
grant select on public.accidentes_transito to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Importar la hoja ACCIDENTES: [{fecha, croquis, comparendo, direccion, placa, clase, gravedad, cedula, nombre}]
-- ---------------------------------------------------------------------------------------------
create or replace function public.accidentes_importar(p_filas jsonb, p_archivo text default null, p_aplicar boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_lote bigint;
  v_res  jsonb;
  v_ins  int := 0;
begin
  if not (public.es_seguridad_vial() or public.es_consola()) then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial y administración.');
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' or jsonb_array_length(p_filas) = 0 then
    return jsonb_build_object('ok', false, 'error', 'La hoja de accidentes no trae filas.');
  end if;
  if jsonb_array_length(p_filas) > 5000 then
    return jsonb_build_object('ok', false, 'error', 'Máximo 5.000 filas por importación.');
  end if;
  perform pg_advisory_xact_lock(hashtext('infracciones_importar'));

  drop table if exists _acc_tmp;
  create temp table _acc_tmp (
    fila int, estado text, anio_reporte int, mes_reporte text, dia_reporte text, fecha_accidente date, hora time,
    codigo_conductor text, cedula_conductor text, nombre_conductor text, fecha_ingreso_conductor date, cat_licencia text,
    licencia_expedicion date, licencia_vencimiento date, placa text, numero_interno text, ruta text, afiliado text,
    clase_accidente text, gravedad text, nro_croquis text, direccion text, nro_comparendo text, cedula_infractor text,
    nombre_infractor text, conductor_segun text, sonar_origen text, siniestro_key text
  ) on commit drop;

  insert into _acc_tmp
  with src as (
    select o.ord::int fila, o.v from jsonb_array_elements(p_filas) with ordinality o(v, ord)
  ),
  b as (
    select fila,
           public._inf_fecha(v->>'fecha') f,
           public._inf_hora(substring(coalesce(v->>'fecha', '') from 11)) h,
           replace(public._inf_txt(v->>'croquis'), ' ', '') croquis,
           public._inf_comparendo(v->>'comparendo') nro,
           public._inf_placa(v->>'placa') placa,
           public._inf_txt(v->>'clase') clase,
           public._inf_txt(v->>'gravedad') gravedad,
           public._inf_txt(v->>'direccion') direccion,
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
    select distinct on (public._inf_ced(cedula)) public._inf_ced(cedula) ced, codigo, nombre, fecha_ingreso,
           categoria_licencia, licencia_expedicion, licencia_vencimiento
      from public.perfilsociodemografico where public._inf_ced(cedula) is not null
     order by public._inf_ced(cedula), (estado = 'ACTIVO') desc, fecha_ingreso desc nulls last
  ),
  son as (   -- sin cédula en el reporte: quién manejaba ese bus a esa hora según SONAR
    select b.fila, c.conductor, c.origen, public._inf_ced(cs.cedula) ced
      from b
      cross join lateral (
        select d.mid from public.despachos_sonar d
         where d.fecha between b.f - 1 and b.f + 1 and d.mid is not null and public._inf_placa(d.placa) = b.placa
         order by abs(d.fecha - b.f) limit 1) m
      cross join lateral public.eventos_bus_conductor(m.mid, (b.f + b.h) at time zone 'America/Bogota') c
      left join lateral (
        select x.cedula from public.conductores_sonar x
         where upper(btrim(x.nombre)) = upper(btrim(c.conductor)) and public._inf_ced(x.cedula) is not null limit 1) cs on true
     where b.ced_inf is null and b.f is not null and b.h is not null and b.h <> time '00:00'
  ),
  sin as (   -- el siniestro reportado en la app: misma placa, ±1 día, el más cercano
    select b.fila, s.key
      from b cross join lateral (
        select x.key from public.siniestros x
         where x.fecha between b.f - 1 and b.f + 1 and public._inf_placa(x.placa) = b.placa
         order by abs(x.fecha - b.f), x.key limit 1) s
     where b.f is not null and b.placa is not null
  ),
  r as (
    select b.*, v.numero_interno, v.ruta veh_ruta, v.propietario, s.conductor son_nombre, s.origen son_origen, s.ced son_ced,
           si.key sin_key,
           case when b.ced_inf is not null then 'REPORTE' when s.conductor is not null then 'SONAR' else 'SIN DATO' end segun
      from b
      left join veh v on v.placa = b.placa
      left join son s on s.fila = b.fila
      left join sin si on si.fila = b.fila
  ),
  r2 as (select r.*, case r.segun when 'SONAR' then r.son_ced when 'REPORTE' then r.ced_inf end ced_cond from r)
  select r2.fila, null,
         extract(year from r2.f)::int, public._inf_mes(r2.f), public._inf_dia(r2.f), r2.f, r2.h,
         p.codigo, r2.ced_cond,
         coalesce(public._inf_txt(p.nombre),
                  case r2.segun when 'SONAR' then public._inf_txt(r2.son_nombre) when 'REPORTE' then r2.nom_inf end),
         p.fecha_ingreso, public._inf_txt(p.categoria_licencia), p.licencia_expedicion, p.licencia_vencimiento,
         r2.placa, public._inf_txt(r2.numero_interno), public._inf_txt(r2.veh_ruta), public._inf_txt(r2.propietario),
         r2.clase, r2.gravedad, r2.croquis, r2.direccion, r2.nro, r2.ced_inf, r2.nom_inf, r2.segun, r2.son_origen, r2.sin_key
    from r2 left join per p on p.ced = r2.ced_cond;

  update _acc_tmp set estado = case
      when fecha_accidente is null then 'ERROR: fecha inválida'
      when placa is null then 'ERROR: sin placa'
    end;
  update _acc_tmp t set estado = 'YA ESTABA'
   where t.estado is null and exists (
     select 1 from public.accidentes_transito a
      where a.placa = t.placa
        and ((t.nro_croquis is not null and a.nro_croquis = t.nro_croquis)
          or (t.nro_croquis is null and a.nro_croquis is null and a.fecha_accidente = t.fecha_accidente
              and a.hora is not distinct from t.hora)));
  update _acc_tmp t set estado = 'REPETIDA EN EL ARCHIVO'
   where t.estado is null and exists (
     select 1 from _acc_tmp o
      where o.fila < t.fila and coalesce(o.estado, '') not like 'ERROR%' and o.placa = t.placa
        and ((t.nro_croquis is not null and o.nro_croquis = t.nro_croquis)
          or (t.nro_croquis is null and o.nro_croquis is null and o.fecha_accidente = t.fecha_accidente
              and o.hora is not distinct from t.hora)));
  update _acc_tmp set estado = 'NUEVA' where estado is null;

  v_res := jsonb_build_object(
    'ok', true, 'formato', 'ACCIDENTES', 'aplicado', p_aplicar,
    'filas', (select count(*) from _acc_tmp),
    'nuevas', (select count(*) from _acc_tmp where estado = 'NUEVA'),
    'ya_estaban', (select count(*) from _acc_tmp where estado = 'YA ESTABA'),
    'repetidas', (select count(*) from _acc_tmp where estado = 'REPETIDA EN EL ARCHIVO'),
    'errores', (select count(*) from _acc_tmp where estado like 'ERROR%'),
    'imprecisos', 0,
    'sin_vehiculo', (select count(*) from _acc_tmp where estado = 'NUEVA' and numero_interno is null),
    'conductor', (select coalesce(jsonb_object_agg(conductor_segun, n), '{}') from (
                    select conductor_segun, count(*) n from _acc_tmp where estado = 'NUEVA' group by 1) x),
    'sin_perfil', (select count(*) from _acc_tmp where estado = 'NUEVA' and cedula_conductor is not null and codigo_conductor is null),
    'sin_siniestro', (select count(*) from _acc_tmp where estado = 'NUEVA' and siniestro_key is null),
    'desde', (select min(fecha_accidente) from _acc_tmp where estado = 'NUEVA'),
    'hasta', (select max(fecha_accidente) from _acc_tmp where estado = 'NUEVA'),
    'codigos_nuevos', '[]'::jsonb,
    'detalle', (select coalesce(jsonb_agg(jsonb_build_object(
                    'fila', fila, 'estado', estado, 'fecha', fecha_accidente, 'hora', hora, 'croquis', nro_croquis,
                    'placa', placa, 'movil', numero_interno, 'ruta', ruta, 'clase', clase_accidente, 'gravedad', gravedad,
                    'conductor', nombre_conductor, 'codigo_conductor', codigo_conductor, 'segun', conductor_segun,
                    'sonar', sonar_origen, 'siniestro', siniestro_key is not null)
                    order by k, fila), '[]')
                  from (select *, case when estado like 'ERROR%' then 0 when estado = 'NUEVA' then 1 else 2 end k
                          from _acc_tmp order by k, fila limit 600) d)
  );

  if not p_aplicar then return v_res; end if;

  insert into public.infracciones_lotes (formato, archivo, filas, nuevas, ya_estaban, resumen, cargado_por)
  values ('ACCIDENTES', left(p_archivo, 200), (v_res->>'filas')::int, (v_res->>'nuevas')::int, (v_res->>'ya_estaban')::int,
          v_res - 'detalle', coalesce(auth.email(), current_user))
  returning id into v_lote;

  insert into public.accidentes_transito (
    anio_reporte, mes_reporte, dia_reporte, fecha_accidente, hora, codigo_conductor, cedula_conductor, nombre_conductor,
    fecha_ingreso_conductor, cat_licencia, licencia_expedicion, licencia_vencimiento, placa, numero_interno, ruta, afiliado,
    clase_accidente, gravedad, nro_croquis, direccion, nro_comparendo, cedula_infractor, nombre_infractor, conductor_segun,
    siniestro_key, lote_id)
  select anio_reporte, mes_reporte, dia_reporte, fecha_accidente, hora, codigo_conductor, cedula_conductor, nombre_conductor,
         fecha_ingreso_conductor, cat_licencia, licencia_expedicion, licencia_vencimiento, placa, numero_interno, ruta, afiliado,
         clase_accidente, gravedad, nro_croquis, direccion, nro_comparendo, cedula_infractor, nombre_infractor, conductor_segun,
         siniestro_key, v_lote
    from _acc_tmp where estado = 'NUEVA'
   order by fecha_accidente, hora nulls first, fila;
  get diagnostics v_ins = row_count;

  -- Los accidentes que aún no tenían siniestro: quizá ya se reportó después
  update public.accidentes_transito a
     set siniestro_key = (select x.key from public.siniestros x
                           where x.fecha between a.fecha_accidente - 1 and a.fecha_accidente + 1 and x.placa = a.placa
                           order by abs(x.fecha - a.fecha_accidente), x.key limit 1)
   where a.siniestro_key is null
     and exists (select 1 from public.siniestros x
                  where x.fecha between a.fecha_accidente - 1 and a.fecha_accidente + 1 and x.placa = a.placa);

  return v_res || jsonb_build_object('lote', v_lote, 'insertadas', v_ins);
end $fn$;

-- Corregir el conductor de un accidente (por cédula del perfil)
create or replace function public.accidentes_conductor_asignar(p_id bigint, p_cedula text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_ced text := public._inf_ced(p_cedula); v_n int;
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial y administración.');
  end if;
  if v_ced is null then return jsonb_build_object('ok', false, 'error', 'Escriba la cédula del conductor.'); end if;
  update public.accidentes_transito a
     set cedula_conductor = v_ced, codigo_conductor = p.codigo, nombre_conductor = public._inf_txt(p.nombre),
         fecha_ingreso_conductor = p.fecha_ingreso, cat_licencia = public._inf_txt(p.categoria_licencia),
         licencia_expedicion = p.licencia_expedicion, licencia_vencimiento = p.licencia_vencimiento,
         conductor_segun = 'MANUAL', actualizado_por = coalesce(auth.email(), current_user), actualizado_en = now()
    from (select * from public.perfilsociodemografico where public._inf_ced(cedula) = v_ced
           order by (estado = 'ACTIVO') desc, fecha_ingreso desc nulls last limit 1) p
   where a.id = p_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'Esa cédula no está en el perfil sociodemográfico, o el accidente no existe.');
  end if;
  return jsonb_build_object('ok', true);
end $fn$;

-- «Deshacer» una importación: ahora también borra los accidentes de ese lote
create or replace function public.infracciones_lote_borrar(p_lote bigint)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_n int; v_a int;
begin
  if not (public.es_admin() or public.es_consola()) then return jsonb_build_object('ok', false, 'error', 'Solo administración.'); end if;
  delete from public.infracciones_transito where lote_id = p_lote;
  get diagnostics v_n = row_count;
  delete from public.accidentes_transito where lote_id = p_lote;
  get diagnostics v_a = row_count;
  delete from public.infracciones_lotes where id = p_lote;
  return jsonb_build_object('ok', true, 'borradas', v_n + v_a);
end $fn$;

-- La vista, con los encabezados al estilo del histórico de infracciones
create or replace view public.accidentes_historico with (security_invoker = true) as
select a.anio_reporte            as "AÑO DEL REPORTE",
       a.mes_reporte             as "MES DEL REPORTE",
       a.dia_reporte             as "DIA DEL REPORTE",
       a.fecha_accidente         as "FECHA DEL ACCIDENTE",
       a.hora                    as "HORA",
       a.codigo_conductor        as "CODIGO DEL CONDUCTOR",
       a.cedula_conductor        as "ID. CONDUCTOR",
       a.nombre_conductor        as "NOMBRE CONDUCTOR",
       a.fecha_ingreso_conductor as "FECHA DE INGRESO DEL CONDUCTOR",
       a.cat_licencia            as "CAT. LICENCIA DE CONDUCCIÓN",
       a.licencia_expedicion     as "FCHA EXPEDICI",
       a.licencia_vencimiento    as "FECHA VENCIMIENTO",
       a.placa                   as "PLACA",
       a.numero_interno          as "NRO. INT.",
       a.ruta                    as "RUTA",
       a.afiliado                as "AFILIADO",
       a.clase_accidente         as "CLASE DE ACCIDENTE",
       a.gravedad                as "GRAVEDAD",
       a.nro_croquis             as "NRO. CROQUIS",
       a.direccion               as "DIRECCIÓN",
       a.nro_comparendo          as "NRO. COMPARENDO",
       a.conductor_segun         as "CONDUCTOR SEGÚN",
       (a.siniestro_key is not null) as "REPORTADO COMO SINIESTRO",
       a.lote_id                 as "LOTE",
       a.id
  from public.accidentes_transito a
 order by a.fecha_accidente, a.hora nulls first, a.id;

revoke all on public.accidentes_historico from anon, public;
grant select on public.accidentes_historico to authenticated;

revoke all on function public.accidentes_importar(jsonb, text, boolean) from public, anon;
revoke all on function public.accidentes_conductor_asignar(bigint, text) from public, anon;
revoke all on function public.infracciones_lote_borrar(bigint) from public, anon;
grant execute on function public.accidentes_importar(jsonb, text, boolean) to authenticated;
grant execute on function public.accidentes_conductor_asignar(bigint, text) to authenticated;
grant execute on function public.infracciones_lote_borrar(bigint) to authenticated;
