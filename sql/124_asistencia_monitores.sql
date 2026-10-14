-- 124_asistencia_monitores.sql  (v318)
-- Los MONITORES (rol auditor / control) entran al modulo "Inicio y fin de labores":
--   1) marcan su propia jornada, igual que un despachador (eso ya lo permitian las
--      politicas de INSERT/UPDATE, que van por el correo propio), y
--   2) VEN las marcaciones de todos para controlar la puntualidad del ingreso.
--
-- Antes: asistencia_sel = es_admin() OR correo propio  -> el monitor solo veia lo suyo
-- Ahora: se suma es_auditor(), que ya ve completas las tablas de puesto (sql/42).
--
-- Las funciones van envueltas en (select ...) para que el planeador las evalue UNA vez
-- y no una por fila: sin eso la consulta se arrastra cuando crece el historico
-- (ver sql/56, mismo problema en Resumen).
--
-- Lo que NO se toca a proposito:
--   - INSERT/UPDATE siguen limitados al correo propio (o admin): un monitor puede ver
--     la jornada de un despachador, pero no marcarsela ni corregirsela.
--   - DELETE sigue siendo solo del admin.

drop policy if exists asistencia_sel on public.asistencia;
create policy asistencia_sel on public.asistencia
  for select
  using (
    (select public.es_admin())
    or (select public.es_auditor())
    or lower(email) = lower(auth.email())
  );

-- Comprobacion: deben quedar las 6 politicas, con asistencia_sel incluyendo es_auditor
select policyname, cmd, qual
  from pg_policies
 where schemaname = 'public' and tablename = 'asistencia'
 order by policyname;
