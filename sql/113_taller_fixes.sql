-- ===================================================================================
-- 113: CORRECCIONES AL TALLER (sql/111) + el despachador también lo ve.
-- ===================================================================================
-- Tres cosas, encontradas viendo el tablero con datos reales el 22/09/2026:
--
-- 1) EL BANNER DE ERROR MENTÍA. Mostraba el último error que hubiera existido alguna vez,
--    aunque después todo hubiera salido bien. Quedaba en pantalla "Falta CF_API_KEY en el
--    Vault" con el tablero lleno de datos. Ahora solo se muestra si el ÚLTIMO intento
--    falló: un error viejo, ya superado, no es un error.
--
-- 2) LA PROGRAMACIÓN SALÍA EN CERO. Traía las 106 filas y las borraba enseguida. El
--    borrado de "lo que ya no vino" comparaba `vista_en` (que se escribe con now()) contra
--    clock_timestamp(). En Postgres now() es el instante en que arrancó la TRANSACCIÓN, no
--    el de la fila: como la traída de programación corre después de órdenes y novedades,
--    su clock_timestamp() siempre era mayor que el now() de sus propios inserts, y el
--    delete se llevaba todo lo que acababa de entrar. Ahora se lleva la lista de
--    consecutivos vistos, igual que hacen órdenes y novedades, que no dependen del reloj.
--
-- 3) EL DESPACHADOR NO VEÍA NADA. Solo le salía el aviso del móvil que tenía en la mano.
--    Ahora entra al tablero y ve qué carros están en el taller, para poder mover la
--    programación antes de que el problema llegue a la hora del despacho. No ve costos
--    ni el represamiento administrativo: eso no es asunto suyo.
--
-- Y algo que no existía: el CRUCE CON LA OPERACIÓN. Un bus marcado fuera de servicio que
-- aparece despachado hoy es la alerta que de verdad importa — o el taller no cerró la
-- orden, o ese carro está rodando cuando no debería. Cualquiera de las dos hay que
-- resolverla, y hasta hoy nadie la veía porque cada sistema miraba su propia mitad.
-- ===================================================================================

-- ---------- 1) La programación, sin depender del reloj ----------
create or replace function public.taller_sync_programacion()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  cfg public.taller_config%rowtype;
  v_t0 timestamptz := clock_timestamp();
  v_hoy date; v_url text; v_pag int := 0;
  v_r jsonb; v_arr jsonb; v_n int; v_nn int;
  v_ids int[]; v_vistos int[] := '{}';
  v_filas int := 0; v_nuevas int := 0; v_viejas int := 0;
begin
  if not public.taller_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede sincronizar el taller.';
  end if;
  select * into cfg from public.taller_config where id = 1;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  v_url := 'maintenance-schedules/?dateToExecuteFrom=' || to_char(v_hoy - cfg.prog_atras, 'YYYY-MM-DD') || 'T00:00:00Z'
        || '&dateToExecuteTo=' || to_char(v_hoy + cfg.prog_adelante, 'YYYY-MM-DD') || 'T23:59:59Z';

  loop
    v_pag := v_pag + 1;
    v_r := public.taller_http(v_url);
    if not coalesce((v_r->>'ok')::boolean, false) then
      insert into public.taller_sync (que, error, ms)
      values ('programacion', left(v_r->>'error', 300),
              (extract(milliseconds from clock_timestamp() - v_t0))::int);
      return v_r;
    end if;
    v_arr := v_r->'datos';
    exit when jsonb_typeof(v_arr) <> 'array';

    select count(*) into v_n from jsonb_array_elements(v_arr) t where (t->>'consecutive') ~ '^[0-9]+$';
    select count(*) into v_nn from jsonb_array_elements(v_arr) t
     where (t->>'consecutive') ~ '^[0-9]+$'
       and not exists (select 1 from public.taller_programacion p where p.consecutivo = (t->>'consecutive')::int);

    with f as (select t from jsonb_array_elements(v_arr) t where (t->>'consecutive') ~ '^[0-9]+$')
    insert into public.taller_programacion as p (
      consecutivo, movil, trabajo, rutina, estado, fecha_ejecutar, dias_dif,
      odom_objetivo, odom_dif, orden_creada, orden_ejecucion, fuente, tipo, vista_en, crudo)
    select (t->>'consecutive')::int,
           btrim(coalesce(t->'vehicle'->>'code', '')),
           t->'task'->>'name',
           t->'routine'->>'name',
           t->>'status',
           nullif(t->>'dateToExecute', '')::timestamptz,
           nullif(t->>'dateToExecuteDaysDiff', '')::numeric,
           nullif(t->>'odometerToExecute', '')::numeric,
           nullif(t->>'odometerToExecuteDiff', '')::numeric,
           nullif(t->'woCreation'->>'number', '')::int,
           nullif(t->'woExecution'->>'number', '')::int,
           t->>'scheduleSource', t->>'scheduleType', now(), t
      from f
    on conflict (consecutivo) do update set
      movil = excluded.movil, trabajo = excluded.trabajo, rutina = excluded.rutina,
      estado = excluded.estado, fecha_ejecutar = excluded.fecha_ejecutar,
      dias_dif = excluded.dias_dif, odom_objetivo = excluded.odom_objetivo,
      odom_dif = excluded.odom_dif, orden_creada = excluded.orden_creada,
      orden_ejecucion = excluded.orden_ejecucion, fuente = excluded.fuente,
      tipo = excluded.tipo, vista_en = now(), crudo = excluded.crudo;

    select coalesce(array_agg((t->>'consecutive')::int), '{}') into v_ids
      from jsonb_array_elements(v_arr) t where (t->>'consecutive') ~ '^[0-9]+$';
    v_vistos := v_vistos || v_ids;
    v_filas  := v_filas + coalesce(v_n, 0);
    v_nuevas := v_nuevas + coalesce(v_nn, 0);
    v_url := v_r->>'next';
    exit when coalesce(v_url, '') = '' or v_pag >= 12;
  end loop;

  -- Lo que estaba en la ventana y ya no vino: le movieron la fecha o se ejecutó. Se compara
  -- contra la lista de lo que llegó, NO contra la hora: ese fue el error que vaciaba la tabla.
  if array_length(v_vistos, 1) is not null then
    delete from public.taller_programacion
     where fecha_ejecutar >= (v_hoy - cfg.prog_atras)::timestamptz
       and fecha_ejecutar <  (v_hoy + cfg.prog_adelante + 1)::timestamptz
       and consecutivo <> all (v_vistos);
    get diagnostics v_viejas = row_count;
  end if;

  insert into public.taller_sync (que, filas, nuevas, ms)
  values ('programacion', v_filas, v_nuevas, (extract(milliseconds from clock_timestamp() - v_t0))::int);

  return jsonb_build_object('ok', true, 'filas', v_filas, 'nuevas', v_nuevas, 'salieron', v_viejas);
end $fn$;

-- ---------- 2) ¿Un bus fuera de servicio se está despachando? ----------
-- El cruce que nadie tenía: el taller dice "no debería rodar" y la operación lo despachó.
-- Se mira por el vehículo real y por el programado, porque las dos cosas importan: uno ya
-- pasó, el otro está por pasar y todavía se puede mover.
create or replace function public.taller_en_operacion(p_fecha date default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare v_f date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
begin
  if not ( (select public.es_admin()) or (select public.es_operaciones())
        or (select public.es_auditor()) or (select public.es_despachador()) ) then
    return jsonb_build_object('ok', false);
  end if;

  return jsonb_build_object('ok', true, 'fecha', v_f,
    'filas', (
      select coalesce(jsonb_agg(x order by x->>'movil'), '[]'::jsonb) from (
        select jsonb_build_object(
                 'movil', o.movil,
                 'orden', o.numero,
                 'tipo', o.tipo,
                 'motivo', left(coalesce(o.motivo, o.falla, ''), 160),
                 'dias', greatest((v_f - (o.fecha_inicio at time zone 'America/Bogota')::date), 0),
                 'despachados', (
                   select count(*) from public.despachos d
                    join public.vehiculos v on v.id = d.vehiculo_id
                   where d.fecha = v_f and btrim(coalesce(v.numero, '')) = o.movil
                     and coalesce(d.despachado, false)),
                 'programados', (
                   select count(*) from public.despachos d
                    join public.vehiculos v on v.id = d.vehiculo_programado_id
                   where d.fecha = v_f and btrim(coalesce(v.numero, '')) = o.movil)) as x
          from public.taller_ordenes o
         where o.estado = 'opened' and not o.fuera_listado and o.afecta_disponib) s
      where (x->>'despachados')::int > 0 or (x->>'programados')::int > 0));
end $fn$;
revoke all on function public.taller_en_operacion(date) from public, anon;
grant execute on function public.taller_en_operacion(date) to authenticated;

-- ---------- 3) El tablero: sin errores viejos, y abierto al despachador ----------
create or replace function public.taller_tablero()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v jsonb; v_min int; v_err text; v_falta boolean; v_admin boolean;
begin
  v_admin := ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor()) );
  if not (v_admin or (select public.es_despachador())) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver el taller.');
  end if;

  select (extract(epoch from (now() - max(cuando))) / 60)::int into v_min
    from public.taller_sync where error is null;

  -- Solo si el ÚLTIMO intento falló. Un error superado por una traída buena no se muestra.
  select left(error, 200) into v_err
    from public.taller_sync
   where error is not null
     and cuando > coalesce((select max(cuando) from public.taller_sync where error is null),
                           '-infinity'::timestamptz)
   order by cuando desc limit 1;

  v_falta := not exists (select 1 from public.taller_sync where error is null);

  select jsonb_build_object(
    'abiertas',      count(*) filter (where estado = 'opened' and not fuera_listado),
    'afectan',       count(*) filter (where estado = 'opened' and not fuera_listado and afecta_disponib),
    'correctivas',   count(*) filter (where estado = 'opened' and not fuera_listado and tipo = 'CORRECTIVO'),
    'cierre_tecnico',count(*) filter (where estado = 'onTechnicalCompletion' and not fuera_listado),
    'viejas',        count(*) filter (where estado = 'opened' and not fuera_listado
                                        and fecha_inicio < (v_hoy - 7)::timestamptz))
    into v from public.taller_ordenes;

  return jsonb_build_object('ok', true, 'sync_hace_min', v_min, 'sin_traer', v_falta,
    'ultimo_error', v_err, 'admin', v_admin,
    'ordenes', v,
    'lista', (select coalesce(jsonb_agg(jsonb_build_object(
                'numero', o.numero, 'movil', o.movil, 'tipo', o.tipo, 'estado', o.estado,
                'afecta', o.afecta_disponib, 'taller', o.taller, 'grupo', o.grupo,
                'motivo', left(coalesce(o.motivo, o.falla, ''), 200),
                'etiquetas', coalesce(o.etiquetas, '{}'),
                'desde', o.fecha_inicio, 'fin_estimado', o.fin_estimado,
                'dias', greatest((v_hoy - (o.fecha_inicio at time zone 'America/Bogota')::date), 0),
                -- el costo es información administrativa: no va al despachador
                'costo', case when v_admin then o.costo_total end)
              order by o.afecta_disponib desc, o.fecha_inicio), '[]'::jsonb)
              from public.taller_ordenes o
             where o.estado = 'opened' and not o.fuera_listado),
    'operacion', (public.taller_en_operacion(v_hoy) -> 'filas'),
    'represadas', (select case when not v_admin then '[]'::jsonb else coalesce(jsonb_agg(jsonb_build_object(
                'numero', o.numero, 'movil', o.movil, 'tipo', o.tipo,
                'cierre_tecnico', o.cierre_tecnico_en,
                'dias', greatest((v_hoy - (o.cierre_tecnico_en at time zone 'America/Bogota')::date), 0))
              order by o.cierre_tecnico_en), '[]'::jsonb) end
              from public.taller_ordenes o
             where o.estado = 'onTechnicalCompletion' and not o.fuera_listado
               and o.cierre_tecnico_en < (v_hoy - 7)::timestamptz),
    'novedades', (select coalesce(jsonb_agg(jsonb_build_object(
                'numero', n.numero, 'movil', n.movil, 'prioridad', n.prioridad,
                'texto', left(coalesce(n.observacion, ''), 200), 'reporto', n.reportada_por,
                'desde_checklist', n.desde_checklist, 'cuando', n.reportada_en,
                'dias', greatest((v_hoy - (n.reportada_en at time zone 'America/Bogota')::date), 0))
              order by case n.prioridad when 'high' then 0 when 'medium' then 1 else 2 end, n.reportada_en),
              '[]'::jsonb)
              from public.taller_novedades n where not n.resuelta),
    'prog', (select jsonb_build_object(
                'vencidas',   count(*) filter (where estado = 'Vencido'),
                'hoy',        count(*) filter (where estado = 'Vence hoy'),
                'proximas',   count(*) filter (where estado = 'Próximo'),
                'moviles',    count(distinct movil) filter (where estado in ('Vencido', 'Vence hoy')))
              from public.taller_programacion),
    'prog_lista', (select coalesce(jsonb_agg(jsonb_build_object(
                'movil', p.movil, 'trabajo', coalesce(p.trabajo, p.rutina), 'estado', p.estado,
                'fecha', p.fecha_ejecutar, 'dias', p.dias_dif, 'orden', p.orden_creada)
              order by p.fecha_ejecutar), '[]'::jsonb)
              from public.taller_programacion p
             where p.estado in ('Vencido', 'Vence hoy')));
end $fn$;
revoke all on function public.taller_tablero() from public, anon;
grant execute on function public.taller_tablero() to authenticated;

-- ---------- 4) El numerito del menú ----------
-- El despachador no lee taller_ordenes directamente (la tabla lleva costos y datos
-- administrativos que no le corresponden), así que el contador viene por aquí: devuelve
-- un número y nada más.
create or replace function public.taller_fuera_n()
returns int
language sql stable security definer set search_path = public as $fn$
  select case when ( (select public.es_admin()) or (select public.es_operaciones())
                  or (select public.es_auditor()) or (select public.es_despachador()) )
    then (select count(*)::int from public.taller_ordenes
           where estado = 'opened' and not fuera_listado and afecta_disponib)
    else 0 end;
$fn$;
revoke all on function public.taller_fuera_n() from public, anon;
grant execute on function public.taller_fuera_n() to authenticated;

-- ===================================================================================
-- Después de ejecutar, para ver la programación ya corregida:
--   select public.taller_sync_programacion();   -- debe devolver filas > 0
--   select public.taller_tablero() -> 'prog';
--   select public.taller_en_operacion();        -- buses fuera de servicio que se despacharon hoy
-- ===================================================================================
