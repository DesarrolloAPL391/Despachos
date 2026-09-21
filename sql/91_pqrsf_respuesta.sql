-- ============================================================================================
-- 91) PQRSF: que las áreas respondan aquí
--
-- Hasta ahora el módulo solo leía la hoja. Con esto un área contesta la PQRSF dentro de la app,
-- queda registrado quién respondió y cuándo, y el cumplimiento se recalcula solo.
--
-- EL PROBLEMA QUE RESUELVE ESTE ARCHIVO: la radicación sigue en AppSheet y la hoja se vuelve a
-- traer cada tanto. Si la respuesta escrita aquí se guardara en las mismas columnas que trae la
-- hoja, la siguiente carga la borraría. Por eso la gestión vive en columnas PROPIAS que
-- `pqrsf_cargar` no toca nunca:
--     respuesta_app, respondido_por, respondido_en, respondido_el, estado_app, area_app
-- Lo que se muestra como "respuesta" es la de la app si existe y, si no, la que vino de la hoja.
--
-- El cumplimiento pasa a medirse con la fecha EFECTIVA: la de la hoja o, si el área contestó
-- aquí, el día en que lo hizo. Se guarda `respondido_el` como fecha de Colombia ya resuelta,
-- porque una columna calculada no puede convertir zonas horarias por su cuenta.
--
-- QUIÉN RESPONDE QUÉ: administración y Gestión Humana responden cualquiera. A las cuentas de
-- servicio al cliente se les puede asignar un área en `pqrsf_acceso.area`: con área puesta solo
-- responden lo de su área; sin área puesta responden cualquiera (que es como queda al aplicar
-- este archivo, para no bloquear a nadie de entrada).
--
-- Se aplica sobre sql/89 y 90.
-- ============================================================================================

-- 1) Columnas propias de la gestión -----------------------------------------------------------
alter table public.pqrsf
  add column if not exists respuesta_app   text,
  add column if not exists respondido_por  text,
  add column if not exists respondido_en   timestamptz,
  add column if not exists respondido_el   date,
  add column if not exists estado_app      text,
  add column if not exists area_app        text;

comment on column public.pqrsf.respuesta_app  is 'Respuesta escrita en la app. La carga de la hoja NO la toca.';
comment on column public.pqrsf.respondido_el  is 'Dia (hora Colombia) en que el area respondio aqui. Lo usa el cumplimiento.';
comment on column public.pqrsf.estado_app     is 'EN PROCESO / RESPONDIDA / CERRADA, segun lo que haga el area en la app.';

-- 2) El cumplimiento pasa a contar también la respuesta dada aquí ------------------------------
--    Hay que rehacer las dos columnas calculadas: una columna generada no puede apoyarse en otra.
alter table public.pqrsf drop column if exists cumplimiento;
alter table public.pqrsf drop column if exists dias_respuesta;

alter table public.pqrsf
  add column dias_respuesta integer generated always as (
    case when coalesce(fecha_respuesta, respondido_el) is not null and fecha_radicado is not null
         then coalesce(fecha_respuesta, respondido_el) - fecha_radicado end) stored;

alter table public.pqrsf
  add column cumplimiento text generated always as (
    case when coalesce(fecha_respuesta, respondido_el) is null      then 'SIN RESPUESTA'
         when fecha_limite is null                                  then 'SIN PLAZO'
         when coalesce(fecha_respuesta, respondido_el) <= fecha_limite then 'A TIEMPO'
         else                                                            'FUERA DE PLAZO' end) stored;

create index if not exists pqrsf_cumplimiento_idx on public.pqrsf (cumplimiento, fecha_radicado desc);
create index if not exists pqrsf_estado_app_idx   on public.pqrsf (estado_app) where estado_app is not null;

-- 3) Historial: todo movimiento queda registrado ------------------------------------------------
create table if not exists public.pqrsf_gestion (
  id         bigserial primary key,
  pqrsf_key  text not null references public.pqrsf(key) on delete cascade,
  accion     text not null,      -- RESPUESTA | ASIGNACION | CIERRE | REAPERTURA | NOTA
  texto      text,
  area       text,
  usuario    text not null,
  creado_en  timestamptz not null default now()
);
create index if not exists pqrsf_gestion_key_idx on public.pqrsf_gestion (pqrsf_key, creado_en desc);
comment on table public.pqrsf_gestion is 'Bitacora de la gestion hecha en la app: quien respondio, asigno, cerro o reabrio.';

alter table public.pqrsf_gestion enable row level security;
drop policy if exists pqrsf_gestion_ver on public.pqrsf_gestion;
create policy pqrsf_gestion_ver on public.pqrsf_gestion
  for select to authenticated using ((select public.es_pqrsf()));
revoke all on public.pqrsf_gestion from public, anon;
grant select on public.pqrsf_gestion to authenticated;
revoke all on sequence public.pqrsf_gestion_id_seq from public, anon;

-- 4) A qué área pertenece cada cuenta -----------------------------------------------------------
alter table public.pqrsf_acceso add column if not exists area text;
comment on column public.pqrsf_acceso.area is
  'Area de destino que responde esa cuenta (tal como aparece en RESPONSABLE AREA DE DESTINO). Vacio = responde cualquiera.';

create or replace function public.pqrsf_mi_area()
returns text
language sql stable security definer set search_path to 'public'
as $$
  select a.area from public.pqrsf_acceso a
   where lower(a.email) = lower(coalesce(auth.email(), '')) limit 1;
$$;
revoke all on function public.pqrsf_mi_area() from public, anon;
grant execute on function public.pqrsf_mi_area() to authenticated;

-- ¿Puede esta cuenta responder ESTA PQRSF?
create or replace function public.pqrsf_puede_responder(p_key text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select case
    when public.es_admin() or public.es_gestion_humana() then true
    when not public.es_pqrsf_editor() then false
    when coalesce(public.pqrsf_mi_area(), '') = '' then true      -- sin area asignada: responde cualquiera
    else exists (select 1 from public.pqrsf p
                  where p.key = p_key
                    and upper(coalesce(p.area_app, p.responsable_destino, ''))
                        = upper(public.pqrsf_mi_area()))
  end;
$$;
revoke all on function public.pqrsf_puede_responder(text) from public, anon;
grant execute on function public.pqrsf_puede_responder(text) to authenticated;

-- 5) Responder -----------------------------------------------------------------------------------
--    p_cerrar = true deja la PQRSF cerrada; si no, queda RESPONDIDA y se puede seguir editando.
create or replace function public.pqrsf_responder(p_key text, p_texto text, p_cerrar boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_hoy date := (now() at time zone 'America/Bogota')::date; v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.pqrsf_puede_responder(p_key) then
    return jsonb_build_object('ok', false, 'error', 'Esta PQRSF no es de tu area.');
  end if;
  if coalesce(trim(p_texto), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe la respuesta antes de guardar.');
  end if;
  if not exists (select 1 from public.pqrsf where key = p_key) then
    return jsonb_build_object('ok', false, 'error', 'No se encontro la PQRSF.');
  end if;

  update public.pqrsf set
    respuesta_app  = trim(p_texto),
    respondido_por = v_yo,
    respondido_en  = now(),
    respondido_el  = coalesce(respondido_el, v_hoy),   -- la primera respuesta es la que cuenta para el plazo
    estado_app     = case when p_cerrar then 'CERRADA' else 'RESPONDIDA' end
  where key = p_key;

  insert into public.pqrsf_gestion (pqrsf_key, accion, texto, usuario)
  values (p_key, case when p_cerrar then 'CIERRE' else 'RESPUESTA' end, trim(p_texto), v_yo);

  return (select jsonb_build_object('ok', true, 'estado_app', p.estado_app,
                                    'respondido_el', p.respondido_el, 'cumplimiento', p.cumplimiento)
            from public.pqrsf p where p.key = p_key);
end $$;
revoke all on function public.pqrsf_responder(text, text, boolean) from public, anon;
grant execute on function public.pqrsf_responder(text, text, boolean) to authenticated;

-- 6) Asignar a un área, reabrir y anotar ----------------------------------------------------------
create or replace function public.pqrsf_asignar(p_key text, p_area text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not (public.es_admin() or public.es_gestion_humana()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion o Gestion Humana reasignan una PQRSF.');
  end if;
  if coalesce(trim(p_area), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Indica a que area se asigna.');
  end if;
  update public.pqrsf set area_app = upper(trim(p_area)),
                          estado_app = coalesce(estado_app, 'EN PROCESO')
   where key = p_key;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro la PQRSF.'); end if;
  insert into public.pqrsf_gestion (pqrsf_key, accion, area, usuario)
  values (p_key, 'ASIGNACION', upper(trim(p_area)), v_yo);
  return jsonb_build_object('ok', true, 'area_app', upper(trim(p_area)));
end $$;
revoke all on function public.pqrsf_asignar(text, text) from public, anon;
grant execute on function public.pqrsf_asignar(text, text) to authenticated;

create or replace function public.pqrsf_reabrir(p_key text, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not (public.es_admin() or public.es_gestion_humana()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion o Gestion Humana reabren una PQRSF.');
  end if;
  update public.pqrsf set estado_app = 'EN PROCESO' where key = p_key;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro la PQRSF.'); end if;
  insert into public.pqrsf_gestion (pqrsf_key, accion, texto, usuario)
  values (p_key, 'REAPERTURA', nullif(trim(coalesce(p_nota, '')), ''), v_yo);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.pqrsf_reabrir(text, text) from public, anon;
grant execute on function public.pqrsf_reabrir(text, text) to authenticated;

create or replace function public.pqrsf_nota(p_key text, p_texto text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_pqrsf_editor() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para anotar en las PQRSF.');
  end if;
  if coalesce(trim(p_texto), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'La nota esta vacia.');
  end if;
  insert into public.pqrsf_gestion (pqrsf_key, accion, texto, usuario)
  values (p_key, 'NOTA', trim(p_texto), v_yo);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.pqrsf_nota(text, text) from public, anon;
grant execute on function public.pqrsf_nota(text, text) to authenticated;

-- 7) Lo que necesita la ficha: historial + si esta cuenta puede responder --------------------------
create or replace function public.pqrsf_ficha(p_key text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_pqrsf() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_responder', public.pqrsf_puede_responder(p_key),
      'puede_asignar',   (public.es_admin() or public.es_gestion_humana()),
      'mi_area',         public.pqrsf_mi_area(),
      'areas',           (select coalesce(jsonb_agg(distinct a), '[]'::jsonb)
                            from (select coalesce(area_app, responsable_destino) as a
                                    from public.pqrsf
                                   where coalesce(area_app, responsable_destino) is not null) s),
      'historial',       (select coalesce(jsonb_agg(jsonb_build_object(
                             'accion', g.accion, 'texto', g.texto, 'area', g.area,
                             'usuario', g.usuario,
                             'cuando', to_char(g.creado_en at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI'))
                             order by g.creado_en desc), '[]'::jsonb)
                            from public.pqrsf_gestion g where g.pqrsf_key = p_key))
  end;
$$;
revoke all on function public.pqrsf_ficha(text) from public, anon;
grant execute on function public.pqrsf_ficha(text) to authenticated;

-- 8) Las pantallas de sql/90 pasan a usar la fecha efectiva ---------------------------------------
--    (pendiente = sin respuesta en la hoja NI en la app, o marcada ABIERTA sin cerrar aquí)
create or replace function public.pqrsf_pendientes(p_limite int default 500)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_items jsonb; v_hoy date := (now() at time zone 'America/Bogota')::date; v_lim int;
begin
  if not public.es_pqrsf() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver las PQRSF.');
  end if;
  v_lim := greatest(least(coalesce(p_limite, 500), 2000), 1);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.atraso desc nulls last, x.fecha_radicado), '[]'::jsonb)
    into v_items
  from (
    select p.key, p.radicado, p.fecha_radicado, p.fecha_limite, p.tipo, p.motivo, p.urgencia,
           p.numero_interno, p.ruta,
           coalesce(p.area_app, p.responsable_destino) as responsable_destino,
           p.estado, p.estado_app, p.medio_recibido, p.usuario_nombre,
           (v_hoy - p.fecha_limite)   as atraso,
           (v_hoy - p.fecha_radicado) as edad
    from public.pqrsf p
    where coalesce(p.fecha_respuesta, p.respondido_el) is null
       or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')
    order by (v_hoy - p.fecha_limite) desc nulls last, p.fecha_radicado
    limit v_lim
  ) x;

  return jsonb_build_object(
    'ok', true, 'hoy', v_hoy,
    'total',    (select count(1) from public.pqrsf p
                  where coalesce(p.fecha_respuesta, p.respondido_el) is null
                     or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
    'vencidas', (select count(1) from public.pqrsf p
                  where (coalesce(p.fecha_respuesta, p.respondido_el) is null
                         or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA'))
                    and p.fecha_limite is not null and p.fecha_limite < v_hoy),
    'items', v_items);
end $$;
revoke all on function public.pqrsf_pendientes(int) from public, anon;
grant execute on function public.pqrsf_pendientes(int) to authenticated;

create or replace function public.pqrsf_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_pqrsf() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_cargar', public.es_pqrsf_editor(),
      'mi_area',      public.pqrsf_mi_area(),
      'url',          (select url from public.pqrsf_fuente where id = 1),
      'ultima_carga', (select ultima_carga from public.pqrsf_fuente where id = 1),
      'total',        (select count(1) from public.pqrsf),
      'desde',        (select min(fecha_radicado) from public.pqrsf),
      'hasta',        (select max(fecha_radicado) from public.pqrsf),
      'abiertas',     (select count(1) from public.pqrsf where estado = 'ABIERTA'),
      'sin_respuesta',(select count(1) from public.pqrsf where cumplimiento = 'SIN RESPUESTA'),
      'fuera_plazo',  (select count(1) from public.pqrsf where cumplimiento = 'FUERA DE PLAZO'),
      'respondidas_app', (select count(1) from public.pqrsf where respuesta_app is not null),
      'pendientes',   (select count(1) from public.pqrsf p
                        where coalesce(p.fecha_respuesta, p.respondido_el) is null
                           or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
      'vencidas',     (select count(1) from public.pqrsf p
                        where (coalesce(p.fecha_respuesta, p.respondido_el) is null
                               or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA'))
                          and p.fecha_limite is not null
                          and p.fecha_limite < (now() at time zone 'America/Bogota')::date))
  end;
$$;
revoke all on function public.pqrsf_estado() from public, anon;
grant execute on function public.pqrsf_estado() to authenticated;

-- 9) Para asignar áreas a las cuentas de servicio al cliente (va aparte, este archivo es publico):
--    update public.pqrsf_acceso set area = '<AREA DE DESTINO>' where email = '<correo>';
--    select email, area from public.pqrsf_acceso order by email;
