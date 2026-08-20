-- 43: Rol AFILIADO (dueño de vehículos). Se le crea usuario+contraseña; ve SOLO sus vehículos
-- en el mapa y puede consultar pasajeros SOLO de sus móviles. Nada más.
--
-- Piezas: tabla afiliado_vehiculos (dueño→vehículos, por correo), helpers es_afiliado()/
-- mis_moviles_afiliado(), en_horario() deja pasar al afiliado, admin_crear_usuario acepta
-- 'afiliado', mi_contexto rama afiliado, RLS de ubicaciones para el afiliado, y RPCs para que
-- el admin asigne/liste vehículos por afiliado.

-- ---- 0) Permitir el rol 'afiliado' en perfiles ----
alter table public.perfiles drop constraint if exists perfiles_rol_check;
alter table public.perfiles add constraint perfiles_rol_check
  check (rol = any (array['admin','despachador','auditor','afiliado']));

-- ---- 1) Asignación dueño→vehículos (por correo del afiliado, como los auditores) ----
create table if not exists public.afiliado_vehiculos (
  afiliado_email text   not null,
  vehiculo_id    bigint not null references public.vehiculos(id) on delete cascade,
  creado         timestamptz not null default now(),
  primary key (afiliado_email, vehiculo_id)
);
create index if not exists afiliado_vehiculos_email_idx on public.afiliado_vehiculos (lower(afiliado_email));
alter table public.afiliado_vehiculos enable row level security;
drop policy if exists afiliado_vehiculos_sel on public.afiliado_vehiculos;
create policy afiliado_vehiculos_sel on public.afiliado_vehiculos for select to authenticated
  using (public.es_admin() or lower(afiliado_email) = lower(auth.email()));
-- escritura solo por el admin (además los RPC son SECURITY DEFINER con guarda es_admin)
drop policy if exists afiliado_vehiculos_admin on public.afiliado_vehiculos;
create policy afiliado_vehiculos_admin on public.afiliado_vehiculos for all to authenticated
  using (public.es_admin()) with check (public.es_admin());

-- ---- 2) Helpers ----
create or replace function public.es_afiliado()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and rol = 'afiliado' and activo);
$$;

-- Números de móvil (vehiculos.numero) que pertenecen al afiliado logueado.
create or replace function public.mis_moviles_afiliado()
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct trim(v.numero)), '{}')
  from public.afiliado_vehiculos av
  join public.vehiculos v on v.id = av.vehiculo_id
  where lower(trim(av.afiliado_email)) = lower(trim(auth.email()));
$$;
grant execute on function public.es_afiliado() to authenticated;
grant execute on function public.mis_moviles_afiliado() to authenticated;

-- ---- 3) en_horario(): el afiliado siempre pasa (no tiene turno, como admin/auditor) ----
create or replace function public.en_horario()
returns boolean language plpgsql stable security definer set search_path = public as $function$
declare
  v_rol   text;
  v_now   time := (now() at time zone 'America/Bogota')::time;
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_email text := auth.jwt() ->> 'email';
  r record;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin', 'auditor', 'afiliado') then
    return true;
  end if;
  for r in
    select hora_inicio, hora_fin from public.horarios
    where lower(email) = lower(v_email) and fecha = v_today
  loop
    if r.hora_inicio is null or r.hora_fin is null then continue; end if;
    if r.hora_fin >= r.hora_inicio then
      if v_now between r.hora_inicio and r.hora_fin then return true; end if;
    else
      if v_now >= r.hora_inicio or v_now <= r.hora_fin then return true; end if;
    end if;
  end loop;
  return false;
end;
$function$;

-- ---- 4) admin_crear_usuario(): acepta el rol 'afiliado' ----
create or replace function public.admin_crear_usuario(p_email text, p_nombre text, p_pass text, p_rol text default 'despachador')
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $function$
declare v_id uuid; v_rol text := lower(trim(coalesce(p_rol,'despachador')));
begin
  if not public.es_admin() then return jsonb_build_object('ok',false,'error','No autorizado'); end if;
  if v_rol not in ('admin','despachador','auditor','afiliado') then
    return jsonb_build_object('ok',false,'error','Rol invalido (admin/despachador/auditor/afiliado)'); end if;
  if coalesce(trim(p_email),'')='' or coalesce(p_pass,'')='' then
    return jsonb_build_object('ok',false,'error','Correo y contrasena requeridos'); end if;
  v_id := public._crear_login(lower(trim(p_email)), p_pass, p_nombre);
  insert into public.perfiles(id,email,nombre,rol,activo)
    values (v_id, lower(trim(p_email)), p_nombre, v_rol, true)
    on conflict (id) do update set nombre=coalesce(excluded.nombre,perfiles.nombre), rol=v_rol, activo=true;
  if v_rol = 'auditor' then
    insert into public.auditores(nombre)
      select lower(trim(p_email))
      where not exists (select 1 from public.auditores where lower(trim(nombre))=lower(trim(p_email)));
  end if;
  return jsonb_build_object('ok',true,'id',v_id,'rol',v_rol);
end $function$;

-- ---- 5) RLS de ubicaciones: el afiliado ve SOLO sus móviles ----
drop policy if exists ubicaciones_select on public.ubicaciones;
create policy ubicaciones_select on public.ubicaciones for select
  using (
    public.es_admin()
    or (lower(trim(coalesce(ruta, ''))) = any (public.mis_ruta_nombres()))
    or (public.es_afiliado() and trim(movil) = any (public.mis_moviles_afiliado()))
  );

-- ---- 6) RPCs de administración de afiliados (solo admin) ----
-- Reemplaza el set de vehículos de un afiliado.
create or replace function public.afiliado_asignar_vehiculos(p_email text, p_vehiculo_ids bigint[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.es_admin() then raise exception 'Solo un administrador.'; end if;
  if nullif(trim(p_email),'') is null then return jsonb_build_object('ok',false,'error','Correo vacío'); end if;
  delete from public.afiliado_vehiculos where lower(trim(afiliado_email)) = lower(trim(p_email));
  insert into public.afiliado_vehiculos (afiliado_email, vehiculo_id)
    select lower(trim(p_email)), x from unnest(coalesce(p_vehiculo_ids,'{}')) x
    on conflict do nothing;
  select count(*) into v_n from public.afiliado_vehiculos where lower(trim(afiliado_email))=lower(trim(p_email));
  return jsonb_build_object('ok',true,'email',lower(trim(p_email)),'vehiculos',v_n);
end $$;
grant execute on function public.afiliado_asignar_vehiculos(text, bigint[]) to authenticated;

-- Vehículos asignados a un afiliado (para la pantalla del admin).
create or replace function public.afiliado_vehiculos_de(p_email text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'numero',v.numero,'placa',v.placa) order by v.numero), '[]'::jsonb)
  from public.afiliado_vehiculos av
  join public.vehiculos v on v.id = av.vehiculo_id
  where lower(trim(av.afiliado_email)) = lower(trim(p_email))
    and public.es_admin();
$$;
grant execute on function public.afiliado_vehiculos_de(text) to authenticated;

-- Lista de afiliados (perfiles rol=afiliado) con su conteo de vehículos.
create or replace function public.afiliados_listar()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'email', p.email, 'nombre', p.nombre, 'activo', p.activo,
      'vehiculos', (select count(*) from public.afiliado_vehiculos av where lower(trim(av.afiliado_email))=lower(trim(p.email)))
    ) order by p.nombre), '[]'::jsonb)
  from public.perfiles p
  where p.rol = 'afiliado' and public.es_admin();
$$;
grant execute on function public.afiliados_listar() to authenticated;
