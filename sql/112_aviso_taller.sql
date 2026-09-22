-- ===================================================================================
-- 112: AVISO DE OBLIGATORIA RESPUESTA A LOS AUDITORES — ya ven el taller (sql/109+111).
-- ===================================================================================
-- Un módulo nuevo que nadie sabe que existe no sirve de nada. Este aviso les explica a
-- los auditores qué están viendo, qué significa cada cosa y qué se espera de ellos, y
-- queda registrado quién lo leyó (aviso_acuses) para poder llamar a quien falte.
--
-- Lo más importante que tiene que quedar claro es que ESTO NO BLOQUEA. Si alguien cree
-- que la app ya no deja despachar un bus en taller, va a dejar de revisar y de reportar.
-- Lo que se les pide es justamente lo contrario: que miren y que reporten.
--
-- Va solo a los auditores porque es a quienes se decidió informar. Para sumar a los
-- despachadores basta con agregar 'despachador' al array de roles y volver a ejecutarlo:
-- el `on conflict (codigo)` actualiza el aviso sin duplicarlo ni borrar los acuses ya
-- registrados de quienes ya lo confirmaron.
-- ===================================================================================

insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta)
values (
  'TALLER-2026-09',
  '🛠️',
  'Ahora ves el taller dentro de la app',
  'Desde hoy la aplicación te muestra lo que está pasando en el taller con cada bus: las '
  || 'órdenes de trabajo abiertas, las fallas reportadas que siguen sin resolver y el '
  || 'mantenimiento programado. Se trae del sistema del taller y se actualiza cada 15 minutos.'
  || E'\n\n'
  || 'Lo encuentras en el menú, en 🛠️ Taller y mantenimiento. El número rojo al lado son los '
  || 'buses que el taller tiene hoy fuera de servicio.'
  || E'\n\n'
  || 'Y cuando abras una intervención, si ese bus está en el taller te lo dice ahí mismo: '
  || 'aprovéchalo estando allá en vez de citarlo aparte otro día.',
  jsonb_build_array(
    'FUERA DE SERVICIO significa que el taller dice que ese bus no debería estar rodando. Ese es el dato que importa.',
    'ORDEN ABIERTA sin más quiere decir que está en el taller, pero puede seguir operando.',
    'La app NO bloquea el despacho por esto. Te informa; la decisión sigue siendo de operaciones.',
    'Si ves una falla en un carro, repórtala con el botón "Reportarle al taller": le llega a la misma bandeja donde el taller recibe las del conductor, y queda con tu nombre.',
    'El dato puede tener hasta 15 minutos. Si algo se acabó de cerrar en el taller, usa "Traer del taller".'
  ),
  'Entiendo qué me está mostrando la app del taller, que no bloquea el despacho, y cómo reportar una falla.',
  'Entendido',
  array['auditor'],
  (now() at time zone 'America/Bogota')::date,
  date '2026-10-31'
)
on conflict (codigo) do update
  set titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      hasta = excluded.hasta, activo = true;

-- Quién lo ha leído y quién falta: ⚙️ Administración > 📢 Avisos al personal, o aquí:
--   select public.aviso_control((select id from public.avisos where codigo = 'TALLER-2026-09'));
