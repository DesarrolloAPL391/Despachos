-- 125_pasajeros_monitores.sql  (v319)
-- Los MONITORES (rol auditor / control) entran al modulo "Pasajeros".
--
-- Hoy el gate de las dos funciones que alimentan la pantalla deja por fuera al auditor:
--   pasajeros_movil : es_admin() or es_operaciones() or (es_afiliado() and movil suyo)
--   viajes_movil    : es_admin()                     or (es_afiliado() and movil suyo)
-- Se le suma el auditor a ambas, con alcance de TODA la flota (no solo sus rutas), que es
-- el mismo criterio de sonar_eventos_auditor y de las tablas de puesto (sql/42): el monitor
-- controla la operacion completa.
--
-- De paso se agrega es_operaciones() a viajes_movil: la app ya les muestra el modulo, pero
-- esa funcion los rechazaba y la seccion "Viajes del dia" les quedaba vacia sin explicacion.
--
-- El cuerpo NO se reescribe a mano: se pide con pg_get_functiondef y se cambia SOLO la linea
-- del permiso. Asi no hay riesgo de alterar sin querer el resto (llamadas SOAP a SONAR,
-- manejo de temporales, calculo de paradas). Si el texto buscado no aparece, el bloque
-- FALLA en vez de dejar la funcion a medias.

do $do$
declare d text; nuevo text;
begin
  d := pg_get_functiondef('public.pasajeros_movil(text,date)'::regprocedure);
  nuevo := replace(d,
    'if not (public.es_admin() or public.es_operaciones() or (public.es_afiliado()',
    'if not (public.es_admin() or public.es_operaciones() or public.es_auditor() or (public.es_afiliado()');
  if nuevo = d then raise exception 'pasajeros_movil: no se encontro la linea del permiso; revisar antes de aplicar'; end if;
  execute nuevo;
end $do$;

do $do$
declare d text; nuevo text;
begin
  d := pg_get_functiondef('public.viajes_movil(text,date)'::regprocedure);
  nuevo := replace(d,
    'if not (public.es_admin() or (public.es_afiliado()',
    'if not (public.es_admin() or public.es_operaciones() or public.es_auditor() or (public.es_afiliado()');
  if nuevo = d then raise exception 'viajes_movil: no se encontro la linea del permiso; revisar antes de aplicar'; end if;
  execute nuevo;
end $do$;

-- Las dos estaban concedidas a PUBLIC y a anon (se ve en proacl: '=X' y 'anon=X'), que es
-- como quedo abierto el recorrido GPS en sql/123: cualquiera con la URL del proyecto podia
-- llamarlas sin cuenta. Se cierran. PostgreSQL vuelve a dar EXECUTE a PUBLIC cada vez que
-- se recrea una funcion, asi que este revoke va DESPUES del create, no antes.
revoke all on function public.pasajeros_movil(text, date) from public, anon;
revoke all on function public.viajes_movil(text, date)    from public, anon;
grant execute on function public.pasajeros_movil(text, date) to authenticated;
grant execute on function public.viajes_movil(text, date)    to authenticated;

-- Comprobacion: ambas deben contemplar al auditor y NO tener ya permisos de anon/PUBLIC
select p.proname,
       (pg_get_functiondef(p.oid) ilike '%es_auditor%') as contempla_auditor,
       array_to_string(p.proacl, ' | ') as permisos
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('pasajeros_movil', 'viajes_movil')
 order by 1;
