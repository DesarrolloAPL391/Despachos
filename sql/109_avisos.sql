-- ===================================================================================
-- 109: AVISOS DE OBLIGATORIA RESPUESTA — comunicados que hay que confirmar que se leyeron.
-- ===================================================================================
-- QUÉ RESUELVE: cuando hay una instrucción que TODOS tienen que cumplir (un plazo, un
-- cambio en el procedimiento), avisarla por WhatsApp o de viva voz deja dos problemas:
-- nunca se sabe quién se enteró, y el que no cumplió siempre puede decir que no supo.
--
-- CÓMO QUEDA: el aviso sale en un modal que NO se puede cerrar sin confirmar. Queda
-- registrado quién lo confirmó y a qué hora, y administración ve en cualquier momento
-- quién falta por leerlo — con nombre, para poder llamarlo.
--
-- Va dirigido por ROL (despachador, auditor, …) y solo lo ve quien tiene ese rol en
-- public.perfiles, que es donde vive el rol real de cada cuenta.
-- ===================================================================================

create table if not exists public.avisos (
  id           bigserial primary key,
  codigo       text unique,           -- para poder reinsertarlo sin duplicarlo
  icono        text not null default '📢',
  titulo       text not null,
  cuerpo       text not null,         -- el texto, con saltos de línea
  puntos       jsonb not null default '[]'::jsonb,   -- las viñetas destacadas
  confirmacion text,                  -- la frase de la casilla que hay que marcar
  boton        text not null default 'Entendido',
  roles        text[] not null default '{}',         -- roles de public.perfiles
  desde        date,
  hasta        date,                  -- hasta cuándo sigue saliendo
  activo       boolean not null default true,
  creado_en    timestamptz not null default now(),
  creado_por   text
);
create index if not exists avisos_activo_idx on public.avisos (activo, desde, hasta);

comment on table public.avisos is
  'Comunicados de obligatoria respuesta. Salen en modal bloqueante y quedan con acuse por persona.';

create table if not exists public.aviso_acuses (
  aviso_id  bigint not null references public.avisos(id) on delete cascade,
  correo    text not null,
  nombre    text,
  rol       text,
  leido_en  timestamptz not null default now(),
  primary key (aviso_id, correo)
);
comment on table public.aviso_acuses is
  'Quien confirmo cada aviso y cuando. Es la prueba de que la instruccion se comunico.';

alter table public.avisos enable row level security;
alter table public.aviso_acuses enable row level security;
drop policy if exists avisos_sel on public.avisos;
create policy avisos_sel on public.avisos for select to authenticated using (true);
drop policy if exists aviso_acuses_sel on public.aviso_acuses;
create policy aviso_acuses_sel on public.aviso_acuses for select to authenticated
  using ( (select public.es_admin()) );
revoke insert, update, delete on public.avisos from authenticated;
revoke insert, update, delete on public.aviso_acuses from authenticated;

-- ---------- Mi rol, tal como está en perfiles ----------
create or replace function public.mi_rol_aviso()
returns text
language sql stable security definer set search_path = public as $fn$
  select rol from public.perfiles where lower(email) = lower(coalesce(auth.email(), '')) and activo limit 1;
$fn$;
revoke all on function public.mi_rol_aviso() from public, anon;
grant execute on function public.mi_rol_aviso() to authenticated;

-- ---------- Lo que tengo pendiente por confirmar ----------
create or replace function public.avisos_pendientes()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare v_rol text; v_correo text; v jsonb; v_hoy date;
begin
  v_correo := lower(coalesce(auth.email(), ''));
  if v_correo = '' then return jsonb_build_object('ok', true, 'filas', '[]'::jsonb); end if;
  v_rol := public.mi_rol_aviso();
  if v_rol is null then return jsonb_build_object('ok', true, 'filas', '[]'::jsonb); end if;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  select jsonb_agg(to_jsonb(a) order by a.id) into v
    from public.avisos a
   where a.activo
     and v_rol = any (a.roles)
     and (a.desde is null or a.desde <= v_hoy)
     and (a.hasta is null or a.hasta >= v_hoy)
     and not exists (select 1 from public.aviso_acuses k
                      where k.aviso_id = a.id and lower(k.correo) = v_correo);

  return jsonb_build_object('ok', true, 'rol', v_rol, 'filas', coalesce(v, '[]'::jsonb));
end $fn$;
revoke all on function public.avisos_pendientes() from public, anon;
grant execute on function public.avisos_pendientes() to authenticated;

-- ---------- Confirmar que lo leí ----------
create or replace function public.aviso_confirmar(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text; v_rol text; v_nombre text;
begin
  v_correo := lower(coalesce(auth.email(), ''));
  if v_correo = '' then return jsonb_build_object('ok', false, 'error', 'Sesión no válida.'); end if;
  select rol, nombre into v_rol, v_nombre from public.perfiles
   where lower(email) = v_correo and activo limit 1;
  if v_rol is null then return jsonb_build_object('ok', false, 'error', 'Cuenta sin rol activo.'); end if;
  if not exists (select 1 from public.avisos where id = p_id and activo) then
    return jsonb_build_object('ok', false, 'error', 'Ese aviso ya no está activo.');
  end if;

  insert into public.aviso_acuses (aviso_id, correo, nombre, rol)
  values (p_id, v_correo, v_nombre, v_rol)
  on conflict (aviso_id, correo) do nothing;

  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.aviso_confirmar(bigint) from public, anon;
grant execute on function public.aviso_confirmar(bigint) to authenticated;

-- ---------- Administración: quién leyó y quién falta ----------
-- Los que faltan salen CON NOMBRE, que es lo que permite llamarlos. Solo admin.
create or replace function public.aviso_control(p_id bigint default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare v jsonb; a public.avisos%rowtype; v_leidos jsonb; v_faltan jsonb;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración ve el control de lectura.');
  end if;

  if p_id is null then
    select jsonb_agg(x order by (x->>'id')::bigint desc) into v from (
      select jsonb_build_object(
        'id', a.id, 'icono', a.icono, 'titulo', a.titulo, 'roles', a.roles,
        'activo', a.activo, 'desde', a.desde, 'hasta', a.hasta, 'creado_en', a.creado_en,
        'leidos', (select count(*) from public.aviso_acuses k where k.aviso_id = a.id),
        'destinatarios', (select count(*) from public.perfiles p
                           where p.activo and p.rol = any (a.roles))) as x
        from public.avisos a) t;
    return jsonb_build_object('ok', true, 'filas', coalesce(v, '[]'::jsonb));
  end if;

  select * into a from public.avisos where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe ese aviso.'); end if;

  select jsonb_agg(jsonb_build_object('correo', k.correo, 'nombre', k.nombre,
                                      'rol', k.rol, 'leido_en', k.leido_en)
                   order by k.leido_en desc)
    into v_leidos from public.aviso_acuses k where k.aviso_id = p_id;

  select jsonb_agg(jsonb_build_object('correo', p.email, 'nombre', p.nombre, 'rol', p.rol)
                   order by p.nombre)
    into v_faltan
    from public.perfiles p
   where p.activo and p.rol = any (a.roles)
     and not exists (select 1 from public.aviso_acuses k
                      where k.aviso_id = p_id and lower(k.correo) = lower(p.email));

  return jsonb_build_object('ok', true, 'aviso', to_jsonb(a),
    'leidos', coalesce(v_leidos, '[]'::jsonb), 'faltan', coalesce(v_faltan, '[]'::jsonb));
end $fn$;
revoke all on function public.aviso_control(bigint) from public, anon;
grant execute on function public.aviso_control(bigint) to authenticated;

-- ---------- Administración: crear, editar, activar o apagar un aviso ----------
create or replace function public.aviso_guardar(
  p_id bigint default null, p_titulo text default null, p_cuerpo text default null,
  p_roles text[] default null, p_puntos jsonb default null, p_confirmacion text default null,
  p_icono text default null, p_boton text default null,
  p_desde date default null, p_hasta date default null, p_activo boolean default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_id bigint; v_correo text;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración publica avisos.');
  end if;
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');

  if p_id is null then
    if nullif(trim(coalesce(p_titulo, '')), '') is null
       or nullif(trim(coalesce(p_cuerpo, '')), '') is null then
      return jsonb_build_object('ok', false, 'error', 'Falta el título o el texto del aviso.');
    end if;
    if p_roles is null or array_length(p_roles, 1) is null then
      return jsonb_build_object('ok', false, 'error', 'Di a qué roles va dirigido.');
    end if;
    insert into public.avisos (titulo, cuerpo, roles, puntos, confirmacion, icono, boton,
                               desde, hasta, creado_por)
    values (trim(p_titulo), trim(p_cuerpo), p_roles, coalesce(p_puntos, '[]'::jsonb),
            nullif(trim(coalesce(p_confirmacion, '')), ''), coalesce(nullif(trim(coalesce(p_icono, '')), ''), '📢'),
            coalesce(nullif(trim(coalesce(p_boton, '')), ''), 'Entendido'), p_desde, p_hasta, v_correo)
    returning id into v_id;
  else
    update public.avisos set
      titulo = coalesce(nullif(trim(coalesce(p_titulo, '')), ''), titulo),
      cuerpo = coalesce(nullif(trim(coalesce(p_cuerpo, '')), ''), cuerpo),
      roles = coalesce(p_roles, roles),
      puntos = coalesce(p_puntos, puntos),
      confirmacion = coalesce(nullif(trim(coalesce(p_confirmacion, '')), ''), confirmacion),
      icono = coalesce(nullif(trim(coalesce(p_icono, '')), ''), icono),
      boton = coalesce(nullif(trim(coalesce(p_boton, '')), ''), boton),
      desde = coalesce(p_desde, desde),
      hasta = coalesce(p_hasta, hasta),
      activo = coalesce(p_activo, activo)
    where id = p_id returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'No existe ese aviso.'); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $fn$;
revoke all on function public.aviso_guardar(bigint, text, text, text[], jsonb, text, text, text, date, date, boolean) from public, anon;
grant execute on function public.aviso_guardar(bigint, text, text, text[], jsonb, text, text, text, date, date, boolean) to authenticated;

-- ===================================================================================
-- EL AVISO DE LAS LICENCIAS (22/09/2026)
-- ===================================================================================
-- Se inserta por código: si este archivo se ejecuta dos veces, el aviso no se duplica
-- ni se le borran los acuses ya registrados.
insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta)
values (
  'LICENCIAS-2026-09',
  '🪪',
  'Licencias de conducción: plazo hasta el sábado 26',
  'Todos los conductores deben tener la licencia al día en el sistema.' || E'\n\n'
  || 'Cuando al despachar salga el aviso de licencia vencida o por vencer, pídele la licencia al '
  || 'conductor y sube las dos fotos: frente y respaldo. El plazo va hasta el sábado 26 de septiembre.'
  || E'\n\n'
  || 'A partir del domingo 27 el sistema bloqueará el despacho de los conductores que no la hayan presentado.',
  jsonb_build_array(
    'Hasta el SÁBADO 26: subir las fotos de la licencia de todo conductor al que le salga el aviso.',
    'Desde el DOMINGO 27: no se podrá despachar a quien no la haya presentado.',
    'Son DOS fotos: frente y respaldo. La fecha de vencimiento está en el respaldo.',
    'El botón "❓ Cómo se hace" del mismo aviso explica el paso a paso.'
  ),
  'Leí la instrucción y entiendo que desde el domingo 27 no podré despachar a un conductor sin la licencia al día.',
  'Entendido, me comprometo',
  array['despachador', 'auditor'],
  (now() at time zone 'America/Bogota')::date,
  date '2026-10-31'
)
on conflict (codigo) do update
  set titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      hasta = excluded.hasta, activo = true;
