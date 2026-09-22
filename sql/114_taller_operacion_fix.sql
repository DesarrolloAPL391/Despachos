-- ===================================================================================
-- 114: EL CRUCE CON LA OPERACIÓN, BIEN HECHO (corrige sql/113).
-- ===================================================================================
-- Dos errores en taller_en_operacion, los dos del mismo origen: escribí la consulta
-- mirando el esquema viejo (sql/01) en vez de cómo funciona la operación de verdad.
--
-- 1) LA COLUMNA NO EXISTE. No hay `despachos.despachado`; el estado real se guarda en
--    `estado_despacho` ('DESPACHADO' / 'SI') y, cuando el viaje salió a SONAR, queda el
--    `sonar_regid`. Ese es el criterio que ya usa _despachos_realizados (sql/55) y es el
--    que se usa aquí, para que las dos partes del sistema cuenten lo mismo.
--
-- 2) Y EL PEOR: MIRABA DONDE CASI NUNCA HAY NADA. Los despachos de TABLA (turno fijo) no
--    viven en `despachos`: cada puesto guarda los suyos en su propia tabla (laureles,
--    t_130, ...; están listadas en public.tablas_despacho). En `despachos` solo va el
--    LIBRE. Así que el cruce habría dado cero entre semana y nadie se habría enterado de
--    que estaba mal: un cero se lee como "todo bien", que es la peor forma de fallar.
--    Ahora recorre todas las fuentes, igual que hace _despachos_realizados.
--
-- Se cuentan dos cosas distintas a propósito:
--   - DESPACHADO hoy: ya salió. Es un hecho que hay que explicar.
--   - PROGRAMADO hoy: todavía no sale. Es lo único que aún se puede mover.
--
-- De paso: estas funciones también responden desde el SQL Editor. Antes contestaban
-- `ok:false` porque preguntaban por el rol del usuario de la app y ahí no hay sesión.
-- ===================================================================================

-- ---------- Quién está preguntando ----------
-- Igual que taller_puede_traer: el dueño de la base consultando desde la consola (sin JWT)
-- es administración por definición; no tiene sentido negarle una lectura.
create or replace function public.es_consola()
returns boolean
language sql stable security definer set search_path = public as $fn$
  select auth.uid() is null and session_user in ('postgres', 'supabase_admin');
$fn$;
revoke all on function public.es_consola() from public, anon;
grant execute on function public.es_consola() to authenticated;

-- ---------- El cruce ----------
create or replace function public.taller_en_operacion(p_fecha date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_f date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
  v_base text; v_prog text; v_sql text := ''; v_cnt jsonb; r record;
begin
  if not ( (select public.es_admin()) or (select public.es_operaciones())
        or (select public.es_auditor()) or (select public.es_despachador())
        or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso.');
  end if;

  -- Realizado = como lo define _despachos_realizados (sql/55): estado DESPACHADO/SI, o con
  -- viaje en SONAR. Programado = el carro que la programación puso para hoy.
  v_base := $tpl$
    select trim(coalesce(v.numero, '')) as movil,
           count(*) filter (where x.estado_despacho in ('DESPACHADO', 'SI')
                               or x.sonar_regid is not null)::bigint as d,
           0::bigint as p
      from public.%1$I x
      join public.vehiculos v on v.id = x.vehiculo_id
     where x.fecha = $1 and x.vehiculo_id is not null
     group by 1
  $tpl$;
  v_prog := $tpl$
    select trim(coalesce(v.numero, '')) as movil, 0::bigint as d, count(*)::bigint as p
      from public.%1$I x
      join public.vehiculos v on v.id = x.vehiculo_programado_id
     where x.fecha = $1 and x.vehiculo_programado_id is not null
     group by 1
  $tpl$;

  -- Dinámico: si mañana crean un puesto nuevo, entra solo. La columna de lo programado se
  -- comprueba tabla por tabla porque no todas las de puesto la tienen.
  for r in select t.tabla from public.tablas_despacho t
           union select 'despachos' order by 1
  loop
    if to_regclass('public.' || quote_ident(r.tabla)) is null then continue; end if;
    v_sql := v_sql || case when v_sql = '' then '' else ' union all ' end || format(v_base, r.tabla);
    if exists (select 1 from information_schema.columns c
                where c.table_schema = 'public' and c.table_name = r.tabla
                  and c.column_name = 'vehiculo_programado_id') then
      v_sql := v_sql || ' union all ' || format(v_prog, r.tabla);
    end if;
  end loop;

  if v_sql = '' then return jsonb_build_object('ok', true, 'fecha', v_f, 'filas', '[]'::jsonb); end if;

  execute 'with t as (' || v_sql || ') '
       || 'select coalesce(jsonb_object_agg(movil, jsonb_build_object(''d'', d, ''p'', p)), ''{}''::jsonb) '
       || 'from (select movil, sum(d) d, sum(p) p from t where movil <> '''' group by movil) z'
    into v_cnt using v_f;

  return jsonb_build_object('ok', true, 'fecha', v_f,
    'filas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'movil', o.movil, 'orden', o.numero, 'tipo', o.tipo,
               'motivo', left(coalesce(o.motivo, o.falla, ''), 160),
               'dias', greatest((v_f - (o.fecha_inicio at time zone 'America/Bogota')::date), 0),
               'despachados', coalesce((v_cnt -> o.movil ->> 'd')::int, 0),
               'programados', coalesce((v_cnt -> o.movil ->> 'p')::int, 0))
             order by coalesce((v_cnt -> o.movil ->> 'd')::int, 0) desc, o.movil), '[]'::jsonb)
        from public.taller_ordenes o
       where o.estado = 'opened' and not o.fuera_listado and o.afecta_disponib
         and ( coalesce((v_cnt -> o.movil ->> 'd')::int, 0) > 0
            or coalesce((v_cnt -> o.movil ->> 'p')::int, 0) > 0 )));
end $fn$;
revoke all on function public.taller_en_operacion(date) from public, anon;
grant execute on function public.taller_en_operacion(date) to authenticated;

-- ---------- Que el tablero y el resumen de licencias respondan en la consola ----------
create or replace function public.taller_fuera_n()
returns int
language sql stable security definer set search_path = public as $fn$
  select case when ( (select public.es_admin()) or (select public.es_operaciones())
                  or (select public.es_auditor()) or (select public.es_despachador())
                  or (select public.es_consola()) )
    then (select count(*)::int from public.taller_ordenes
           where estado = 'opened' and not fuera_listado and afecta_disponib)
    else 0 end;
$fn$;
revoke all on function public.taller_fuera_n() from public, anon;
grant execute on function public.taller_fuera_n() to authenticated;

-- El resumen de licencias: es el número del que depende el plazo del sábado 26, y hasta
-- ahora no se podía consultar desde el SQL Editor porque exigía sesión de la app.
create or replace function public.licencia_bloqueo_resumen()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare cfg public.licencia_bloqueo_config%rowtype; v_hoy date; v jsonb;
begin
  if not ( (select public.es_admin()) or (select public.es_operaciones())
        or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false);
  end if;
  select * into cfg from public.licencia_bloqueo_config where id = 1;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  select jsonb_build_object(
    'vencidas',    count(*) filter (where a.dias < 0 and not a.en_revision),
    'en_revision', count(*) filter (where a.dias < 0 and a.en_revision),
    'por_vencer',  count(*) filter (where a.dias >= 0 and a.dias <= 30))
    into v
    from (
      -- distinct on: un mismo conductor puede tener dos dr_id en SONAR y contaría doble
      select distinct on (p.cedula)
             (p.licencia_vencimiento - v_hoy) as dias,
             exists (select 1 from public.licencia_actualizaciones l
                      where l.cedula = p.cedula and l.estado = 'PENDIENTE') as en_revision
        from public.conductores_sonar c
        join public.perfilsociodemografico p
          on p.cedula = regexp_replace(coalesce(c.cedula, ''), '\D', '', 'g')
       where c.status = 'ENABLED' and p.estado = 'ACTIVO'
         and p.licencia_vencimiento is not null
       order by p.cedula, c.dr_id) a;

  return jsonb_build_object('ok', true, 'desde', cfg.desde, 'activo', cfg.activo,
    'faltan_dias', greatest(cfg.desde - v_hoy, 0),
    'vigente', (coalesce(cfg.activo, false) and v_hoy >= cfg.desde)) || coalesce(v, '{}'::jsonb);
end $fn$;
revoke all on function public.licencia_bloqueo_resumen() from public, anon;
grant execute on function public.licencia_bloqueo_resumen() to authenticated;

-- ===================================================================================
-- Todo en una sola consulta, ahora sí desde el SQL Editor:
--   select public.taller_en_operacion()  as taller_vs_operacion,
--          public.licencia_bloqueo_resumen() as licencias;
-- ===================================================================================
