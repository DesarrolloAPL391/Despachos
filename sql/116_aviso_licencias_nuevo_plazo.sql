-- ===================================================================================
-- 116: EL PLAZO DE LAS LICENCIAS SE MOVIÓ — hay que volver a avisar.
-- ===================================================================================
-- El 22/09 se les dijo a despachadores y auditores, por modal de obligatoria respuesta,
-- que el plazo era el sábado 26 de septiembre. Ese mismo día se midió: 31 conductores
-- activos con la licencia vencida. Renovar una licencia es un trámite de tránsito que no
-- se hace en cuatro días, así que el plazo se corrió al sábado 10 de octubre (el bloqueo
-- se enciende solo el domingo 11, ver licencia_bloqueo_config).
--
-- POR QUÉ UN AVISO NUEVO Y NO EDITAR EL ANTERIOR:
--   Los acuses se guardan por aviso. Si solo le cambio el texto al de septiembre, a quien
--   ya lo confirmó no le vuelve a salir: se quedaría con el sábado 26 en la cabeza y
--   nosotros creyendo que está informado. Con un código nuevo lo ven todos otra vez, y el
--   acuse del primero queda intacto como constancia de lo que se dijo la primera vez.
--
-- Y el de septiembre se apaga, para que no queden dos avisos con fechas distintas.
-- ===================================================================================

update public.avisos set activo = false where codigo = 'LICENCIAS-2026-09';

insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta)
values (
  'LICENCIAS-2026-10',
  '🪪',
  'Licencias: el plazo cambió al sábado 10 de octubre',
  'El plazo que se les dio la semana pasada era el sábado 26 de septiembre. Se movió al '
  || 'sábado 10 de octubre, y esta es la razón: hay 31 conductores activos con la licencia '
  || 'vencida, y renovarla es un trámite de tránsito que no se hace en cuatro días.'
  || E'\n\n'
  || 'El plazo se corrió una vez. No se vuelve a correr: desde el domingo 11 de octubre el '
  || 'sistema no dejará despachar a un conductor con la licencia vencida.'
  || E'\n\n'
  || 'Lo que hay que hacer no es esperar a octubre. Es hoy: al conductor que ya renovó, '
  || 'súbele las dos fotos ahora; al que no ha ido al tránsito, dile hoy que vaya.',
  jsonb_build_array(
    'El plazo era el sábado 26 de septiembre. Ahora es el SÁBADO 10 DE OCTUBRE.',
    'Desde el DOMINGO 11 no se podrá despachar a quien no la haya presentado.',
    'Al conductor que YA renovó: súbele las dos fotos hoy mismo. Eso lo saca de la lista de una vez.',
    'Al que no ha ido: dile hoy que vaya. Renovar toma días, no horas — por eso se corrió el plazo.',
    'Son dos fotos: frente y respaldo. La fecha de vencimiento está en el respaldo.'
  ),
  'Entiendo que el nuevo plazo es el sábado 10 de octubre y que desde el domingo 11 no podré despachar a un conductor con la licencia vencida.',
  'Entendido, me comprometo',
  array['despachador', 'auditor'],
  (now() at time zone 'America/Bogota')::date,
  date '2026-11-15'
)
on conflict (codigo) do update
  set titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      hasta = excluded.hasta, activo = true;

-- Quién lo ha leído y quién falta:
--   select public.aviso_control((select id from public.avisos where codigo = 'LICENCIAS-2026-10'));
