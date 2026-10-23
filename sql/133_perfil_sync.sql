-- 133_perfil_sync.sql  (LOCAL, sin publicar)
-- "la base de datos todavia esta en Google Sheets; la idea es una funcion automatica que
--  incluya los conductores y administrativos" (22/10/2026).
--
-- Trae las dos hojas publicadas (admin = administrativos, "Hoja 3" = conductores) y las
-- sincroniza contra perfilsociodemografico. Corre DENTRO de Supabase (extension http + pg_cron):
-- los datos nunca pasan por un computador ni por GitHub.
--
-- LA URL NO VA EN ESTE ARCHIVO. El repo es publico y esa hoja tiene cedulas, salarios y datos
-- de salud. Vive en public.perfil_fuente, que tiene RLS de solo-admin, igual que
-- siniestros_fuente / pqrsf_fuente / disciplinarios_fuente.
--
-- POR DEFECTO SIMULA. perfil_sync() sin argumentos NO escribe: devuelve cuantas personas
-- entrarian, cuantas cambiarian y cuantas filas vienen malas. Para aplicar: perfil_sync(true).
--
-- QUE SE SINCRONIZA Y QUE NO (importante, hay DOS fuentes de verdad):
--   * Datos laborales (estado, cargo, area, contrato, fechas, salario, centro de costos, placa,
--     propietario, codigo, novedad de retiro y la licencia de los conductores): manda la HOJA,
--     que es la que lleva Gestion Humana. Se sobrescriben siempre.
--   * Contacto (correo, celular, telefono): solo se RELLENA si en la base esta vacio. El
--     empleado los actualiza desde la app (perfil_enviar_actualizacion) y seria absurdo que la
--     hoja le pisara el dato bueno con uno viejo.
--   * El resto de datos personales (direccion, familia, estudios, emergencia): NO se tocan.
-- El historial (perfil_vinculaciones) se llena solo: lo hace el trigger perfil_despues_guardar,
-- que ya distingue alta, reingreso y cambio laboral. Por eso aqui NO se activa su llave de
-- escape (app.perfil_carga): queremos que el historial quede.

-- ---------------------------------------------------------------------------
-- 1) De donde se trae (con RLS: solo el admin la ve)
-- ---------------------------------------------------------------------------
create table if not exists public.perfil_fuente (
  id            int primary key default 1 check (id = 1),
  url_admin     text,
  url_conductores text,
  nota          text,
  ultima_carga  timestamptz,
  ultimo_total  int,
  actualizado_en timestamptz not null default now()
);
alter table public.perfil_fuente enable row level security;
drop policy if exists perfil_fuente_all on public.perfil_fuente;
create policy perfil_fuente_all on public.perfil_fuente
  for all using ((select public.es_admin())) with check ((select public.es_admin()));
revoke all on public.perfil_fuente from anon;
grant select, insert, update on public.perfil_fuente to authenticated;

-- Registro de cada corrida: sin esto no hay forma de saber si el cron esta trabajando
create table if not exists public.perfil_sync_log (
  id        bigserial primary key,
  corrio_en timestamptz not null default now(),
  hoja      text,
  leidas    int,
  nuevas    int,
  cambios   int,
  invalidas int,
  aplicado  boolean,
  detalle   text
);
alter table public.perfil_sync_log enable row level security;
drop policy if exists perfil_sync_log_sel on public.perfil_sync_log;
create policy perfil_sync_log_sel on public.perfil_sync_log
  for select using ((select public.es_admin()));
revoke all on public.perfil_sync_log from anon;
grant select on public.perfil_sync_log to authenticated;
create index if not exists perfil_sync_log_ix on public.perfil_sync_log (corrio_en desc);

-- ---------------------------------------------------------------------------
-- 2) Utilidades de limpieza
-- ---------------------------------------------------------------------------
-- Cabecera normalizada: sin tildes, mayusculas y con los espacios colapsados, para no depender
-- de como este escrito el titulo en la hoja ("CATEGORÍA LICENCIA" -> "CATEGORIA LICENCIA").
create or replace function public._norm_cab(v text)
returns text language sql immutable as $function$
  select btrim(regexp_replace(
           translate(upper(coalesce(v, '')), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNAEIOUUN'),
           '\s+', ' ', 'g'));
$function$;

-- Fecha colombiana d/m/aaaa. Cualquier cosa rara (#N/D, 31/02/2020, año absurdo) -> null.
create or replace function public._f_cl(v text)
returns date language plpgsql immutable as $function$
declare d date;
begin
  if coalesce(btrim(v), '') !~ '^\d{1,2}/\d{1,2}/\d{4}$' then return null; end if;
  begin d := to_date(btrim(v), 'DD/MM/YYYY'); exception when others then return null; end;
  if extract(year from d) < 1900 or extract(year from d) > 2035 then return null; end if;
  return d;
end $function$;

-- Celular colombiano. Si la celda viene dañada por Excel (1,3E+09) no se inventa nada: null.
create or replace function public._cel_cl(v text)
returns text language sql immutable as $function$
  select case when coalesce(v, '') = '' or upper(v) like '%E+%' then null
              else (select m[1] from regexp_matches(regexp_replace(v, '\D', '', 'g'), '(3\d{9})') m limit 1)
         end;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Parser de CSV
--    Los saltos de linea DENTRO de comillas se neutralizan primero partiendo por el caracter
--    comilla: los trozos en posicion par son los que van dentro de comillas. Despues cada linea
--    se parte por las comas que quedan FUERA de comillas.
--    Las cabeceras repetidas (la hoja trae CIUDAD y DEPARTAMENTO dos veces) se renombran
--    "CIUDAD 2", si no la segunda pisaria a la primera.
-- ---------------------------------------------------------------------------
create or replace function public.csv_a_json(p_texto text)
returns setof jsonb
language plpgsql immutable
as $function$
declare
  v_limpio text; v_cab text[]; v_lin text; v_campos text[]; v_vals text[];
  i int; n int; v_k text; v_primera boolean := true;
begin
  select string_agg(case when ord % 2 = 0
                         then replace(replace(seg, E'\n', ' '), E'\r', ' ')
                         else seg end, '"' order by ord)
    into v_limpio
    from unnest(string_to_array(coalesce(p_texto, ''), '"')) with ordinality as u(seg, ord);

  for v_lin in select l from regexp_split_to_table(coalesce(v_limpio, ''), E'\n') as l loop
    v_lin := btrim(v_lin, E'\r');
    continue when btrim(v_lin) = '';
    v_campos := regexp_split_to_array(v_lin, ',(?=(?:[^"]*"[^"]*")*[^"]*$)');

    if v_primera then
      v_cab := '{}';
      for i in 1 .. coalesce(array_length(v_campos, 1), 0) loop
        v_k := public._norm_cab(btrim(v_campos[i], '"'));
        if v_k = '' then v_k := 'COL' || i; end if;
        if v_k = any (v_cab) then v_k := v_k || ' 2'; end if;
        if v_k = any (v_cab) then v_k := v_k || ' ' || i; end if;
        v_cab := v_cab || v_k;
      end loop;
      v_primera := false;
      continue;
    end if;

    n := coalesce(array_length(v_cab, 1), 0);
    v_vals := '{}';
    for i in 1 .. n loop
      v_vals := v_vals || coalesce(nullif(btrim(btrim(coalesce(v_campos[i], '')), '"'), ''), '');
    end loop;
    return next jsonb_object(v_cab[1:n], v_vals[1:n]);
  end loop;
end $function$;

-- ---------------------------------------------------------------------------
-- 4) La sincronizacion
-- ---------------------------------------------------------------------------
create or replace function public.perfil_sync(p_aplicar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_url_a text; v_url_c text;
  v_res jsonb := '[]'::jsonb;
  v_hoja record;
  v_txt text; v_txt_a text; v_txt_c text; v_st int; v_dup int := 0;
  v_leidas int; v_nuevas int; v_cambios int; v_malas int;
  v_total_nuevas int := 0; v_total_cambios int := 0;
begin
  if not (select public.es_admin()) and current_user not in ('postgres', 'supabase_admin') then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  select url_admin, url_conductores into v_url_a, v_url_c from public.perfil_fuente where id = 1;
  if coalesce(v_url_a, '') = '' and coalesce(v_url_c, '') = '' then
    return jsonb_build_object('ok', false, 'error',
      'Falta configurar el enlace de la hoja en perfil_fuente.');
  end if;

  perform set_config('http.timeout_msec', '60000', true);

  -- Se bajan las dos hojas primero para saber QUIEN APARECE EN LAS DOS. A esa persona no se le
  -- toca el cargo ni el area: una hoja dice "Auxiliar de taller" y la otra "Conductor", y si
  -- cada pasada la corrige, queda cambiando de ida y vuelta todos los dias. Se avisa y lo
  -- arregla Gestion Humana en la fuente.
  if coalesce(v_url_a, '') <> '' then
    select status, content into v_st, v_txt_a from extensions.http_get(v_url_a);
    if v_st <> 200 then v_txt_a := null; end if;
  end if;
  if coalesce(v_url_c, '') <> '' then
    select status, content into v_st, v_txt_c from extensions.http_get(v_url_c);
    if v_st <> 200 then v_txt_c := null; end if;
  end if;

  create temp table _dup on commit drop as
  select cedula from (
    select distinct regexp_replace(coalesce(j->>'CEDULA',''), '\D', '', 'g') as cedula, 'A' as h
      from public.csv_a_json(coalesce(v_txt_a, '')) j
    union all
    select distinct regexp_replace(coalesce(j->>'CEDULA',''), '\D', '', 'g'), 'C'
      from public.csv_a_json(coalesce(v_txt_c, '')) j
  ) t where length(cedula) between 4 and 15
  group by cedula having count(distinct h) = 2;
  select count(*) into v_dup from _dup;

  for v_hoja in
    select 'ADMIN' as origen, 'ADMINISTRATIVO' as tipo, v_url_a as url
    union all
    select 'CONDUCTORES', 'CONDUCTOR', v_url_c
  loop
    continue when coalesce(v_hoja.url, '') = '';
    v_txt := case when v_hoja.origen = 'ADMIN' then v_txt_a else v_txt_c end;
    if v_txt is null then
      insert into public.perfil_sync_log (hoja, leidas, nuevas, cambios, invalidas, aplicado, detalle)
      values (v_hoja.origen, 0, 0, 0, 0, p_aplicar, 'no se pudo descargar');
      v_res := v_res || jsonb_build_object('hoja', v_hoja.origen, 'error', 'no se pudo descargar');
      continue;
    end if;

    -- Las filas de la hoja, ya limpias y con la cedula como llave
    create temp table _f on commit drop as
    select regexp_replace(coalesce(j->>'CEDULA', ''), '\D', '', 'g')            as cedula,
           btrim(regexp_replace(upper(coalesce(j->>'APELLIDOS Y NOMBRE', '')), '\s+', ' ', 'g')) as nombre,
           nullif(upper(btrim(coalesce(j->>'ESTADO', ''))), '')                 as estado,
           nullif(upper(btrim(coalesce(j->>'CARGO', ''))), '')                  as cargo,
           nullif(upper(btrim(coalesce(j->>'AREA', ''))), '')                   as area,
           nullif(upper(btrim(coalesce(j->>'TIPO DE CONTRATO', ''))), '')       as tipo_contrato,
           public._f_cl(j->>'FECHA INGRESO')                                    as fecha_ingreso,
           public._f_cl(j->>'FECHA RETIRO COMPANIA')                            as fecha_retiro_a,
           public._f_cl(j->>'FECHA RETIRO COMPANA')                             as fecha_retiro_b,
           nullif(regexp_replace(coalesce(j->>'SALARIO', ''), '[^0-9]', '', 'g'), '')::numeric as salario,
           nullif(upper(btrim(coalesce(j->>'CENTRO COSTOS', ''))), '')          as centro_costos,
           nullif(upper(btrim(coalesce(j->>'NOMBRE PROPIETARIO', ''))), '')     as nombre_propietario,
           nullif(upper(btrim(coalesce(j->>'PLACA', ''))), '')                  as placa,
           nullif(upper(btrim(coalesce(j->>'CODIGO', ''))), '')                 as codigo,
           nullif(lower(btrim(coalesce(j->>'CORREO ELECTRONICO', ''))), '')     as correo,
           public._cel_cl(j->>'CELULAR')                                        as celular,
           public._cel_cl(j->>'TELEFONO')                                       as telefono,
           nullif(btrim(coalesce(j->>'KEY', '')), '')                           as key_appsheet,
           nullif(upper(btrim(coalesce(j->>'NOVEDAD DE RETIRO', ''))), '')      as novedad_retiro,
           nullif(upper(btrim(coalesce(j->>'CATEGORIA LICENCIA', ''))), '')     as categoria_licencia,
           nullif(btrim(coalesce(j->>'NUMERO LICENCIA DE CONDUCCION', '')), '') as numero_licencia,
           public._f_cl(j->>'FECHA DE EXPEDICION')                              as licencia_expedicion,
           public._f_cl(j->>'FECHA DE VENCIMIENTO')                             as licencia_vencimiento,
           nullif(upper(btrim(coalesce(j->>'RESTRICCIONES LICENCIA', ''))), '') as restricciones_licencia,
           nullif(upper(btrim(coalesce(j->>'ESTADO CONDUCTOR', ''))), '')       as estado_restriccion,
           nullif(upper(btrim(coalesce(j->>'MOTIVO RESTRICCION', ''))), '')     as motivo_restriccion
      from public.csv_a_json(v_txt) j;

    select count(*) into v_leidas from _f;

    -- Se descarta lo que no sirve: sin cedula, sin nombre o con un estado que no es de la casa.
    -- La hoja trae la MISMA persona varias veces (una fila por vinculacion: 379 repetidas en
    -- conductores). Se queda la vinculacion vigente: primero la que esta ACTIVO y, entre
    -- iguales, la de ingreso mas reciente. Asi un reingreso no revive una fecha de retiro vieja.
    create temp table _ok on commit drop as
    select distinct on (cedula) *,
           coalesce(fecha_retiro_a, fecha_retiro_b) as fecha_retiro
      from _f
     where length(cedula) between 4 and 15
       and nombre <> ''
       and estado in ('ACTIVO', 'INACTIVO')
     order by cedula, (estado = 'ACTIVO') desc, fecha_ingreso desc nulls last;

    select v_leidas - count(*) into v_malas from _ok;  -- casi todas son repetidas, no malas

    select count(*) into v_nuevas from _ok o
     where not exists (select 1 from public.perfilsociodemografico p where p.cedula = o.cedula);

    select count(*) into v_cambios from _ok o
      join public.perfilsociodemografico p on p.cedula = o.cedula
     where o.cedula not in (select cedula from _dup)
       and (o.estado, o.cargo, o.area, o.tipo_contrato, o.fecha_ingreso, o.fecha_retiro,
            o.salario, o.centro_costos, o.placa, o.nombre_propietario, o.novedad_retiro)
           is distinct from
           (p.estado, p.cargo, p.area, p.tipo_contrato, p.fecha_ingreso, p.fecha_retiro,
            p.salario, p.centro_costos, p.placa, p.nombre_propietario, p.novedad_retiro);

    if p_aplicar then
      -- Altas
      insert into public.perfilsociodemografico
        (cedula, nombre, tipo, origen, estado, cargo, area, tipo_contrato, fecha_ingreso, fecha_retiro,
         salario, centro_costos, nombre_propietario, placa, codigo, correo, celular, telefono,
         key_appsheet, novedad_retiro, categoria_licencia, numero_licencia, licencia_expedicion,
         licencia_vencimiento, restricciones_licencia, estado_restriccion, motivo_restriccion)
      select o.cedula, o.nombre, v_hoja.tipo, v_hoja.origen, o.estado, o.cargo, o.area, o.tipo_contrato,
             o.fecha_ingreso, o.fecha_retiro, o.salario, o.centro_costos, o.nombre_propietario, o.placa,
             o.codigo, o.correo, o.celular, o.telefono, o.key_appsheet, o.novedad_retiro,
             o.categoria_licencia, o.numero_licencia, o.licencia_expedicion, o.licencia_vencimiento,
             o.restricciones_licencia, o.estado_restriccion, o.motivo_restriccion
        from _ok o
       where not exists (select 1 from public.perfilsociodemografico p where p.cedula = o.cedula);

      -- Cambios. Lo laboral manda la hoja; el contacto solo se rellena si falta; lo personal
      -- (direccion, familia, estudios) no se toca.
      update public.perfilsociodemografico p set
        nombre = o.nombre,
        estado = o.estado,
        cargo = case when exists (select 1 from _dup d where d.cedula = o.cedula)
                     then p.cargo else o.cargo end,
        area  = case when exists (select 1 from _dup d where d.cedula = o.cedula)
                     then p.area else coalesce(o.area, p.area) end,
        tipo_contrato = coalesce(o.tipo_contrato, p.tipo_contrato),
        fecha_ingreso = coalesce(o.fecha_ingreso, p.fecha_ingreso),
        fecha_retiro = o.fecha_retiro,
        salario = coalesce(o.salario, p.salario),
        centro_costos = coalesce(o.centro_costos, p.centro_costos),
        nombre_propietario = coalesce(o.nombre_propietario, p.nombre_propietario),
        placa = coalesce(o.placa, p.placa),
        codigo = coalesce(o.codigo, p.codigo),
        novedad_retiro = o.novedad_retiro,
        correo = coalesce(p.correo, o.correo),
        celular = coalesce(p.celular, o.celular),
        telefono = coalesce(p.telefono, o.telefono),
        key_appsheet = coalesce(p.key_appsheet, o.key_appsheet),
        categoria_licencia = coalesce(o.categoria_licencia, p.categoria_licencia),
        numero_licencia = coalesce(o.numero_licencia, p.numero_licencia),
        licencia_expedicion = coalesce(o.licencia_expedicion, p.licencia_expedicion),
        licencia_vencimiento = coalesce(o.licencia_vencimiento, p.licencia_vencimiento),
        restricciones_licencia = coalesce(o.restricciones_licencia, p.restricciones_licencia),
        estado_restriccion = coalesce(o.estado_restriccion, p.estado_restriccion),
        motivo_restriccion = coalesce(o.motivo_restriccion, p.motivo_restriccion),
        -- Quien aparece en las dos hojas queda marcado, y NO se le cambia el tipo
        origen = case when p.origen is distinct from v_hoja.origen and p.origen is not null
                      then 'AMBOS' else v_hoja.origen end
      from _ok o
      where p.cedula = o.cedula;
    end if;

    insert into public.perfil_sync_log (hoja, leidas, nuevas, cambios, invalidas, aplicado, detalle)
    values (v_hoja.origen, v_leidas, v_nuevas, v_cambios, v_malas, p_aplicar,
            case when p_aplicar then 'aplicado' else 'simulacro' end);

    v_res := v_res || jsonb_build_object('hoja', v_hoja.origen, 'leidas', v_leidas,
                                         'nuevas', v_nuevas, 'cambios', v_cambios,
                                         'repetidas_o_malas', v_malas);
    v_total_nuevas := v_total_nuevas + v_nuevas;
    v_total_cambios := v_total_cambios + v_cambios;
    drop table _f; drop table _ok;
  end loop;

  if p_aplicar then
    update public.perfil_fuente
       set ultima_carga = now(),
           ultimo_total = (select count(*) from public.perfilsociodemografico)
     where id = 1;
  end if;

  return jsonb_build_object('ok', true, 'aplicado', p_aplicar,
                            'nuevas', v_total_nuevas, 'cambios', v_total_cambios,
                            'en_las_dos_hojas', v_dup, 'hojas', v_res);
end $function$;

revoke all on function public.perfil_sync(boolean) from public, anon;
grant execute on function public.perfil_sync(boolean) to authenticated;
revoke all on function public.csv_a_json(text) from public, anon;

-- ---------------------------------------------------------------------------
-- 5) Que corra sola. Los crons de este proyecto estan en UTC (sync-conductores-sonar @ 0 8
--    es la de las 3 a.m. de Colombia), asi que 9:30 y 17:30 UTC = 4:30 a.m. y 12:30 p.m.
--    Dos veces al dia: la de la madrugada deja todo listo antes del primer turno y la del
--    mediodia recoge a quien contrataron en la manana (si no, no podria hacer el
--    preoperacional hasta el dia siguiente). Cada corrida son ~4 s.
-- ---------------------------------------------------------------------------
select cron.unschedule('sync-personal-hoja')
 where exists (select 1 from cron.job where jobname = 'sync-personal-hoja');
select cron.schedule('sync-personal-hoja', '30 9,17 * * *', $cron$select public.perfil_sync(true)$cron$);

-- Comprobacion (solo lectura: un rollback aqui borraria el DDL de arriba, ver sql/131)
select 'funciones creadas' as dato,
       string_agg(p.proname, ' | ' order by p.proname) as valor
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('perfil_sync', 'csv_a_json', '_f_cl', '_cel_cl', '_norm_cab')
union all
select 'fuente configurada',
       coalesce((select case when coalesce(url_admin,'') <> '' then 'si' else 'no' end
                   from public.perfil_fuente where id = 1), 'falta insertar la fila')
union all
select 'parser: fecha 31/12/2024', coalesce(public._f_cl('31/12/2024')::text, 'null')
union all
select 'parser: fecha 31/02/2024', coalesce(public._f_cl('31/02/2024')::text, 'null (bien)')
union all
select 'parser: celular dañado 1,3E+09', coalesce(public._cel_cl('1,3E+09'), 'null (bien)')
union all
select 'cron programado',
       coalesce((select schedule from cron.job where jobname = 'sync-personal-hoja'), 'NO')
union all
select 'parser: csv con coma dentro',
       (select j::text from public.csv_a_json(E'A,B\n1,"x, y"') j);
