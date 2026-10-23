-- 132_preop_panel.sql  (LOCAL, sin publicar)
-- "debe de tener un panel de control, para que se sepa diario que vehiculos la realizaron, el
--  conductor, y quienes faltan" + "generar una alerta de que se tiene una incidencia en un
--  vehiculo" (22/10/2026).
--
-- QUIENES "DEBIAN" HACERLA: los vehiculos que REALMENTE salieron ese dia, es decir los que
-- tienen al menos un despacho en la fecha (hoy: 150 vehiculos distintos). Medir contra los 315
-- activos del parque daria decenas de "faltantes" falsos: hay carros en mantenimiento o sin
-- programacion que no salieron. Se comprobo que los 150 despachados cruzan 150/150 con el
-- parque por numero interno y por placa, asi que la union por numero es segura.
-- (De paso: 4 de los 150 que salieron hoy NO figuran como 'Activo' en el parque. Eso es otro
--  tema, pero por eso el panel no filtra por estado: muestra lo que de verdad salio.)
--
-- Todo se calcula en el servidor y vuelve en un solo JSON: el panel no debe traerse miles de
-- filas de despachos al celular.
--
-- NOTA: las comprobaciones de este archivo son de SOLO LECTURA a proposito. Un `rollback` de
-- pruebas aqui revertiria tambien el `create function` (ver sql/131).

create or replace function public.preop_panel(p_fecha date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
stable
as $function$
declare
  v_f date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
  v_out jsonb;
begin
  -- Pantalla de administracion: solo el admin (igual que la tabla, sql/127)
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador ve este panel.');
  end if;

  with sal as ( -- los vehiculos que REALMENTE salieron ese dia, con su conductor
    select btrim(v.numero) as movil,
           max(btrim(coalesce(v.placa, ''))) as placa,
           (array_agg(c.nombre order by c.nombre))[1] as conductor,
           count(*)::int as viajes
      from public.despachos d
      join public.vehiculos v on v.id = d.vehiculo_id
      left join public.conductores c on c.id = d.conductor_id
     where d.fecha = v_f and btrim(coalesce(v.numero, '')) <> ''
     group by btrim(v.numero)
  ),
  hec as ( select * from public.preoperacionales where fecha = v_f )
  select jsonb_build_object(
    'ok', true,
    'fecha', v_f,
    'resumen', jsonb_build_object(
      'salieron',         (select count(*) from sal),
      'hechas',           (select count(*) from hec),
      'faltan',           (select count(*) from sal s
                            where not exists (select 1 from hec h where h.movil = s.movil)),
      'con_novedad',      (select count(*) from hec where novedades > 0),
      'pendientes_atras', (select count(*) from public.preoperacionales
                            where estado = 'PENDIENTE' and fecha < v_f)),

    -- Las que SI se hicieron
    'hechas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', h.id, 'movil', h.movil, 'placa', h.placa, 'conductor', h.nombre,
                 'hora', to_char(h.creado_en at time zone 'America/Bogota', 'HH24:MI'),
                 'estado', h.estado, 'novedades', h.novedades, 'lat', h.lat, 'lon', h.lon,
                 'salio', exists (select 1 from sal s where s.movil = h.movil)
               ) order by h.creado_en), '[]'::jsonb) from hec h),

    -- Los que salieron y NO la hicieron
    'faltan', (select coalesce(jsonb_agg(jsonb_build_object(
                 'movil', s.movil, 'placa', s.placa, 'conductor', s.conductor, 'viajes', s.viajes
               ) order by lpad(s.movil, 6, '0')), '[]'::jsonb)
                 from sal s
                where not exists (select 1 from hec h where h.movil = s.movil)),

    -- Las incidencias del dia: que punto salio mal y que dijo el conductor
    'incidencias', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', h.id, 'movil', h.movil, 'placa', h.placa, 'conductor', h.nombre,
                      'estado', h.estado, 'novedades', h.novedades,
                      'puntos', (select jsonb_agg(jsonb_build_object(
                                          'pregunta', i.pregunta, 'comentario', i.comentario)
                                        order by i.orden)
                                   from public.preoperacional_items i
                                  where i.preop_id = h.id and i.respuesta = 'MAL')
                    ) order by h.creado_en), '[]'::jsonb)
                      from hec h where h.novedades > 0)
  ) into v_out;

  return v_out;
end $function$;

revoke all on function public.preop_panel(date) from public, anon;
grant execute on function public.preop_panel(date) to authenticated;

-- Comprobacion (solo lectura). Como la API corre como postgres, es_admin() es falso: lo que se
-- verifica aqui es que la funcion existe y responde; el contenido se prueba desde la app.
select 'funcion creada' as dato, p.oid::regprocedure::text as valor
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'preop_panel'
union all
select 'respuesta sin ser admin', (public.preop_panel())::text
union all
select 'vehiculos que salieron hoy',
       (select count(distinct d.vehiculo_id)::text from public.despachos d
         where d.fecha = (now() at time zone 'America/Bogota')::date);
