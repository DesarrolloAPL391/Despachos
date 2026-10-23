-- 128_preoperacional_res315.sql  (LOCAL, sin publicar)
-- Ajustes pedidos el 22/10/2026 sobre sql/127:
--   1) Elegir el bus por LISTA o leyendo el QR del sticker (ademas de escribir el numero).
--   2) La foto deja de ser del bus: es una SELFIE del conductor dentro del carro, OBLIGATORIA.
--   3) El kilometraje NO es obligatorio. Responder las 14 preguntas SI lo es.
--   4) Las preguntas se alinean con la Resolucion 315 de 2013 del Ministerio de Transporte.
--
-- RESOLUCION 315 DE 2013, ARTICULO 4 (protocolo de alistamiento). Exige verificar como minimo:
--   * Motor y mecanica: fugas del motor, tension de correas, tapas, niveles de aceite de motor,
--     transmision, direccion, frenos, nivel de agua del limpiabrisas, aditivos de radiador y
--     filtros humedos y secos.
--   * Baterias: niveles de electrolito, ajuste de bornes y sulfatacion.
--   * Llantas: desgaste y presion de aire.
--   * Equipo de carretera y botiquin.
-- A las 12 preguntas del formato de AppSheet les faltaban: fugas/correas/tapas del motor, la
-- bateria, la presion de las llantas, el agua del limpiabrisas y los aditivos del radiador.
-- Quedan 14 preguntas: se conservan las 12 originales (con el texto ampliado donde la norma
-- pide mas) y se agregan 2 nuevas.
--
-- ADVERTENCIA que queda para decision de la empresa (NO se resuelve con este archivo):
-- el paragrafo del articulo 4 dice que el alistamiento lo hace la empresa "con personal
-- diferente de sus conductores pero con la participacion del conductor", y que debe quedar
-- constancia de las personas que participaron. Este formulario deja la constancia del
-- conductor; si se quiere cumplir el paragrafo completo hay que registrar tambien quien de la
-- empresa acompano el alistamiento.

-- ---------------------------------------------------------------------------
-- 1) La foto ahora es la selfie del conductor dentro del bus
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'preoperacionales'
                and column_name = 'foto_vehiculo')
     and not exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'preoperacionales'
                and column_name = 'selfie') then
    alter table public.preoperacionales rename column foto_vehiculo to selfie;
  end if;
end $$;
comment on column public.preoperacionales.selfie is
  'Selfie del conductor DENTRO del bus (obligatoria). base64 JPEG reducido en el navegador.';

-- ---------------------------------------------------------------------------
-- 2) Las 14 preguntas (Res. 315/2013 art. 4 + el formato de AppSheet)
--    preoperacional_items guarda el TEXTO de la pregunta, no una llave: recargar el
--    catalogo no toca las inspecciones ya hechas.
-- ---------------------------------------------------------------------------
delete from public.preoperacional_preguntas;

insert into public.preoperacional_preguntas (orden, corto, texto, icono, grupo) values
  (1,  'Frenos',               'Frenos (carga de aire, tensión de parqueo y altura del pedal)', '🛑', 'Mecánica'),
  (2,  'Dirección',            'Dirección (sin juego y alineada)', '🎯', 'Mecánica'),
  (3,  'Suspensión',           'Suspensión (estado de muelles en general)', '🔩', 'Mecánica'),
  (4,  'Llantas y rines',      'Llantas (labrado y presión de aire) y rines (sin fisuras)', '🛞', 'Mecánica'),
  (5,  'Motor: fugas y correas','Motor sin fugas, correas bien tensionadas y tapas en su sitio', '🔧', 'Mecánica'),
  (6,  'Niveles',              'Niveles por encima del mínimo: aceite de motor, transmisión, refrigerante y aditivos del radiador, y agua del limpiabrisas', '🛢️', 'Mecánica'),
  (7,  'Batería',              'Batería: bornes ajustados, sin sulfatación y con nivel de electrolito', '🔋', 'Mecánica'),
  (8,  'Sistema eléctrico',    'Sistema eléctrico funcional (todas las luces, pito, alarma de reversa, tablero sin alarmas críticas)', '💡', 'Luces y visibilidad'),
  (9,  'Espejos y parabrisas', 'Espejos, parabrisas (sin fisuras y/o rayones) y limpiaparabrisas (funcionalidad)', '🪞', 'Luces y visibilidad'),
  (10, 'Cinturón y asiento',   'Cinturón y asiento del conductor (anclados y funcionalidad sin bloqueos)', '🪑', 'Cabina y pasajeros'),
  (11, 'Puertas',              'Puertas (apertura y cierre)', '🚪', 'Cabina y pasajeros'),
  (12, 'Salidas de emergencia','Salidas de emergencia (señalizadas y elementos de quiebre)', '🚨', 'Cabina y pasajeros'),
  (13, 'Pasamanos',            'Pasamanos (ajustados)', '🫱', 'Cabina y pasajeros'),
  (14, 'Equipo y botiquín',    'Equipo de carretera y botiquín vigentes (extintor, botiquín, conos, tacos, caja de herramienta, linterna, cruceta, llanta de repuesto)', '🧰', 'Equipo');

-- ---------------------------------------------------------------------------
-- 3) Puerta publica 4: la lista de buses, para elegirlo sin escribirlo y para
--    emparejar lo que traiga el QR del sticker.
--    Devuelve SOLO numero interno y placa de los buses activos: datos de la flota que ya
--    van pintados en el costado del carro, ningun dato de personas.
-- ---------------------------------------------------------------------------
create or replace function public.preop_buses()
returns jsonb
language sql
security definer
set search_path to 'public'
stable
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('movil', m, 'placa', p) order by lpad(m, 6, '0')), '[]'::jsonb)
    from (select btrim(numero_interno) as m, btrim(coalesce(placa, '')) as p
            from public.parque_automotor
           where estado = 'Activo' and btrim(coalesce(numero_interno, '')) <> '') t;
$function$;

-- ---------------------------------------------------------------------------
-- 4) Guardar: selfie OBLIGATORIA, kilometraje opcional, todas las preguntas obligatorias
-- ---------------------------------------------------------------------------
create or replace function public.preop_guardar(
  p_cedula text,
  p_movil  text,
  p_kms    numeric,
  p_items  jsonb,              -- [{orden, respuesta, comentario}]
  p_firma  text default null,
  p_foto   text default null   -- selfie del conductor dentro del bus (obligatoria)
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nombre text; v_placa text; v_mov text := btrim(coalesce(p_movil, ''));
  v_id bigint; v_mal int := 0; v_total int; it jsonb; v_resp text; v_com text;
  v_selfie text := nullif(btrim(coalesce(p_foto, '')), '');
  v_firma  text := nullif(btrim(coalesce(p_firma, '')), '');
begin
  select p.nombre into v_nombre
    from public.perfilsociodemografico p
   where regexp_replace(coalesce(p.cedula, ''), '\D', '', 'g') = v_ced
     and p.estado = 'ACTIVO' and p.cargo = 'CONDUCTOR'
   limit 1;
  if v_nombre is null then
    return jsonb_build_object('ok', false, 'error', 'Esa cédula no aparece como conductor activo.');
  end if;

  select placa into v_placa from public.parque_automotor
   where btrim(numero_interno) = v_mov and estado = 'Activo' limit 1;
  if v_placa is null then
    return jsonb_build_object('ok', false, 'error', 'El bus ' || v_mov || ' no está activo en el parque.');
  end if;

  -- La selfie es el soporte de que la revisión se hizo en el carro: sin ella no se guarda.
  if v_selfie is null then
    return jsonb_build_object('ok', false, 'error', 'Falta la foto tuya dentro del bus.');
  end if;
  if v_firma is null then
    return jsonb_build_object('ok', false, 'error', 'Falta tu firma.');
  end if;

  -- Deben venir TODAS las preguntas activas respondidas
  select count(*) into v_total from public.preoperacional_preguntas where activa;
  if coalesce(jsonb_array_length(p_items), 0) <> v_total then
    return jsonb_build_object('ok', false, 'error', 'Faltan preguntas por responder.');
  end if;

  -- Una respuesta MAL sin explicacion no sirve para nada en el taller
  for it in select * from jsonb_array_elements(p_items) loop
    v_resp := upper(btrim(coalesce(it->>'respuesta', '')));
    v_com  := nullif(btrim(coalesce(it->>'comentario', '')), '');
    if v_resp not in ('BIEN', 'MAL', 'NO APLICA') then
      return jsonb_build_object('ok', false, 'error', 'Respuesta inválida.');
    end if;
    if v_resp = 'MAL' then
      v_mal := v_mal + 1;
      if v_com is null then
        return jsonb_build_object('ok', false, 'error', 'Cuéntanos qué pasa con lo que marcaste en mal estado.');
      end if;
    end if;
  end loop;

  insert into public.preoperacionales (fecha, cedula, nombre, movil, placa, kms, estado, novedades, firma, selfie)
  values ((now() at time zone 'America/Bogota')::date, v_ced, v_nombre, v_mov, v_placa, p_kms,
          case when v_mal > 0 then 'PENDIENTE' else 'SIN NOVEDAD' end, v_mal, v_firma, v_selfie)
  on conflict (fecha, cedula, movil) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'error',
      'Ya registraste hoy el preoperacional del bus ' || v_mov || '.');
  end if;

  insert into public.preoperacional_items (preop_id, orden, pregunta, respuesta, comentario)
  select v_id,
         (it2->>'orden')::int,
         coalesce(pq.texto, 'Pregunta ' || (it2->>'orden')),
         upper(btrim(it2->>'respuesta')),
         nullif(btrim(coalesce(it2->>'comentario', '')), '')
    from jsonb_array_elements(p_items) it2
    left join public.preoperacional_preguntas pq on pq.orden = (it2->>'orden')::int;

  return jsonb_build_object('ok', true, 'id', v_id, 'novedades', v_mal,
                            'estado', case when v_mal > 0 then 'PENDIENTE' else 'SIN NOVEDAD' end);
end $function$;

-- Puertas publicas: las llama el link del conductor, que entra como anon.
revoke all on function public.preop_buses()   from public;
revoke all on function public.preop_guardar(text, text, numeric, jsonb, text, text) from public;
grant execute on function public.preop_buses()   to anon, authenticated;
grant execute on function public.preop_guardar(text, text, numeric, jsonb, text, text) to anon, authenticated;

-- Comprobacion
select 'preguntas activas' as dato, count(*)::text as valor from public.preoperacional_preguntas where activa
union all
select 'buses en la lista', jsonb_array_length(public.preop_buses())::text
union all
select 'primer bus', (public.preop_buses()->0)::text
union all
select 'columna selfie', (select count(*)::text from information_schema.columns
                           where table_schema = 'public' and table_name = 'preoperacionales'
                             and column_name = 'selfie');
