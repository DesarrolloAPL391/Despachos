-- 131_preop_ubicacion.sql  (LOCAL, sin publicar)
-- "que con la foto que salga directo donde esta" (22/10/2026): la foto se guarda con el
-- PUNTO donde se tomo. Foto + ubicacion + hora es la constancia de que la revision se hizo
-- en el carro y no en la casa.
--
-- La ubicacion se INTENTA siempre, pero NO bloquea: en un patio techado o con el GPS frio el
-- navegador puede no darla, y dejar a un conductor sin poder despachar por eso es peor. En la
-- ficha del admin se ve claramente "sin ubicacion" cuando falta, que es lo que permite
-- reclamarlo. Si se quiere volver obligatoria, es una linea mas abajo.
--
-- Ademas este archivo CONSOLIDA la funcion: queda una sola version con todo lo decidido
-- (sql/127 base, 128 selfie obligatoria + kms opcional, 129 sin "no aplica", 130 sin firma).
-- Por eso se BORRA la version de 6 argumentos y se crea la de 8: dejar las dos haria
-- ambigua la llamada.

alter table public.preoperacionales
  add column if not exists lat        numeric,
  add column if not exists lon        numeric,
  add column if not exists precision_m numeric;

comment on column public.preoperacionales.lat is 'Latitud donde se tomo la foto (null si el navegador no la dio).';
comment on column public.preoperacionales.lon is 'Longitud donde se tomo la foto.';
comment on column public.preoperacionales.precision_m is 'Exactitud informada por el navegador, en metros.';

drop function if exists public.preop_guardar(text, text, numeric, jsonb, text, text);

create or replace function public.preop_guardar(
  p_cedula text,
  p_movil  text,
  p_kms    numeric,
  p_items  jsonb,                     -- [{orden, respuesta, comentario}]
  p_foto   text,                      -- foto del conductor dentro del bus (obligatoria)
  p_lat    numeric default null,
  p_lon    numeric default null,
  p_prec   numeric default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nombre text; v_placa text; v_mov text := btrim(coalesce(p_movil, ''));
  v_id bigint; v_mal int := 0; v_total int; it jsonb; v_resp text; v_com text;
  v_foto text := nullif(btrim(coalesce(p_foto, '')), '');
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

  -- La foto es el soporte de que la revisión se hizo en el carro: sin ella no se guarda.
  if v_foto is null then
    return jsonb_build_object('ok', false, 'error', 'Falta la foto tuya dentro del bus.');
  end if;

  -- Deben venir TODAS las preguntas activas respondidas
  select count(*) into v_total from public.preoperacional_preguntas where activa;
  if coalesce(jsonb_array_length(p_items), 0) <> v_total then
    return jsonb_build_object('ok', false, 'error', 'Faltan preguntas por responder.');
  end if;

  -- Solo BIEN o MAL, y una respuesta MAL sin explicación no le sirve al taller
  for it in select * from jsonb_array_elements(p_items) loop
    v_resp := upper(btrim(coalesce(it->>'respuesta', '')));
    v_com  := nullif(btrim(coalesce(it->>'comentario', '')), '');
    if v_resp not in ('BIEN', 'MAL') then
      return jsonb_build_object('ok', false, 'error', 'Cada punto se responde Bien o Mal.');
    end if;
    if v_resp = 'MAL' then
      v_mal := v_mal + 1;
      if v_com is null then
        return jsonb_build_object('ok', false, 'error', 'Cuéntanos qué pasa con lo que marcaste en mal estado.');
      end if;
    end if;
  end loop;

  insert into public.preoperacionales
    (fecha, cedula, nombre, movil, placa, kms, estado, novedades, selfie, lat, lon, precision_m)
  values ((now() at time zone 'America/Bogota')::date, v_ced, v_nombre, v_mov, v_placa, p_kms,
          case when v_mal > 0 then 'PENDIENTE' else 'SIN NOVEDAD' end, v_mal, v_foto,
          p_lat, p_lon, p_prec)
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

revoke all on function public.preop_guardar(text, text, numeric, jsonb, text, numeric, numeric, numeric) from public;
grant execute on function public.preop_guardar(text, text, numeric, jsonb, text, numeric, numeric, numeric) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- OJO CON LAS PRUEBAS EN ESTE MISMO ARCHIVO (me costo una vuelta entera):
-- la Management API ejecuta TODO el archivo dentro de una sola transaccion. Un `begin;`
-- aqui NO abre una transaccion nueva, asi que el `rollback;` de un bloque de pruebas
-- REVIERTE TAMBIEN EL DDL de arriba... y la respuesta se ve exitosa. Asi se perdieron en
-- silencio sql/129 y sql/130. Las pruebas que escriban van en archivo aparte.
-- Aqui solo comprobaciones de LECTURA.
-- ---------------------------------------------------------------------------
select 'firma de la funcion' as dato, p.oid::regprocedure::text as valor
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'preop_guardar'
union all
select 'ya no admite NO APLICA',
       (position('NO APLICA' in pg_get_functiondef(p.oid)) = 0)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'preop_guardar'
union all
select 'ya no exige firma',
       (position('Falta tu firma' in pg_get_functiondef(p.oid)) = 0)::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'preop_guardar'
union all
select 'columnas de ubicacion',
       (select count(*)::text from information_schema.columns
         where table_schema = 'public' and table_name = 'preoperacionales'
           and column_name in ('lat', 'lon', 'precision_m'));
