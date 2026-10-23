-- ATENCION (22/10/2026): este archivo NUNCA llego a quedar aplicado. Terminaba en un
-- bloque de pruebas con `begin; ... rollback;` y la Management API corre TODO el archivo
-- dentro de una sola transaccion, de modo que ese rollback revirtio tambien el cambio de
-- arriba... devolviendo una respuesta de exito. El cambio quedo incorporado en
-- sql/131_preop_ubicacion.sql, que rehace la funcion completa. NO correr este archivo
-- despues del 131: fallaria, porque busca un texto que ya no existe.

-- 130_preop_sin_firma.sql  (LOCAL, sin publicar)
-- "firma no y debe de salir el boton de la foto, eso es importante y no se pueden subir
--  fotos desde el celular, super importante" (22/10/2026).
--
--   * Se quita la firma: ya no se pide ni se exige. La columna `firma` se conserva porque la
--     inspeccion de prueba la tiene; simplemente queda vacia de aqui en adelante.
--   * La FOTO sigue siendo obligatoria y ahora se toma con la camara DENTRO de la pagina
--     (no hay selector de archivos), de modo que no se puede subir una imagen vieja de la
--     galeria. Eso se resuelve en webapp/preoperacional.html; aqui solo queda la exigencia.
--
-- Se cambia SOLO el bloque de la firma dentro de preop_guardar.

do $$
declare
  v_def   text := pg_get_functiondef('public.preop_guardar(text, text, numeric, jsonb, text, text)'::regprocedure);
  v_vieja text := $v$  if v_firma is null then
    return jsonb_build_object('ok', false, 'error', 'Falta tu firma.');
  end if;$v$;
  v_nueva text := $n$  -- Sin firma (22/10/2026): la constancia es la foto del conductor en el bus.$n$;
begin
  if position(v_vieja in v_def) = 0 then
    raise exception 'No encontre la validacion de la firma en preop_guardar; revisar a mano.';
  end if;
  execute replace(v_def, v_vieja, v_nueva);
end $$;

revoke all on function public.preop_guardar(text, text, numeric, jsonb, text, text) from public;
grant execute on function public.preop_guardar(text, text, numeric, jsonb, text, text) to anon, authenticated;

comment on column public.preoperacionales.firma is
  'Sin uso desde el 22/10/2026: se quito la firma. Se conserva por las inspecciones anteriores.';

-- Comprobacion: sin firma pasa, sin foto sigue sin pasar
begin;
with c as (
  select regexp_replace(cedula, '\D', '', 'g') as ced
    from public.perfilsociodemografico
   where cargo = 'CONDUCTOR' and estado = 'ACTIVO' order by cedula limit 1
),
i as (
  select jsonb_agg(jsonb_build_object('orden', orden, 'respuesta', 'BIEN') order by orden) j
    from public.preoperacional_preguntas where activa
)
select 'sin firma y con foto' as prueba,
       public.preop_guardar((select ced from c), '5002', null, (select j from i), null, 'SELFIE')::text as resultado
union all
select 'sin firma y sin foto',
       public.preop_guardar((select ced from c), '5003', null, (select j from i), null, null)::text;
rollback;
