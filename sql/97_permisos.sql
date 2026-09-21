-- ============================================================================================
-- 97) Solicitudes de permiso y licencia (formato F-GH-07)
--
-- QUÉ ES: el formato en papel "SOLICITUD PERMISOS Y/O LICENCIAS". El empleado lo radica desde un
-- link público (permisos.html), Gestión Humana y Gerencia lo aprueban en la app, y de ahí sale el
-- mismo formato impreso, ya con el estado y quién autorizó.
--
-- LO QUE SE ARREGLÓ DEL FORMATO:
--   * El papel solo tiene "FECHA Y HORA DEL PERMISO" (una sola). Así no se sabe si el permiso fue
--     de una hora o de un día, y sin eso no se puede controlar la reposición que el mismo formato
--     exige. Aquí se pide DESDE y HASTA, y las horas se calculan solas.
--   * "Descripción" y "Motivo" eran el mismo dato escrito dos veces: queda uno.
--   * Las casillas "GERENCIA:" y "GESTIÓN HUMANA:" quedaban en blanco; ahora cada una guarda
--     quién decidió, cuándo y por qué.
--
-- CÓMO SE IDENTIFICA EL EMPLEADO: cédula + fecha de nacimiento contra el perfil, igual que el
-- link de actualización de datos (sql/75). La página NO lee nada de la base: solo envía.
--
-- LOS SOPORTES van dentro de la misma solicitud (la foto se comprime en el celular antes de
-- enviarla). No se abre Storage a usuarios anónimos: un bucket con escritura pública es una
-- invitación a que suban cualquier cosa.
-- ============================================================================================

-- 1) La solicitud --------------------------------------------------------------------------------
create sequence if not exists public.permiso_radicado_seq start 1;

create table if not exists public.permisos (
  id               bigserial primary key,
  radicado         int not null unique default nextval('public.permiso_radicado_seq'),
  fecha_solicitud  date not null default (now() at time zone 'America/Bogota')::date,
  -- Del perfil, copiados al radicar: el cargo de hoy no tiene por qué ser el de dentro de un año
  cedula           text not null,
  nombre           text not null,
  cargo            text,
  area             text,
  -- Lo que llena el empleado
  tipo             text not null,
  motivo           text not null,
  reemplaza        text,
  desde            timestamp not null,
  hasta            timestamp not null,
  reposicion       boolean not null default false,
  forma_reposicion text,
  celular          text,
  -- Decisión de cada instancia
  gh_estado        text check (gh_estado in ('APROBADO', 'NEGADO')),
  gh_nota          text,
  gh_por           text,
  gh_en            timestamptz,
  ger_estado       text check (ger_estado in ('APROBADO', 'NEGADO')),
  ger_nota         text,
  ger_por          text,
  ger_en           timestamptz,
  anulado_en       timestamptz,
  anulado_por      text,
  creado_en        timestamptz not null default now(),
  -- Calculadas
  horas            numeric generated always as (
                     round(extract(epoch from (hasta - desde)) / 3600.0, 2)) stored,
  estado           text generated always as (
                     case when anulado_en is not null then 'ANULADO'
                          when gh_estado = 'NEGADO' or ger_estado = 'NEGADO' then 'NEGADO'
                          when gh_estado = 'APROBADO' and ger_estado = 'APROBADO' then 'APROBADO'
                          when gh_estado is not null or ger_estado is not null then 'EN TRAMITE'
                          else 'PENDIENTE' end) stored,
  constraint permisos_rango check (hasta > desde)
);
create index if not exists permisos_estado_idx on public.permisos (estado, desde desc);
create index if not exists permisos_cedula_idx on public.permisos (cedula, desde desc);

comment on table public.permisos is
  'Solicitudes de permiso/licencia (formato F-GH-07). Las radica el empleado en permisos.html; aprueban Gestion Humana y Gerencia.';
comment on column public.permisos.horas is 'Duracion real del permiso: el formato en papel no la tenia y por eso no se podia controlar la reposicion.';

alter table public.permisos enable row level security;
revoke all on public.permisos from public, anon;
grant select on public.permisos to authenticated;
revoke all on sequence public.permiso_radicado_seq from public, anon;

-- 2) Los soportes (incapacidad, cita, registro civil…) -------------------------------------------
create table if not exists public.permiso_soportes (
  id          bigserial primary key,
  permiso_id  bigint not null references public.permisos(id) on delete cascade,
  nombre      text,
  tipo_mime   text,
  archivo     text not null,          -- data URI ya comprimido desde el celular
  bytes       int,
  creado_en   timestamptz not null default now()
);
create index if not exists permiso_soportes_idx on public.permiso_soportes (permiso_id);
alter table public.permiso_soportes enable row level security;
revoke all on public.permiso_soportes from public, anon;
grant select on public.permiso_soportes to authenticated;
revoke all on sequence public.permiso_soportes_id_seq from public, anon;

-- 3) Quién ve y quién decide ---------------------------------------------------------------------
--    Gerencia no es un rol del sistema: son correos concretos. Se llena aparte (no va al repo).
create table if not exists public.permiso_gerencia (
  email     text primary key,
  nombre    text,
  creado_en timestamptz not null default now()
);
alter table public.permiso_gerencia enable row level security;
revoke all on public.permiso_gerencia from public, anon;

create or replace function public.es_permiso_gerencia()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_admin() or exists (
    select 1 from public.permiso_gerencia g
     where lower(g.email) = lower(coalesce(auth.email(), '')));
$$;
revoke all on function public.es_permiso_gerencia() from public, anon;
grant execute on function public.es_permiso_gerencia() to authenticated;

-- Ver: talento humano (admin + Gestión Humana) y quien esté en gerencia.
create or replace function public.es_permiso_ver()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_talento_humano() or public.es_permiso_gerencia();
$$;
revoke all on function public.es_permiso_ver() from public, anon;
grant execute on function public.es_permiso_ver() to authenticated;

drop policy if exists permisos_ver on public.permisos;
create policy permisos_ver on public.permisos
  for select to authenticated using ((select public.es_permiso_ver()));
drop policy if exists permiso_soportes_ver on public.permiso_soportes;
create policy permiso_soportes_ver on public.permiso_soportes
  for select to authenticated using ((select public.es_permiso_ver()));

-- 4) RADICAR (link público) ----------------------------------------------------------------------
--    Valida cédula + fecha de nacimiento contra el perfil. No devuelve datos de la persona:
--    solo el número de radicado. Así, poner una cédula ajena no sirve para averiguar nada.
create or replace function public.permiso_radicar(
  p_cedula text, p_fecha_nacimiento date, p_tipo text, p_motivo text,
  p_desde timestamp, p_hasta timestamp, p_reemplaza text default null,
  p_reposicion boolean default false, p_forma_reposicion text default null,
  p_celular text default null, p_soportes jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_p record; v_id bigint; v_rad int; v_n int; s jsonb;
  v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
begin
  if v_ced = '' or p_fecha_nacimiento is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu cedula y tu fecha de nacimiento.');
  end if;

  select cedula, nombre, cargo, area, estado into v_p
    from public.perfilsociodemografico
   where regexp_replace(cedula, '\D', '', 'g') = v_ced
     and fecha_nacimiento = p_fecha_nacimiento
   limit 1;
  if v_p is null then
    return jsonb_build_object('ok', false, 'error',
      'No encontramos tus datos. Revisa la cedula y la fecha de nacimiento, o avisale a Gestion Humana.');
  end if;
  if v_p.estado <> 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error',
      'Tu registro aparece inactivo. Comunicate con Gestion Humana.');
  end if;

  if coalesce(trim(p_tipo), '') = '' or coalesce(trim(p_motivo), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el tipo de permiso o el motivo.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta <= p_desde then
    return jsonb_build_object('ok', false, 'error', 'Revisa las fechas: la de regreso debe ser posterior.');
  end if;
  if p_desde < (now() at time zone 'America/Bogota') - interval '30 days'
     or p_desde > (now() at time zone 'America/Bogota') + interval '365 days' then
    return jsonb_build_object('ok', false, 'error', 'La fecha del permiso esta fuera de rango.');
  end if;

  -- Freno simple: una persona no radica 6 solicitudes el mismo día.
  select count(1) into v_n from public.permisos
   where cedula = v_p.cedula
     and creado_en > now() - interval '1 day';
  if v_n >= 5 then
    return jsonb_build_object('ok', false, 'error',
      'Ya radicaste varias solicitudes hoy. Comunicate con Gestion Humana.');
  end if;

  insert into public.permisos
    (cedula, nombre, cargo, area, tipo, motivo, reemplaza, desde, hasta,
     reposicion, forma_reposicion, celular)
  values (v_p.cedula, v_p.nombre, v_p.cargo, v_p.area, upper(trim(p_tipo)), trim(p_motivo),
          nullif(trim(coalesce(p_reemplaza, '')), ''), p_desde, p_hasta,
          coalesce(p_reposicion, false), nullif(trim(coalesce(p_forma_reposicion, '')), ''),
          regexp_replace(coalesce(p_celular, ''), '\D', '', 'g'))
  returning id, radicado into v_id, v_rad;

  -- Soportes: máximo 3, y cada uno hasta ~1,5 MB ya codificado.
  for s in select * from jsonb_array_elements(coalesce(p_soportes, '[]'::jsonb)) limit 3 loop
    if length(coalesce(s->>'archivo', '')) between 100 and 2000000 then
      insert into public.permiso_soportes (permiso_id, nombre, tipo_mime, archivo, bytes)
      values (v_id, left(coalesce(s->>'nombre', 'soporte'), 120), s->>'tipo_mime',
              s->>'archivo', length(s->>'archivo'));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'radicado', v_rad);
end $$;
revoke all on function public.permiso_radicar(text, date, text, text, timestamp, timestamp, text, boolean, text, text, jsonb)
  from public;
grant execute on function public.permiso_radicar(text, date, text, text, timestamp, timestamp, text, boolean, text, text, jsonb)
  to anon, authenticated;

-- 5) DECIDIR (Gestión Humana y Gerencia) ----------------------------------------------------------
create or replace function public.permiso_decidir(
  p_id bigint, p_instancia text, p_estado text, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if p_estado not in ('APROBADO', 'NEGADO') then
    return jsonb_build_object('ok', false, 'error', 'Decision no valida.');
  end if;
  if p_instancia = 'GH' then
    if not public.es_talento_humano() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gestion Humana.');
    end if;
    update public.permisos set gh_estado = p_estado, gh_nota = nullif(trim(coalesce(p_nota, '')), ''),
           gh_por = v_yo, gh_en = now()
     where id = p_id and anulado_en is null;
  elsif p_instancia = 'GERENCIA' then
    if not public.es_permiso_gerencia() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gerencia.');
    end if;
    update public.permisos set ger_estado = p_estado, ger_nota = nullif(trim(coalesce(p_nota, '')), ''),
           ger_por = v_yo, ger_en = now()
     where id = p_id and anulado_en is null;
  else
    return jsonb_build_object('ok', false, 'error', 'Instancia no valida.');
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No se encontro la solicitud (o esta anulada).');
  end if;
  return (select jsonb_build_object('ok', true, 'estado', p.estado) from public.permisos p where p.id = p_id);
end $$;
revoke all on function public.permiso_decidir(bigint, text, text, text) from public, anon;
grant execute on function public.permiso_decidir(bigint, text, text, text) to authenticated;

-- Anular: para la solicitud radicada por error. No se borra, queda el rastro.
create or replace function public.permiso_anular(p_id bigint, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Solo Gestion Humana anula una solicitud.');
  end if;
  update public.permisos
     set anulado_en = now(), anulado_por = v_yo,
         gh_nota = coalesce(nullif(trim(coalesce(p_nota, '')), ''), gh_nota)
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontro o ya estaba anulada.'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.permiso_anular(bigint, text) from public, anon;
grant execute on function public.permiso_anular(bigint, text) to authenticated;

-- 6) Lo que necesita la pantalla -------------------------------------------------------------------
create or replace function public.permisos_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_permiso_ver() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'es_gh', public.es_talento_humano(),
      'es_gerencia', public.es_permiso_gerencia(),
      'pendientes', (select count(1) from public.permisos where estado in ('PENDIENTE', 'EN TRAMITE')),
      -- lo que le falta decidir a QUIEN esta mirando
      'mios', (select count(1) from public.permisos p
                where p.anulado_en is null
                  and ((public.es_talento_humano() and p.gh_estado is null)
                    or (public.es_permiso_gerencia() and p.ger_estado is null))),
      'total', (select count(1) from public.permisos))
  end;
$$;
revoke all on function public.permisos_estado() from public, anon;
grant execute on function public.permisos_estado() to authenticated;

-- Los soportes de una solicitud (pesan: se piden solo al abrir la ficha).
create or replace function public.permiso_soportes_de(p_id bigint)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_permiso_ver() then '[]'::jsonb
    else (select coalesce(jsonb_agg(jsonb_build_object(
            'id', s.id, 'nombre', s.nombre, 'tipo_mime', s.tipo_mime,
            'archivo', s.archivo, 'bytes', s.bytes) order by s.id), '[]'::jsonb)
          from public.permiso_soportes s where s.permiso_id = p_id)
  end;
$$;
revoke all on function public.permiso_soportes_de(bigint) from public, anon;
grant execute on function public.permiso_soportes_de(bigint) to authenticated;

-- 7) El consecutivo arranca donde va el papel ------------------------------------------------------
--    El último radicado en físico fue el 388, así que el primero de la app debe ser el 389.
select setval('public.permiso_radicado_seq', 388, true)
 where not exists (select 1 from public.permisos);

-- 8) QUIÉN ES GERENCIA: va en sql/local/ (correos, no pueden ir al repositorio público)
--    insert into public.permiso_gerencia (email, nombre) values ('<correo>', '<nombre>')
--      on conflict (email) do nothing;
