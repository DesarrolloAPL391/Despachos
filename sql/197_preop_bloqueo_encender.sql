-- 197: ENCIENDE el bloqueo del despacho por preoperacional (sql/196) y avisa a los despachadores.
-- Decision del usuario el 18/11/2026: bloquear "apenas se publique" la v372, con aviso de
-- obligatoria respuesta (sql/109) al rol despachador. Se corre DESPUES de que GitHub Pages publique.
--
-- Para apagarlo sin publicar: select public.preop_bloqueo_config_guardar(p_activo => false);
-- Reejecutar el aviso no lo duplica ni borra los acuses (on conflict por codigo).

select public.preop_bloqueo_config_guardar(
  p_activo => true,
  p_desde  => now(),
  p_nota   => '18/11/2026: encendido apenas se publico la v372, a pedido del usuario.');

insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'PREOP-DESPACHO-2026-11',
  '🧰',
  'Ningún bus sale sin su preoperacional del día',
  'Desde hoy la app NO deja despachar un bus que no tenga la inspección preoperacional de hoy '
  || '(Resolución 315 de 2013: alistamiento diario del vehículo).'
  || chr(10) || chr(10)
  || 'Es por bus: si cualquier conductor ya se la hizo hoy a ese bus, el bus sale. '
  || 'Vale en Nuevo despacho y en todas las tablas.'
  || chr(10) || chr(10)
  || 'Al elegir el bus van a ver:',
  jsonb_build_array(
    '🚫 Caja roja DESPACHO BLOQUEADO: el bus no tiene preoperacional de hoy. No se puede despachar.',
    '💬 Desde la misma caja le envían el enlace al conductor por WhatsApp. Él entra con su cédula.',
    '🔄 Cuando el conductor la envíe, toquen "Ya la hizo, revisar otra vez" y se desbloquea.',
    '✅ Línea verde: el bus ya la tiene.',
    '🧰 Si sale en naranja con puntos en mal estado, se puede despachar, pero avísenle a taller.'
  ),
  'Entendí que ningún bus se despacha sin su preoperacional del día.',
  'Entendido',
  array['despachador'],
  date '2026-11-18',
  date '2026-12-02',
  'sql/197'
)
on conflict (codigo) do update
  set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      desde = excluded.desde, hasta = excluded.hasta, activo = true;
