-- ============================================================================
-- 28_optimizar_crons.sql  (optimización de carga de fondo)
-- Los dos refrescos pesados de SONAR (traen toda la flota, ~18 s cada uno) corrían
-- cada 1 y 2 min y se solapaban cada minuto par. Se reparten para que NUNCA corran
-- a la vez y se baja el de móviles a cada 2 min: alivia ~40-45% de la carga de fondo.
--   - refrescar-moviles-operacion (Rutas en vivo): 1 min → cada 2 min, minutos PARES
--   - refrescar-recorrido-vivo (progreso/línea):   cada 2 min, minutos IMPARES (desfasado)
-- Así cada minuto corre a lo sumo UN proceso pesado. Las vistas siguen "casi en vivo"
-- (muestran "actualizado hace Xs" y avisan si se pasa de 3 min).
-- ============================================================================

select cron.alter_job(jobid, schedule => '*/2 * * * *')
  from cron.job where jobname = 'refrescar-moviles-operacion';

select cron.alter_job(jobid, schedule => '1-59/2 * * * *')
  from cron.job where jobname = 'refrescar-recorrido-vivo';
