-- ============================================================================================
-- 92) PQRSF: la bandeja separa "sin responder" de "falta cerrar"
--
-- POR QUÉ: al medir la bandeja real (20/09/2026) salieron 80 PQRSF abiertas, pero NO son lo
-- mismo: solo 3 están sin responder; las otras 77 ya tienen respuesta y lo que falta es que
-- alguien las cierre. Mezcladas en una sola lista el área ve 80 y se paraliza; separadas ve
-- 3 para redactar y 77 para revisar y cerrar, que es trabajo de un clic.
--
-- TAMBIÉN CAMBIA QUÉ SIGNIFICA "VENCIDA": pasa a contar solo lo que está sin responder y con el
-- plazo pasado. Una PQRSF ya respondida que nadie cerró es desorden administrativo, no
-- incumplimiento con el usuario, y no debe inflar el aviso rojo del menú.
--
-- Se aplica sobre sql/89, 90 y 91.
-- ============================================================================================

-- 1) La bandeja, en dos listas -----------------------------------------------------------------
create or replace function public.pqrsf_pendientes(p_limite int default 500)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_sin jsonb; v_cer jsonb;
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_lim int := greatest(least(coalesce(p_limite, 500), 2000), 1);
begin
  if not public.es_pqrsf() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver las PQRSF.');
  end if;

  -- A) SIN RESPONDER: nadie le ha contestado al usuario. Lo mas vencido primero.
  select coalesce(jsonb_agg(to_jsonb(x) order by x.atraso desc nulls last, x.fecha_radicado), '[]'::jsonb)
    into v_sin
  from (
    select p.key, p.radicado, p.fecha_radicado, p.fecha_limite, p.tipo, p.motivo, p.urgencia,
           p.numero_interno, p.ruta,
           coalesce(p.area_app, p.responsable_destino) as responsable_destino,
           p.estado, p.estado_app, p.medio_recibido, p.usuario_nombre,
           (v_hoy - p.fecha_limite)   as atraso,
           (v_hoy - p.fecha_radicado) as edad
    from public.pqrsf p
    where coalesce(p.fecha_respuesta, p.respondido_el) is null
    order by (v_hoy - p.fecha_limite) desc nulls last, p.fecha_radicado
    limit v_lim
  ) x;

  -- B) FALTA CERRAR: ya respondida, pero sigue marcada ABIERTA. La mas vieja sin cerrar primero.
  select coalesce(jsonb_agg(to_jsonb(y) order by y.dias_sin_cerrar desc nulls last), '[]'::jsonb)
    into v_cer
  from (
    select p.key, p.radicado, p.fecha_radicado, p.fecha_limite, p.tipo, p.motivo,
           p.numero_interno, p.ruta,
           coalesce(p.area_app, p.responsable_destino) as responsable_destino,
           p.estado, p.estado_app, p.cumplimiento,
           coalesce(p.fecha_respuesta, p.respondido_el)           as fecha_efectiva,
           (v_hoy - coalesce(p.fecha_respuesta, p.respondido_el)) as dias_sin_cerrar,
           (p.respuesta_app is not null)                          as respondida_aqui
    from public.pqrsf p
    where coalesce(p.fecha_respuesta, p.respondido_el) is not null
      and p.estado = 'ABIERTA'
      and coalesce(p.estado_app, '') <> 'CERRADA'
    order by (v_hoy - coalesce(p.fecha_respuesta, p.respondido_el)) desc nulls last
    limit v_lim
  ) y;

  return jsonb_build_object(
    'ok', true, 'hoy', v_hoy,
    'items',  v_sin,            -- sin responder
    'cerrar', v_cer,            -- respondidas que falta cerrar
    'sin_responder', (select count(1) from public.pqrsf p
                       where coalesce(p.fecha_respuesta, p.respondido_el) is null),
    'falta_cerrar',  (select count(1) from public.pqrsf p
                       where coalesce(p.fecha_respuesta, p.respondido_el) is not null
                         and p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA'),
    'vencidas',      (select count(1) from public.pqrsf p
                       where coalesce(p.fecha_respuesta, p.respondido_el) is null
                         and p.fecha_limite is not null and p.fecha_limite < v_hoy),
    'total',         (select count(1) from public.pqrsf p
                       where coalesce(p.fecha_respuesta, p.respondido_el) is null
                          or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')));
end $$;
revoke all on function public.pqrsf_pendientes(int) from public, anon;
grant execute on function public.pqrsf_pendientes(int) to authenticated;

-- 2) Cerrar sin volver a redactar ---------------------------------------------------------------
--    `pqrsf_responder` exige texto, a proposito. Pero para las que YA tienen respuesta lo unico
--    que falta es cerrarlas, y obligar a reescribir la respuesta seria pedir que se invente una.
create or replace function public.pqrsf_cerrar(p_key text, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), '')); v_tiene boolean;
begin
  if not public.pqrsf_puede_responder(p_key) then
    return jsonb_build_object('ok', false, 'error', 'Esta PQRSF no es de tu area.');
  end if;
  select (coalesce(fecha_respuesta, respondido_el) is not null) into v_tiene
    from public.pqrsf where key = p_key;
  if v_tiene is null then
    return jsonb_build_object('ok', false, 'error', 'No se encontro la PQRSF.');
  end if;
  if not v_tiene then
    return jsonb_build_object('ok', false, 'error',
      'Esta PQRSF no tiene respuesta todavia: primero respondela y luego se cierra.');
  end if;

  update public.pqrsf set estado_app = 'CERRADA' where key = p_key;
  insert into public.pqrsf_gestion (pqrsf_key, accion, texto, usuario)
  values (p_key, 'CIERRE', nullif(trim(coalesce(p_nota, '')), ''), v_yo);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.pqrsf_cerrar(text, text) from public, anon;
grant execute on function public.pqrsf_cerrar(text, text) to authenticated;

-- 3) El aviso del menu deja de contar lo que ya se respondio -------------------------------------
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
      -- pendientes = lo que hay en la bandeja (las dos listas juntas)
      'pendientes',   (select count(1) from public.pqrsf p
                        where coalesce(p.fecha_respuesta, p.respondido_el) is null
                           or (p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
      'sin_responder',(select count(1) from public.pqrsf p
                        where coalesce(p.fecha_respuesta, p.respondido_el) is null),
      'falta_cerrar', (select count(1) from public.pqrsf p
                        where coalesce(p.fecha_respuesta, p.respondido_el) is not null
                          and p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA'),
      -- vencida = sin responder Y con el plazo pasado. Lo demas es desorden, no incumplimiento.
      'vencidas',     (select count(1) from public.pqrsf p
                        where coalesce(p.fecha_respuesta, p.respondido_el) is null
                          and p.fecha_limite is not null
                          and p.fecha_limite < (now() at time zone 'America/Bogota')::date))
  end;
$$;
revoke all on function public.pqrsf_estado() from public, anon;
grant execute on function public.pqrsf_estado() to authenticated;
