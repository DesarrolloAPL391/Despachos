-- ATENCION (22/10/2026): este archivo NUNCA llego a quedar aplicado. Terminaba en un
-- bloque de pruebas con `begin; ... rollback;` y la Management API corre TODO el archivo
-- dentro de una sola transaccion, de modo que ese rollback revirtio tambien el cambio de
-- arriba... devolviendo una respuesta de exito. El cambio quedo incorporado en
-- sql/131_preop_ubicacion.sql, que rehace la funcion completa. NO correr este archivo
-- despues del 131: fallaria, porque busca un texto que ya no existe.

-- 129_preop_sin_no_aplica.sql  (LOCAL, sin publicar)
-- "quitar ese que dice que no aplica para este bus, el conductor no se nos puede saltar
--  esta parte" (22/10/2026). Cada punto se responde BIEN o MAL, sin salida intermedia.
--
-- Se cambia SOLO la linea de validacion dentro de preop_guardar (no se reescribe la funcion,
-- para no arrastrar por error una version vieja del resto del cuerpo).
--
-- El CHECK de preoperacional_items se deja como esta (permite 'NO APLICA'): las inspecciones
-- ya guardadas con esa respuesta siguen siendo validas y legibles en la ficha del admin.
-- La puerta de entrada es la que cierra: por la RPC ya no entra.

do $$
declare
  v_def  text := pg_get_functiondef('public.preop_guardar(text, text, numeric, jsonb, text, text)'::regprocedure);
  v_vieja text := $v$    if v_resp not in ('BIEN', 'MAL', 'NO APLICA') then
      return jsonb_build_object('ok', false, 'error', 'Respuesta inválida.');
    end if;$v$;
  v_nueva text := $n$    if v_resp not in ('BIEN', 'MAL') then
      return jsonb_build_object('ok', false, 'error', 'Cada punto se responde Bien o Mal.');
    end if;$n$;
begin
  if position(v_vieja in v_def) = 0 then
    raise exception 'No encontre la validacion de respuestas en preop_guardar; revisar a mano.';
  end if;
  execute replace(v_def, v_vieja, v_nueva);
end $$;

-- Los grants se conservan al hacer CREATE OR REPLACE, pero se reafirman por claridad.
revoke all on function public.preop_guardar(text, text, numeric, jsonb, text, text) from public;
grant execute on function public.preop_guardar(text, text, numeric, jsonb, text, text) to anon, authenticated;

-- Comprobacion: la funcion ya no admite 'NO APLICA' y sigue admitiendo BIEN/MAL
begin;
with c as (
  select regexp_replace(cedula, '\D', '', 'g') as ced
    from public.perfilsociodemografico
   where cargo = 'CONDUCTOR' and estado = 'ACTIVO' order by cedula limit 1
),
con_na as (
  select jsonb_agg(jsonb_build_object('orden', orden,
           'respuesta', case when orden = 1 then 'NO APLICA' else 'BIEN' end) order by orden) j
    from public.preoperacional_preguntas where activa
),
todo_bien as (
  select jsonb_agg(jsonb_build_object('orden', orden, 'respuesta', 'BIEN') order by orden) j
    from public.preoperacional_preguntas where activa
)
select 'con un NO APLICA' as prueba,
       public.preop_guardar((select ced from c), '5002', null, (select j from con_na),
                            'FIRMA', 'SELFIE')::text as resultado
union all
select 'todo BIEN',
       public.preop_guardar((select ced from c), '5002', null, (select j from todo_bien),
                            'FIRMA', 'SELFIE')::text;
rollback;
