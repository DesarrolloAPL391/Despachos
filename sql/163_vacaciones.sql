-- ============================================================================================
-- 163) Solicitud de vacaciones (formato FO-GH-82 v2)
--
-- QUÉ ES: el formato en papel "SOLICITUD DE VACACIONES", convertido en flujo, igual que los
-- permisos (sql/97):
--   * El empleado la radica desde un link público (vacaciones.html) con su cédula y su fecha de
--     nacimiento, y Talento Humano también la puede registrar desde la app (cuando la pide el
--     afiliado o la empresa).
--   * Aprueban en la app Gestión Humana y Gerencia, y Nómina marca "recibido". El afiliado, el jefe
--     inmediato y el coordinador de ruta firman sobre el formato impreso que sale de la app.
--   * Gerencia autoriza a conductores APL, despachadores y administrativos; a los conductores de
--     afiliados los autoriza su afiliado (así lo dice la nota del formato). `req_gerencia` guarda
--     cuál de los dos casos es, y si algún día Gerencia firma todas se cambia solo eso.
--
-- LO QUE EL PAPEL NO HACÍA:
--   * La fecha de culminación se escribía a mano. Aquí se calcula contando días HÁBILES: sin
--     domingos ni festivos (es_festivo), y el sábado cuenta solo para quien trabaja ese día
--     (conductores y despachadores). También se dice qué día regresa a trabajar.
--   * Nombre, cédula, cargo, área, código, vehículo y afiliado salen del Perfil, no se escriben.
--   * El período se elige de los que ha cumplido según su fecha de ingreso.
--   * Las notas del formato (8 días mínimo, 15 días de anticipación…) se avisan al radicar y le
--     quedan marcadas a Gestión Humana, pero no bloquean: ellos deciden.
--   * El empleado consulta en el mismo link cómo va su solicitud.
-- ============================================================================================

-- 1) La solicitud --------------------------------------------------------------------------------
create sequence if not exists public.vacaciones_radicado_seq start 1;

create table if not exists public.vacaciones (
  id               bigserial primary key,
  radicado         int not null unique default nextval('public.vacaciones_radicado_seq'),
  fecha_solicitud  date not null default (now() at time zone 'America/Bogota')::date,
  -- Del perfil, copiados al radicar (el cargo de hoy no tiene por qué ser el de dentro de un año)
  cedula           text not null,
  nombre           text not null,
  cargo            text,
  area             text,
  tipo_personal    text,              -- CONDUCTOR / ADMINISTRATIVO
  codigo           text,
  vehiculo         text,              -- número interno, por la placa del perfil
  afiliado         text,              -- propietario del vehículo, si no es de la empresa
  flota_propia     boolean,
  req_gerencia     boolean not null default true,
  -- Lo que se pide
  periodo          text not null,
  fecha_inicio     date,
  dias_disfrute    int not null default 0 check (dias_disfrute between 0 and 30),
  dias_dinero      int not null default 0 check (dias_dinero between 0 and 15),
  fecha_fin        date,
  fecha_regreso    date,
  sabado_habil     boolean not null default false,
  festivos         jsonb not null default '[]'::jsonb,   -- festivos que caen dentro (no cuentan)
  reemplaza        text,
  solicitada_por   text not null default 'EMPLEADO' check (solicitada_por in ('EMPLEADO', 'AFILIADO', 'EMPRESA')),
  origen           text not null default 'LINK' check (origen in ('LINK', 'APP')),
  registrada_por   text,
  celular          text,
  observacion      text,
  anticipacion     int,               -- días entre la solicitud y el inicio
  alertas          text[] not null default '{}',
  -- Decisión de cada instancia
  gh_estado        text check (gh_estado in ('APROBADO', 'NEGADO')),
  gh_nota          text,
  gh_por           text,
  gh_en            timestamptz,
  ger_estado       text check (ger_estado in ('APROBADO', 'NEGADO')),
  ger_nota         text,
  ger_por          text,
  ger_en           timestamptz,
  nom_por          text,
  nom_en           timestamptz,
  nom_nota         text,
  anulado_en       timestamptz,
  anulado_por      text,
  creado_en        timestamptz not null default now(),
  estado           text generated always as (
                     case when anulado_en is not null then 'ANULADO'
                          when gh_estado = 'NEGADO' or ger_estado = 'NEGADO' then 'NEGADO'
                          when gh_estado = 'APROBADO' and (ger_estado = 'APROBADO' or not req_gerencia) then 'APROBADO'
                          when gh_estado is not null or ger_estado is not null then 'EN TRAMITE'
                          else 'PENDIENTE' end) stored,
  constraint vacaciones_dias check (dias_disfrute + dias_dinero > 0),
  constraint vacaciones_fechas check (dias_disfrute = 0 or (fecha_inicio is not null and fecha_fin is not null))
);
create index if not exists vacaciones_estado_idx on public.vacaciones (estado, fecha_inicio desc);
create index if not exists vacaciones_cedula_idx on public.vacaciones (cedula, fecha_inicio desc);

comment on table public.vacaciones is
  'Solicitudes de vacaciones (formato FO-GH-82). Las radica el empleado en vacaciones.html o Talento Humano en la app; aprueban Gestion Humana y Gerencia y Nomina marca recibido.';

alter table public.vacaciones enable row level security;
revoke all on public.vacaciones from public, anon;
grant select on public.vacaciones to authenticated;
revoke all on sequence public.vacaciones_radicado_seq from public, anon;

-- Intentos de identificarse en el link: cédula + fecha de nacimiento se podría adivinar a fuerza
-- de probar fechas, así que después de 8 fallos en una hora esa cédula espera.
create table if not exists public.vacaciones_intentos (
  id     bigserial primary key,
  cedula text not null,
  ok     boolean not null,
  en     timestamptz not null default now()
);
create index if not exists vacaciones_intentos_idx on public.vacaciones_intentos (cedula, en desc);
alter table public.vacaciones_intentos enable row level security;
revoke all on public.vacaciones_intentos from public, anon, authenticated;

-- 2) Quién ve y quién decide ---------------------------------------------------------------------
--    Gerencia es la misma lista de los permisos (permiso_gerencia). Nómina son correos concretos:
--    se llenan aparte (sql/local), no van al repositorio. Mientras no haya, marca administración.
create table if not exists public.vacaciones_nomina (
  email     text primary key,
  nombre    text,
  creado_en timestamptz not null default now()
);
alter table public.vacaciones_nomina enable row level security;
revoke all on public.vacaciones_nomina from public, anon;

create or replace function public.es_vac_nomina()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_admin() or exists (
    select 1 from public.vacaciones_nomina n where lower(n.email) = lower(coalesce(auth.email(), '')));
$$;
revoke all on function public.es_vac_nomina() from public, anon;
grant execute on function public.es_vac_nomina() to authenticated;

create or replace function public.es_vac_ver()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_talento_humano() or public.es_permiso_gerencia() or public.es_vac_nomina();
$$;
revoke all on function public.es_vac_ver() from public, anon;
grant execute on function public.es_vac_ver() to authenticated;

drop policy if exists vacaciones_ver on public.vacaciones;
create policy vacaciones_ver on public.vacaciones
  for select to authenticated using ((select public.es_vac_ver()));

-- 3) Las fechas: días hábiles, sin domingos ni festivos; el sábado según quién ----------------
--    Pública porque es solo un cálculo: la página lo usa para mostrar la fecha antes de enviar.
create or replace function public.vacaciones_fechas(p_inicio date, p_dias int, p_sabado boolean)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  d date := p_inicio; n int := 0; v_fin date; v_fest jsonb := '[]'::jsonb;
  v_sab boolean := coalesce(p_sabado, false);
begin
  if p_inicio is null or coalesce(p_dias, 0) < 1 or p_dias > 60 then
    return jsonb_build_object('ok', false);
  end if;
  loop
    if extract(dow from d) = 0 or (extract(dow from d) = 6 and not v_sab) then
      null;                                            -- no es hábil para esta persona
    elsif public.es_festivo(d) then
      v_fest := v_fest || to_jsonb(d);                 -- festivo: no cuenta, pero se dice
    else
      n := n + 1;
      if n = p_dias then v_fin := d; exit; end if;
    end if;
    d := d + 1;
  end loop;
  -- Regresa el siguiente día hábil.
  d := v_fin + 1;
  while extract(dow from d) = 0 or (extract(dow from d) = 6 and not v_sab) or public.es_festivo(d) loop
    d := d + 1;
  end loop;
  return jsonb_build_object('ok', true, 'fin', v_fin, 'regreso', d, 'festivos', v_fest,
                            'calendario', v_fin - p_inicio + 1);
end $$;
revoke all on function public.vacaciones_fechas(date, int, boolean) from public;
grant execute on function public.vacaciones_fechas(date, int, boolean) to anon, authenticated;

-- 4) Lo que se sabe de la persona (interno) ------------------------------------------------------
--    El sábado es hábil para quien lo trabaja: conductores y despachadores.
create or replace function public._vac_sabado(p_tipo text, p_cargo text)
returns boolean
language sql immutable
as $$ select coalesce(p_tipo, '') = 'CONDUCTOR' or coalesce(p_cargo, '') ~* 'despach' $$;
revoke all on function public._vac_sabado(text, text) from public, anon, authenticated;

-- Períodos según la fecha de ingreso: los tres últimos cumplidos y el que va corriendo.
create or replace function public._vac_periodos(p_cedula text, p_ingreso date)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with hoy as (select (now() at time zone 'America/Bogota')::date d),
  p as (
    select (p_ingreso + make_interval(years => k))::date desde,
           ((p_ingreso + make_interval(years => k + 1))::date - 1) hasta
      from generate_series(0, greatest(0, extract(year from age((select d from hoy), p_ingreso))::int)) k
     where p_ingreso is not null),
  t as (
    select desde, hasta, hasta < (select d from hoy) cumplido,
           to_char(desde, 'DD/MM/YYYY') || ' al ' || to_char(hasta, 'DD/MM/YYYY') texto
      from p where desde <= (select d from hoy))
  select coalesce(jsonb_agg(jsonb_build_object(
           'texto', texto, 'desde', desde, 'hasta', hasta, 'cumplido', cumplido,
           'solicitado', exists (select 1 from public.vacaciones v
                                  where v.cedula = p_cedula and v.periodo = t.texto
                                    and v.estado not in ('ANULADO', 'NEGADO')))
         order by desde desc), '[]'::jsonb)
    from (select * from t order by desde desc limit 4) t;
$$;
revoke all on function public._vac_periodos(text, date) from public, anon, authenticated;

-- La persona tal como sale del perfil, con su vehículo y si es de afiliado.
create or replace function public._vac_persona(p_cedula text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'cedula', p.cedula, 'nombre', p.nombre, 'cargo', p.cargo, 'area', p.area, 'tipo', p.tipo,
    'estado', p.estado, 'codigo', p.codigo, 'fecha_ingreso', p.fecha_ingreso,
    'vehiculo', (select v.numero from public.vehiculos v
                  where nullif(p.placa, '') is not null
                    and upper(replace(v.placa, ' ', '')) = upper(replace(p.placa, ' ', '')) limit 1),
    -- Afiliado solo para conductores de un carro que no es de la empresa.
    'flota_propia', case when nullif(p.nombre_propietario, '') is null then null
                         else p.nombre_propietario ~* 'poblado\s*laureles' end,
    'afiliado', case when p.tipo = 'CONDUCTOR' and nullif(p.nombre_propietario, '') is not null
                      and p.nombre_propietario !~* 'poblado\s*laureles' then p.nombre_propietario end,
    'sabado_habil', public._vac_sabado(p.tipo, p.cargo),
    'periodos', public._vac_periodos(p.cedula, p.fecha_ingreso))
  from public.perfilsociodemografico p
  where p.cedula = p_cedula;
$$;
revoke all on function public._vac_persona(text) from public, anon, authenticated;

-- Identificarse en el link: cédula + fecha de nacimiento, con freno a los que prueban fechas.
create or replace function public._vac_identificar(p_cedula text, p_fnac date)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_ced text := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g'); v_real text; v_n int;
begin
  if v_ced = '' or p_fnac is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu cédula y tu fecha de nacimiento.');
  end if;
  select count(1) into v_n from public.vacaciones_intentos
   where cedula = v_ced and not ok and en > now() - interval '1 hour';
  if v_n >= 8 then
    return jsonb_build_object('ok', false, 'error',
      'Hubo demasiados intentos con esta cédula. Espera una hora o comunícate con Gestión Humana.');
  end if;
  select cedula into v_real from public.perfilsociodemografico
   where regexp_replace(cedula, '\D', '', 'g') = v_ced and fecha_nacimiento = p_fnac limit 1;
  insert into public.vacaciones_intentos (cedula, ok) values (v_ced, v_real is not null);
  if v_real is null then
    return jsonb_build_object('ok', false, 'error',
      'No encontramos tus datos. Revisa la cédula y la fecha de nacimiento, o avísale a Gestión Humana.');
  end if;
  return jsonb_build_object('ok', true, 'cedula', v_real);
end $$;
revoke all on function public._vac_identificar(text, date) from public, anon, authenticated;

-- 5) Crear la solicitud (interno: lo usan el link y la app) --------------------------------------
create or replace function public._vac_crear(
  p_cedula text, p_periodo text, p_inicio date, p_disfrute int, p_dinero int, p_reemplaza text,
  p_solicitada_por text, p_sabado boolean, p_celular text, p_observacion text,
  p_origen text, p_por text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_p jsonb := public._vac_persona(p_cedula);
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_dis int := coalesce(p_disfrute, 0);
  v_din int := coalesce(p_dinero, 0);
  v_sab boolean;
  v_f jsonb := jsonb_build_object('ok', false);
  v_al text[] := '{}';
  v_per jsonb;
  v_otro int;
  v_id bigint; v_rad int; v_n int;
begin
  if v_p is null then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no está en el Perfil.');
  end if;
  if v_p->>'estado' <> 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error', 'El registro aparece inactivo. Comunícate con Gestión Humana.');
  end if;
  if coalesce(trim(p_periodo), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Elige el período de vacaciones.');
  end if;
  if v_dis < 0 or v_dis > 30 or v_din < 0 or v_din > 15 or v_dis + v_din = 0 then
    return jsonb_build_object('ok', false, 'error', 'Revisa los días: de disfrute (0 a 30) y en dinero (0 a 15).');
  end if;
  if coalesce(p_solicitada_por, 'EMPLEADO') not in ('EMPLEADO', 'AFILIADO', 'EMPRESA') then
    return jsonb_build_object('ok', false, 'error', 'Quién la solicita no es válido.');
  end if;

  v_sab := coalesce(p_sabado, (v_p->>'sabado_habil')::boolean, false);
  if v_dis > 0 then
    if p_inicio is null then
      return jsonb_build_object('ok', false, 'error', 'Falta la fecha en que empiezan las vacaciones.');
    end if;
    if p_origen = 'LINK' and p_inicio <= v_hoy then
      return jsonb_build_object('ok', false, 'error', 'La fecha de inicio debe ser posterior a hoy.');
    end if;
    if p_inicio < v_hoy - 180 or p_inicio > v_hoy + 365 then
      return jsonb_build_object('ok', false, 'error', 'La fecha de inicio está fuera de rango.');
    end if;
    v_f := public.vacaciones_fechas(p_inicio, v_dis, v_sab);

    -- Dos solicitudes vivas de la misma persona no se pueden cruzar.
    select radicado into v_otro from public.vacaciones v
     where v.cedula = v_p->>'cedula' and v.estado not in ('ANULADO', 'NEGADO')
       and v.fecha_inicio is not null
       and daterange(v.fecha_inicio, v.fecha_fin, '[]') && daterange(p_inicio, (v_f->>'fin')::date, '[]')
     limit 1;
    if v_otro is not null then
      return jsonb_build_object('ok', false, 'error',
        'Ya hay una solicitud de vacaciones que se cruza con esas fechas (radicado # ' || v_otro || ').');
    end if;
  end if;

  -- Freno simple para el link: una persona no radica más de 3 el mismo día.
  if p_origen = 'LINK' then
    select count(1) into v_n from public.vacaciones
     where cedula = v_p->>'cedula' and creado_en > now() - interval '1 day';
    if v_n >= 3 then
      return jsonb_build_object('ok', false, 'error', 'Ya radicaste varias solicitudes hoy. Comunícate con Gestión Humana.');
    end if;
  end if;

  -- Lo que dicen las notas del formato: se marca para Gestión Humana, no bloquea.
  if v_dis > 0 and p_inicio - v_hoy < 15 then v_al := array_append(v_al, 'ANTICIPACION'); end if;
  if v_dis between 1 and 7 then v_al := array_append(v_al, 'MENOS_8'); end if;
  if v_din > 7 then v_al := array_append(v_al, 'DINERO_MAS_7'); end if;
  if v_dis + v_din > 15 then v_al := array_append(v_al, 'MAS_15'); end if;
  select e.value into v_per from jsonb_array_elements(v_p->'periodos') e where e.value->>'texto' = trim(p_periodo);
  if v_per is not null and not (v_per->>'cumplido')::boolean then v_al := array_append(v_al, 'PERIODO_EN_CURSO'); end if;
  if exists (select 1 from public.vacaciones v where v.cedula = v_p->>'cedula' and v.periodo = trim(p_periodo)
               and v.estado not in ('ANULADO', 'NEGADO')) then
    v_al := array_append(v_al, 'PERIODO_REPETIDO');
  end if;

  insert into public.vacaciones
    (cedula, nombre, cargo, area, tipo_personal, codigo, vehiculo, afiliado, flota_propia, req_gerencia,
     periodo, fecha_inicio, dias_disfrute, dias_dinero, fecha_fin, fecha_regreso, sabado_habil, festivos,
     reemplaza, solicitada_por, origen, registrada_por, celular, observacion, anticipacion, alertas)
  values
    (v_p->>'cedula', v_p->>'nombre', v_p->>'cargo', v_p->>'area', v_p->>'tipo', v_p->>'codigo',
     v_p->>'vehiculo', v_p->>'afiliado', (v_p->>'flota_propia')::boolean,
     -- Al conductor de un afiliado lo autoriza el afiliado, no Gerencia (nota del formato).
     not (v_p->>'tipo' = 'CONDUCTOR' and (v_p->>'flota_propia')::boolean is false),
     trim(p_periodo), case when v_dis > 0 then p_inicio end, v_dis, v_din,
     (v_f->>'fin')::date, (v_f->>'regreso')::date, v_sab, coalesce(v_f->'festivos', '[]'::jsonb),
     nullif(trim(coalesce(p_reemplaza, '')), ''), coalesce(p_solicitada_por, 'EMPLEADO'), p_origen, p_por,
     nullif(regexp_replace(coalesce(p_celular, ''), '\D', '', 'g'), ''),
     nullif(trim(coalesce(p_observacion, '')), ''),
     case when v_dis > 0 then p_inicio - v_hoy end, v_al)
  returning id, radicado into v_id, v_rad;

  return jsonb_build_object('ok', true, 'id', v_id, 'radicado', v_rad, 'fin', v_f->'fin',
                            'regreso', v_f->'regreso', 'alertas', to_jsonb(v_al));
end $$;
revoke all on function public._vac_crear(text, text, date, int, int, text, text, boolean, text, text, text, text)
  from public, anon, authenticated;

-- 6) El link público ------------------------------------------------------------------------------
-- Identificarse: devuelve lo justo para llenar el formulario y sus solicitudes anteriores.
-- No devuelve la cédula completa, ni el salario, ni el nombre del afiliado.
create or replace function public.vacaciones_identificar(p_cedula text, p_fecha_nacimiento date)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento); v_p jsonb;
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  v_p := public._vac_persona(v_id->>'cedula');
  if v_p->>'estado' <> 'ACTIVO' then
    return jsonb_build_object('ok', false, 'error', 'Tu registro aparece inactivo. Comunícate con Gestión Humana.');
  end if;
  return jsonb_build_object('ok', true,
    -- Nombre de pila: en Colombia van primero los dos apellidos.
    'nombre', initcap(lower(coalesce(nullif(array_to_string(
                (regexp_split_to_array(trim(v_p->>'nombre'), '\s+'))[3:], ' '), ''), v_p->>'nombre'))),
    'cargo', v_p->>'cargo', 'tipo', v_p->>'tipo', 'sabado_habil', v_p->'sabado_habil',
    'tiene_afiliado', v_p->>'afiliado' is not null, 'periodos', v_p->'periodos',
    'solicitudes', (select coalesce(jsonb_agg(jsonb_build_object(
        'radicado', v.radicado, 'periodo', v.periodo, 'inicio', v.fecha_inicio, 'fin', v.fecha_fin,
        'regreso', v.fecha_regreso, 'disfrute', v.dias_disfrute, 'dinero', v.dias_dinero,
        'estado', v.estado, 'nomina', v.nom_en is not null,
        'nota', case when v.estado = 'NEGADO' then coalesce(v.gh_nota, v.ger_nota) end)
        order by v.creado_en desc), '[]'::jsonb)
      from (select * from public.vacaciones where cedula = v_id->>'cedula' order by creado_en desc limit 6) v));
end $$;
revoke all on function public.vacaciones_identificar(text, date) from public;
grant execute on function public.vacaciones_identificar(text, date) to anon, authenticated;

create or replace function public.vacaciones_radicar(
  p_cedula text, p_fecha_nacimiento date, p_periodo text, p_inicio date,
  p_dias_disfrute int, p_dias_dinero int, p_reemplaza text default null,
  p_solicitada_por text default 'EMPLEADO', p_celular text default null, p_observacion text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento); v_r jsonb;
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  v_r := public._vac_crear(v_id->>'cedula', p_periodo, p_inicio, p_dias_disfrute, p_dias_dinero,
                           left(p_reemplaza, 120), p_solicitada_por, null, p_celular,
                           left(p_observacion, 400), 'LINK', null);
  return v_r - 'id';
end $$;
revoke all on function public.vacaciones_radicar(text, date, text, date, int, int, text, text, text, text) from public;
grant execute on function public.vacaciones_radicar(text, date, text, date, int, int, text, text, text, text)
  to anon, authenticated;

-- 7) Talento Humano en la app: buscar a la persona y registrar ---------------------------------
create or replace function public.vacaciones_persona(p_cedula text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_p jsonb;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Solo Talento Humano registra vacaciones.');
  end if;
  v_p := public._vac_persona(regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g'));
  if v_p is null then return jsonb_build_object('ok', false, 'error', 'Esa cédula no está en el Perfil.'); end if;
  return v_p || jsonb_build_object('ok', true);
end $$;
revoke all on function public.vacaciones_persona(text) from public, anon;
grant execute on function public.vacaciones_persona(text) to authenticated;

create or replace function public.vacaciones_registrar(
  p_cedula text, p_periodo text, p_inicio date, p_dias_disfrute int, p_dias_dinero int,
  p_reemplaza text, p_solicitada_por text, p_sabado_habil boolean, p_observacion text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Solo Talento Humano registra vacaciones.');
  end if;
  return public._vac_crear(regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g'), p_periodo, p_inicio,
    p_dias_disfrute, p_dias_dinero, left(p_reemplaza, 120), p_solicitada_por, p_sabado_habil, null,
    left(p_observacion, 400), 'APP', lower(coalesce(auth.email(), '')));
end $$;
revoke all on function public.vacaciones_registrar(text, text, date, int, int, text, text, boolean, text) from public, anon;
grant execute on function public.vacaciones_registrar(text, text, date, int, int, text, text, boolean, text) to authenticated;

-- 8) Decidir, recibir en nómina, anular ----------------------------------------------------------
create or replace function public.vacaciones_decidir(
  p_id bigint, p_instancia text, p_estado text, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), '')); v_nota text := nullif(trim(coalesce(p_nota, '')), '');
begin
  if p_estado not in ('APROBADO', 'NEGADO') then
    return jsonb_build_object('ok', false, 'error', 'Decisión no válida.');
  end if;
  -- Negar sin decir por qué deja a la persona sin saber qué cambiar.
  if p_estado = 'NEGADO' and v_nota is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se niega: la persona lo ve al consultar.');
  end if;
  if p_instancia = 'GH' then
    if not public.es_talento_humano() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gestión Humana.');
    end if;
    update public.vacaciones set gh_estado = p_estado, gh_nota = v_nota, gh_por = v_yo, gh_en = now()
     where id = p_id and anulado_en is null and nom_en is null;
  elsif p_instancia = 'GERENCIA' then
    if not public.es_permiso_gerencia() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gerencia.');
    end if;
    update public.vacaciones set ger_estado = p_estado, ger_nota = v_nota, ger_por = v_yo, ger_en = now()
     where id = p_id and anulado_en is null and nom_en is null and req_gerencia;
  else
    return jsonb_build_object('ok', false, 'error', 'Instancia no válida.');
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No se puede: la solicitud no existe, está anulada o ya la recibió Nómina.');
  end if;
  return (select jsonb_build_object('ok', true, 'estado', v.estado) from public.vacaciones v where v.id = p_id);
end $$;
revoke all on function public.vacaciones_decidir(bigint, text, text, text) from public, anon;
grant execute on function public.vacaciones_decidir(bigint, text, text, text) to authenticated;

create or replace function public.vacaciones_nomina_recibir(p_id bigint, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_vac_nomina() then
    return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Nómina.');
  end if;
  update public.vacaciones
     set nom_por = lower(coalesce(auth.email(), '')), nom_en = now(),
         nom_nota = nullif(trim(coalesce(p_nota, '')), '')
   where id = p_id and estado = 'APROBADO' and nom_en is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Solo se recibe una solicitud aprobada que Nómina no haya recibido.');
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.vacaciones_nomina_recibir(bigint, text) from public, anon;
grant execute on function public.vacaciones_nomina_recibir(bigint, text) to authenticated;

create or replace function public.vacaciones_anular(p_id bigint, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'Solo Gestión Humana anula una solicitud.');
  end if;
  update public.vacaciones
     set anulado_en = now(), anulado_por = lower(coalesce(auth.email(), '')),
         gh_nota = coalesce(nullif(trim(coalesce(p_nota, '')), ''), gh_nota)
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'No se encontró o ya estaba anulada.'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.vacaciones_anular(bigint, text) from public, anon;
grant execute on function public.vacaciones_anular(bigint, text) to authenticated;

-- 9) Lo que necesita el menú --------------------------------------------------------------------
create or replace function public.vacaciones_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_vac_ver() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'es_gh', public.es_talento_humano(),
      'es_gerencia', public.es_permiso_gerencia(),
      'es_nomina', public.es_vac_nomina(),
      -- lo que le falta hacer a QUIEN está mirando
      'mios', (select count(1) from public.vacaciones v
                where v.anulado_en is null and v.estado not in ('NEGADO')
                  and ((public.es_talento_humano() and v.gh_estado is null)
                    or (public.es_permiso_gerencia() and v.req_gerencia and v.ger_estado is null)
                    or (public.es_vac_nomina() and v.estado = 'APROBADO' and v.nom_en is null))),
      'total', (select count(1) from public.vacaciones))
  end;
$$;
revoke all on function public.vacaciones_estado() from public, anon;
grant execute on function public.vacaciones_estado() to authenticated;

-- 10) QUIÉN ES NÓMINA: va en sql/local/ (correos, no pueden ir al repositorio público)
--     insert into public.vacaciones_nomina (email, nombre) values ('<correo>', '<nombre>')
--       on conflict (email) do nothing;
