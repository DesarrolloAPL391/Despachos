-- ===================================================================================
-- 121: EL TABLERO DE RUTAS EN VIVO SE REFRESCABA MÁS SEGUIDO DE LO QUE PODÍA
-- ===================================================================================
-- EL DATO QUE LO DESTAPÓ (pg_stat_statements, 07/10/2026):
--
--     refrescar_moviles_operacion_core   16,5 s por corrida   59.566 corridas
--                                        982.582 s = 273 HORAS de servidor
--
-- El cron de sql/18 la dispara CADA MINUTO, las 24 horas. Pero la consulta tarda
-- 16,5 segundos. Dos consecuencias:
--
--   1) El tablero nunca pudo estar más fresco que esos 16,5 segundos, por mucho que el
--      cron corriera cada minuto. Se estaba pagando una frecuencia que el dato no tenía.
--   2) Corriendo cada minuto, esta sola función tuvo ocupado cerca de un cuarto de un
--      núcleo de forma permanente. Eso es parte de por qué el servidor estaba apretado
--      cuando el control en vía se pasó de tiempo el 28/09 (ver sql/119).
--
-- Y corría también de medianoche en adelante, cuando no hay un solo bus rodando.
--
-- QUÉ CAMBIA: pasa a cada 2 minutos y solo en la franja en que hay operación.
-- De 1.440 corridas diarias a 630: un 56% menos de carga, unas 3,7 horas de servidor
-- menos por día. El tablero pasa a tener como mucho 2 minutos de atraso, que es el mismo
-- intervalo con el que ya funciona el control en vía desde sql/119.
--
-- NO SE TOCA LA FUNCIÓN, solo cada cuándo se la llama. Si más adelante se quiere el dato
-- más fresco, el camino no es subir la frecuencia otra vez sino averiguar por qué la
-- consulta tarda 16,5 segundos.
--
-- OJO CON LA HORA: pg_cron programa en UTC y Colombia es UTC-5. La franja se escribe
-- corrida. `0-4,8-23` en UTC son las 3:00 a.m. – 11:59 p.m. de Colombia. Se arranca a
-- las 3 y no a las 4 a propósito, para que las rutas de MADRUGADA ya tengan el tablero
-- caliente cuando salgan. Escribir '4-23' creyendo que es hora de Colombia fue el error
-- que hubo que corregir en sql/119; aquí ya va en UTC.
--
-- APLICADO el 07/10/2026 08:31 (Colombia). La semilla devolvió {"ok":true,"moviles":338}.
-- ===================================================================================

select cron.unschedule('refrescar-moviles-operacion')
 where exists (select 1 from cron.job where jobname = 'refrescar-moviles-operacion');

select cron.schedule('refrescar-moviles-operacion', '*/2 0-4,8-23 * * *',
                     'select public.refrescar_moviles_operacion_core();');

-- Que no quede el tablero viejo esperando al próximo minuto par.
select public.refrescar_moviles_operacion_core();

-- ===================================================================================
-- PARA VERIFICAR:
--   select jobname, schedule, active from cron.job
--    where jobname like 'refrescar%' order by jobname;
--
-- PARA MEDIR EL AHORRO DENTRO DE UNOS DÍAS (comparar contra las 273 horas de hoy):
--   select calls, round((total_exec_time/1000/3600)::numeric, 1) as horas_servidor,
--          round(mean_exec_time::numeric, 0) as ms_por_llamada
--     from extensions.pg_stat_statements
--    where query ilike '%refrescar_moviles_operacion_core%';
--
-- LO QUE QUEDA PENDIENTE DE MIRAR, por si se quiere seguir bajando la carga:
--   · refrescar_recorrido_vivo_core (sql/20 y sql/21): 16,0 s por corrida, 243 horas
--     acumuladas. Es el segundo más pesado y tiene el mismo perfil que este. Además
--     registró 54.843 llamadas, bastantes más de las que explica un cron cada 2 minutos:
--     vale la pena revisar si se está llamando más de una vez por corrida.
--   · sync_ubicaciones: 1,4 s por llamada pero 151.870 llamadas (58 horas).
-- ===================================================================================
