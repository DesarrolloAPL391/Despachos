-- 127_preoperacional.sql  (LOCAL, sin publicar)
-- INSPECCION PREOPERACIONAL DEL VEHICULO.
--
-- El conductor entra por un link publico con su CEDULA (no tiene cuenta de la app), elige su
-- movil y responde las 12 preguntas. Reemplaza el formulario de AppSheet, conservando su
-- estructura: una fila por pregunta, con la cabecera repetida (fecha, conductor, movil, placa,
-- kms, estado) y el ciclo de taller al final (atendido por, comentarios, fecha de atencion).
--
-- Decisiones de esta primera version (faciles de cambiar, todavia no esta publicado):
--   * Respuesta BIEN / MAL / NO APLICA. Si algo va MAL, el comentario es OBLIGATORIO y la
--     inspeccion nace en estado PENDIENTE para que taller la atienda.
--   * Se entra SOLO con la cedula, como pidio el usuario. Por eso la funcion de identificacion
--     devuelve unicamente el nombre (para que confirme que es el) y nada mas: con una cedula
--     ajena no se puede sacar ningun dato personal.
--   * La firma se guarda siempre (pesa poco, es un trazo); la foto del vehiculo es opcional y
--     el navegador la reduce antes de enviarla. Van en base64 dentro de la fila, igual que los
--     soportes de permisos (sql/97). Si se decide exigir foto todos los dias, conviene moverlas
--     a Storage: 315 vehiculos diarios con foto son ~1 GB al mes dentro de la base.
--   * Un preoperacional por conductor + movil + dia.
--
-- Mientras este en pruebas, en la app lo ve SOLO el administrador.

-- ---------------------------------------------------------------------------
-- 1) Catalogo de preguntas (configurable: se agregan o quitan sin tocar codigo)
-- ---------------------------------------------------------------------------
create table if not exists public.preoperacional_preguntas (
  id      bigserial primary key,
  orden   int  not null,
  texto   text not null,
  corto   text,                      -- titulo de la tarjeta en el celular
  icono   text,
  grupo   text,
  activa  boolean not null default true
);
create unique index if not exists preop_preg_orden_uk on public.preoperacional_preguntas (orden);

insert into public.preoperacional_preguntas (orden, corto, texto, icono, grupo) values
  (1,  'Frenos',              'Frenos (carga de aire, tensión de parqueo y altura del pedal)', '🛑', 'Mecánica'),
  (2,  'Dirección',           'Dirección (sin juego y alineada)', '🎯', 'Mecánica'),
  (3,  'Suspensión',          'Suspensión (estado de muelles en general)', '🔩', 'Mecánica'),
  (4,  'Llantas y rines',     'Llantas (labrado) y rines (sin fisuras)', '🛞', 'Mecánica'),
  (5,  'Sistema eléctrico',   'Sistema eléctrico funcional (todas las luces, pito, alarma de reversa, Tablero sin alarmas críticas)', '💡', 'Luces y visibilidad'),
  (6,  'Espejos y parabrisas','Espejos, parabrisas (sin fisuras y/o rayones) y limpiaparabrisas (funcionalidad)', '🪞', 'Luces y visibilidad'),
  (7,  'Niveles',             'Niveles de aceite y liquidos por encima del mínimo', '🛢️', 'Mecánica'),
  (8,  'Cinturón y asiento',  'Cinturón y asiento del conductor (anclados y funcionalidad sin bloqueos)', '🪑', 'Cabina y pasajeros'),
  (9,  'Puertas',             'Puertas (apertura y cierre)', '🚪', 'Cabina y pasajeros'),
  (10, 'Salidas de emergencia','Salidas de emergencia (señalizadas y elementos de quiebre)', '🚨', 'Cabina y pasajeros'),
  (11, 'Pasamanos',           'Pasamanos (ajustados)', '🫱', 'Cabina y pasajeros'),
  (12, 'Equipo de carretera', 'Equipo de carretera vigente (extintor, botiquín, conos, tacos, caja herramienta, linterna, cruceta, llanta de repuesto)', '🧰', 'Equipo')
on conflict (orden) do update
  set texto = excluded.texto, corto = excluded.corto, icono = excluded.icono,
      grupo = excluded.grupo, activa = true;

-- ---------------------------------------------------------------------------
-- 2) La inspeccion (cabecera)
-- ---------------------------------------------------------------------------
create table if not exists public.preoperacionales (
  id             bigserial primary key,
  fecha          date not null default (now() at time zone 'America/Bogota')::date,
  cedula         text not null,
  nombre         text,
  tipo           text not null default 'Conductor',   -- quien inspecciona (columna "Tipo" del CSV)
  movil          text not null,
  placa          text,
  kms            numeric,
  estado         text not null default 'SIN NOVEDAD'
                 check (estado in ('SIN NOVEDAD', 'PENDIENTE', 'ATENDIDO')),
  novedades      int  not null default 0,             -- cuantas respuestas salieron MAL
  foto_vehiculo  text,                                -- base64 (opcional)
  firma          text,                                -- base64 del trazo
  creado_en      timestamptz not null default now(),
  -- ciclo de taller
  atendido_por       text,
  comentarios_taller text,
  adjuntos           text,
  atendido_en        timestamptz
);
-- Un preoperacional por conductor, movil y dia
create unique index if not exists preop_dia_uk
  on public.preoperacionales (fecha, cedula, movil);
create index if not exists preop_fecha_ix  on public.preoperacionales (fecha desc);
create index if not exists preop_estado_ix on public.preoperacionales (estado) where estado = 'PENDIENTE';

-- ---------------------------------------------------------------------------
-- 3) El detalle: una fila por pregunta (la misma forma del archivo de AppSheet)
-- ---------------------------------------------------------------------------
create table if not exists public.preoperacional_items (
  id         bigserial primary key,
  preop_id   bigint not null references public.preoperacionales(id) on delete cascade,
  orden      int    not null,
  pregunta   text   not null,
  respuesta  text   not null check (respuesta in ('BIEN', 'MAL', 'NO APLICA')),
  comentario text
);
create index if not exists preop_items_ix on public.preoperacional_items (preop_id, orden);

-- ---------------------------------------------------------------------------
-- 4) Permisos: en la app lo ve SOLO el administrador (mientras esta en pruebas)
-- ---------------------------------------------------------------------------
alter table public.preoperacional_preguntas enable row level security;
alter table public.preoperacionales         enable row level security;
alter table public.preoperacional_items     enable row level security;

drop policy if exists preop_preg_sel on public.preoperacional_preguntas;
create policy preop_preg_sel on public.preoperacional_preguntas
  for select using ((select public.es_admin()));
drop policy if exists preop_preg_wr on public.preoperacional_preguntas;
create policy preop_preg_wr on public.preoperacional_preguntas
  for all using ((select public.es_admin())) with check ((select public.es_admin()));

drop policy if exists preop_sel on public.preoperacionales;
create policy preop_sel on public.preoperacionales
  for select using ((select public.es_admin()));
drop policy if exists preop_wr on public.preoperacionales;
create policy preop_wr on public.preoperacionales
  for all using ((select public.es_admin())) with check ((select public.es_admin()));

drop policy if exists preop_items_sel on public.preoperacional_items;
create policy preop_items_sel on public.preoperacional_items
  for select using ((select public.es_admin()));
drop policy if exists preop_items_wr on public.preoperacional_items;
create policy preop_items_wr on public.preoperacional_items
  for all using ((select public.es_admin())) with check ((select public.es_admin()));

grant select on public.preoperacional_preguntas, public.preoperacionales, public.preoperacional_items to authenticated;
grant insert, update, delete on public.preoperacionales, public.preoperacional_items, public.preoperacional_preguntas to authenticated;
-- Solo las secuencias de estas tres tablas (nunca un grant sobre todo el esquema)
grant usage, select on sequence public.preoperacional_preguntas_id_seq,
                                public.preoperacionales_id_seq,
                                public.preoperacional_items_id_seq to authenticated;

-- ---------------------------------------------------------------------------
-- 5) Puerta publica 1: identificar al conductor por su cedula
--    Devuelve SOLO el nombre y las preguntas. Nada mas, justamente porque para entrar
--    basta la cedula: con una ajena no se puede averiguar nada de esa persona.
-- ---------------------------------------------------------------------------
create or replace function public.preop_identificar(p_cedula text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nombre text;
  v_preg jsonb;
begin
  if length(v_ced) < 4 then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu número de cédula.');
  end if;

  select p.nombre into v_nombre
    from public.perfilsociodemografico p
   where regexp_replace(coalesce(p.cedula, ''), '\D', '', 'g') = v_ced
     and p.estado = 'ACTIVO'
     and p.cargo  = 'CONDUCTOR'
   limit 1;

  if v_nombre is null then
    return jsonb_build_object('ok', false, 'error',
      'Esa cédula no aparece como conductor activo. Revísala o avísale a Gestión Humana.');
  end if;

  select jsonb_agg(jsonb_build_object('orden', orden, 'texto', texto, 'corto', corto,
                                      'icono', icono, 'grupo', grupo) order by orden)
    into v_preg
    from public.preoperacional_preguntas where activa;

  return jsonb_build_object('ok', true, 'nombre', v_nombre, 'preguntas', coalesce(v_preg, '[]'::jsonb));
end $function$;

-- ---------------------------------------------------------------------------
-- 6) Puerta publica 2: confirmar el movil (devuelve la placa para que no se equivoque de bus)
-- ---------------------------------------------------------------------------
create or replace function public.preop_movil(p_movil text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_placa text; v_mov text := btrim(coalesce(p_movil, ''));
begin
  if v_mov = '' then return jsonb_build_object('ok', false, 'error', 'Escribe el número del bus.'); end if;
  select placa into v_placa from public.parque_automotor
   where btrim(numero_interno) = v_mov and estado = 'Activo' limit 1;
  if v_placa is null then
    return jsonb_build_object('ok', false, 'error', 'El bus ' || v_mov || ' no está activo en el parque.');
  end if;
  return jsonb_build_object('ok', true, 'movil', v_mov, 'placa', v_placa);
end $function$;

-- ---------------------------------------------------------------------------
-- 7) Puerta publica 3: guardar la inspeccion
-- ---------------------------------------------------------------------------
create or replace function public.preop_guardar(
  p_cedula text,
  p_movil  text,
  p_kms    numeric,
  p_items  jsonb,              -- [{orden, respuesta, comentario}]
  p_firma  text default null,
  p_foto   text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  v_nombre text; v_placa text; v_mov text := btrim(coalesce(p_movil, ''));
  v_id bigint; v_mal int := 0; v_total int; it jsonb; v_texto text; v_resp text; v_com text;
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

  insert into public.preoperacionales (fecha, cedula, nombre, movil, placa, kms, estado, novedades, firma, foto_vehiculo)
  values ((now() at time zone 'America/Bogota')::date, v_ced, v_nombre, v_mov, v_placa, p_kms,
          case when v_mal > 0 then 'PENDIENTE' else 'SIN NOVEDAD' end, v_mal,
          nullif(btrim(coalesce(p_firma, '')), ''), nullif(btrim(coalesce(p_foto, '')), ''))
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
-- (El resto de funciones NO deben tener anon; aqui es a proposito y esta acotado.)
revoke all on function public.preop_identificar(text) from public;
revoke all on function public.preop_movil(text)       from public;
revoke all on function public.preop_guardar(text, text, numeric, jsonb, text, text) from public;
grant execute on function public.preop_identificar(text) to anon, authenticated;
grant execute on function public.preop_movil(text)       to anon, authenticated;
grant execute on function public.preop_guardar(text, text, numeric, jsonb, text, text) to anon, authenticated;

-- Comprobacion
select 'preguntas cargadas' as dato, count(*)::text as valor from public.preoperacional_preguntas where activa
union all
select 'identificar (cedula inventada)', (public.preop_identificar('000'))::text
union all
select 'movil inexistente', (public.preop_movil('ZZZZ'))::text;
