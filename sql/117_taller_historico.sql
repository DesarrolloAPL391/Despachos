-- ===================================================================================
-- 117: EL HISTÓRICO DEL TALLER — qué le han hecho a cada bus, hacia atrás.
-- ===================================================================================
-- Hasta ahora el módulo solo mostraba el presente: lo que está abierto hoy. La pregunta
-- que no se podía responder es la que más sirve para decidir: ¿este bus cuántas veces ha
-- entrado al taller este año? ¿cuánto lleva costado? ¿cuál de todos se vara más?
--
-- LO QUE PERMITE LA API (verificado el 23/09/2026):
--   - Las órdenes se pueden pedir por rango de fechas, pero el rango NO puede pasar de
--     180 días: a 180 exactos ya responde "Start Date Range cannot exceeds 180 days".
--     Por eso esto va por tramos de 175 días, que dejan margen.
--   - Se piden los estados `closed` (cerradas) y `voided` (anuladas), que son los que no
--     trae la sincronización de todos los días (esa solo mira lo que está en el taller).
--
-- LO QUE HAY QUE SABER ANTES DE MIRAR LOS NÚMEROS:
--   De 278 órdenes de los últimos seis meses, solo 10 están CERRADAS. El resto quedó en
--   "cierre técnico": el bus salió del taller pero la orden nunca se cerró. Así que un
--   informe de costos por periodo hoy estaría contando sobre esas 10. El dato no está mal
--   traído: está mal cerrado en el taller, y esto lo deja a la vista.
-- ===================================================================================

-- ---------- 1) Traer hacia atrás ----------
-- No borra ni marca nada: solo agrega. Lo que ya está en el espejo se actualiza.
create or replace function public.taller_sync_historico(
  p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_t0 timestamptz := clock_timestamp();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_hasta date := coalesce(p_hasta, v_hoy);
  v_desde date := coalesce(p_desde, v_hoy - 365);
  v_a date; v_b date; v_st text; v_url text; v_pag int;
  v_r jsonb; v_arr jsonb; v_n int; v_nn int;
  v_filas int := 0; v_nuevas int := 0; v_tramos int := 0;
begin
  if not public.taller_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede traer el histórico.';
  end if;
  if v_desde >= v_hasta then
    return jsonb_build_object('ok', false, 'error', 'El rango está al revés.');
  end if;

  v_a := v_desde;
  while v_a < v_hasta loop
    v_b := least(v_a + 175, v_hasta);          -- la API rechaza rangos de 180 días o más
    v_tramos := v_tramos + 1;
    foreach v_st in array array['closed', 'voided'] loop
      v_url := 'work-orders/?status=' || v_st
            || '&startDateFrom=' || to_char(v_a, 'YYYY-MM-DD') || 'T00:00:00Z'
            || '&startDateTo='   || to_char(v_b, 'YYYY-MM-DD') || 'T23:59:59Z';
      v_pag := 0;
      loop
        v_pag := v_pag + 1;
        v_r := public.taller_http(v_url);
        if not coalesce((v_r->>'ok')::boolean, false) then
          -- Un tramo sin resultados contesta 404 con "no encontré": eso no es una falla,
          -- es un periodo sin órdenes. Se sigue con el siguiente.
          exit when v_r->>'error' like '%404%' or v_r->>'error' ilike '%not found%'
                 or v_r->>'detalle' ilike '%No Work Orders%';
          insert into public.taller_sync (que, error, ms)
          values ('historico/' || v_st, left(v_r->>'error', 300),
                  (extract(milliseconds from clock_timestamp() - v_t0))::int);
          return v_r;
        end if;
        v_arr := v_r->'datos';
        exit when jsonb_typeof(v_arr) <> 'array';

        select count(*) into v_n from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$';
        select count(*) into v_nn from jsonb_array_elements(v_arr) t
         where (t->>'number') ~ '^[0-9]+$'
           and not exists (select 1 from public.taller_ordenes o where o.numero = (t->>'number')::int);

        with f as (select t from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$')
        insert into public.taller_ordenes as o (
          numero, movil, estado, tipo, afecta_disponib, motivo, falla, taller, etiquetas,
          fecha_taller, fecha_inicio, fin_estimado, odometro, cierre_tecnico_en, cierre_final_en,
          costo_total, grupo, conductor, fuera_listado, salio_en, vista_en, crudo)
        select (t->>'number')::int,
               btrim(coalesce(t->>'vehicleCode', '')),
               t->>'status', t->>'type',
               coalesce((t->>'affectsVehicleAvailability')::boolean, false),
               nullif(btrim(coalesce(t->>'reason', '')), ''),
               nullif(btrim(coalesce(t->>'detectedIssue', '')), ''),
               t->'vendor'->>'name',
               case when jsonb_typeof(t->'maintenanceLabels') = 'array'
                    then (select array_agg(x #>> '{}') from jsonb_array_elements(t->'maintenanceLabels') x)
               end,
               nullif(t->>'workshopDate', '')::timestamptz,
               nullif(t->>'startDate', '')::timestamptz,
               nullif(t->>'estimatedFinishDate', '')::timestamptz,
               nullif(t->>'odometer', '')::numeric,
               nullif(t->>'technicalCompletionDate', '')::timestamptz,
               nullif(t->>'finalCompletionDate', '')::timestamptz,
               nullif(t->>'totalCost', '')::numeric,
               t->'primaryGroup'->>'name',
               t->'driver'->>'name',
               true,                                    -- cerrada: ya no está en el taller
               coalesce(nullif(t->>'finalCompletionDate', '')::timestamptz,
                        nullif(t->>'technicalCompletionDate', '')::timestamptz),
               now(), t
          from f
        on conflict (numero) do update set
          movil = excluded.movil, estado = excluded.estado, tipo = excluded.tipo,
          afecta_disponib = excluded.afecta_disponib, motivo = excluded.motivo, falla = excluded.falla,
          taller = excluded.taller, etiquetas = excluded.etiquetas,
          fecha_taller = excluded.fecha_taller, fecha_inicio = excluded.fecha_inicio,
          fin_estimado = excluded.fin_estimado, odometro = excluded.odometro,
          cierre_tecnico_en = excluded.cierre_tecnico_en, cierre_final_en = excluded.cierre_final_en,
          costo_total = excluded.costo_total, grupo = excluded.grupo, conductor = excluded.conductor,
          fuera_listado = true, salio_en = excluded.salio_en, vista_en = now(), crudo = excluded.crudo;

        v_filas := v_filas + coalesce(v_n, 0);
        v_nuevas := v_nuevas + coalesce(v_nn, 0);
        v_url := v_r->>'next';
        exit when coalesce(v_url, '') = '' or v_pag >= 20;
      end loop;
    end loop;
    v_a := v_b + 1;
  end loop;

  insert into public.taller_sync (que, filas, nuevas, ms)
  values ('historico', v_filas, v_nuevas, (extract(milliseconds from clock_timestamp() - v_t0))::int);

  return jsonb_build_object('ok', true, 'desde', v_desde, 'hasta', v_hasta,
    'tramos', v_tramos, 'filas', v_filas, 'nuevas', v_nuevas);
end $fn$;
revoke all on function public.taller_sync_historico(date, date) from public, anon;
grant execute on function public.taller_sync_historico(date, date) to authenticated;

-- ---------- 2) Consultar el histórico ----------
-- Sin móvil: el ranking de los que más entran al taller en el periodo.
-- Con móvil: la hoja de vida de ese bus, orden por orden.
create or replace function public.taller_historial(
  p_desde date default null, p_hasta date default null, p_movil text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_h date := coalesce(p_hasta, v_hoy);
  v_d date := coalesce(p_desde, v_hoy - 365);
  v_mov text := nullif(btrim(coalesce(p_movil, '')), '');
  v_admin boolean;
begin
  v_admin := ( (select public.es_admin()) or (select public.es_operaciones())
            or (select public.es_auditor()) or (select public.es_consola()) );
  if not (v_admin or (select public.es_despachador())) then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso.');
  end if;

  return jsonb_build_object('ok', true, 'desde', v_d, 'hasta', v_h, 'movil', v_mov, 'admin', v_admin,
    'resumen', (
      select jsonb_build_object(
        'ordenes',     count(*),
        'moviles',     count(distinct o.movil),
        'correctivas', count(*) filter (where o.tipo = 'CORRECTIVO'),
        'preventivas', count(*) filter (where o.tipo = 'PREVENTIVO'),
        'cerradas',    count(*) filter (where o.estado = 'closed'),
        'sin_cerrar',  count(*) filter (where o.estado = 'onTechnicalCompletion'),
        'abiertas',    count(*) filter (where o.estado = 'opened' and not o.fuera_listado),
        -- El costo solo se puede sumar de lo que está cerrado; lo demás todavía se mueve.
        'costo',       case when v_admin then coalesce(sum(o.costo_total) filter (where o.estado = 'closed'), 0) end)
        from public.taller_ordenes o
       where (o.fecha_inicio at time zone 'America/Bogota')::date between v_d and v_h
         and (v_mov is null or o.movil = v_mov)),
    'por_movil', (
      select coalesce(jsonb_agg(x order by (x->>'entradas')::int desc, (x->>'correctivas')::int desc), '[]'::jsonb)
        from (
          select jsonb_build_object(
                   'movil', o.movil,
                   'entradas', count(*),
                   'correctivas', count(*) filter (where o.tipo = 'CORRECTIVO'),
                   'preventivas', count(*) filter (where o.tipo = 'PREVENTIVO'),
                   'fuera_servicio', count(*) filter (where o.afecta_disponib),
                   'dias', coalesce(sum(
                     greatest(( (coalesce(o.salio_en, o.cierre_tecnico_en, now()) at time zone 'America/Bogota')::date
                              - (o.fecha_inicio at time zone 'America/Bogota')::date ), 0)), 0),
                   'ultima', max(o.fecha_inicio),
                   'costo', case when v_admin then coalesce(sum(o.costo_total) filter (where o.estado = 'closed'), 0) end) as x
            from public.taller_ordenes o
           where (o.fecha_inicio at time zone 'America/Bogota')::date between v_d and v_h
             and (v_mov is null or o.movil = v_mov)
           group by o.movil) s),
    'detalle', (
      case when v_mov is null then '[]'::jsonb else (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'numero', o.numero, 'tipo', o.tipo, 'estado', o.estado,
                 'afecta', o.afecta_disponib,
                 'motivo', left(coalesce(o.motivo, o.falla, ''), 300),
                 'etiquetas', coalesce(o.etiquetas, '{}'),
                 'desde', o.fecha_inicio, 'salio', coalesce(o.salio_en, o.cierre_tecnico_en),
                 'dias', greatest(( (coalesce(o.salio_en, o.cierre_tecnico_en, now()) at time zone 'America/Bogota')::date
                                  - (o.fecha_inicio at time zone 'America/Bogota')::date ), 0),
                 'odometro', o.odometro,
                 'costo', case when v_admin then o.costo_total end)
               order by o.fecha_inicio desc), '[]'::jsonb)
          from public.taller_ordenes o
         where o.movil = v_mov
           and (o.fecha_inicio at time zone 'America/Bogota')::date between v_d and v_h) end),
    'rango_guardado', (
      select jsonb_build_object('desde', min((fecha_inicio at time zone 'America/Bogota')::date),
                                'hasta', max((fecha_inicio at time zone 'America/Bogota')::date),
                                'ordenes', count(*))
        from public.taller_ordenes));
end $fn$;
revoke all on function public.taller_historial(date, date, text) from public, anon;
grant execute on function public.taller_historial(date, date, text) to authenticated;

-- ===================================================================================
-- La primera carga (un año hacia atrás; son ~6 llamadas, contra el techo de 4000 al día):
--   select public.taller_sync_historico();
--   select public.taller_historial();                  -- ranking del último año
--   select public.taller_historial(null, null, '5517'); -- la hoja de vida de un bus
-- Para ir más atrás:
--   select public.taller_sync_historico(date '2024-01-01', date '2025-09-23');
-- ===================================================================================
