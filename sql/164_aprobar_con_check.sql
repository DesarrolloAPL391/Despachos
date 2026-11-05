-- ============================================================================================
-- 164) Aprobar con un check (vacaciones y permisos)
--
-- Pedido: "lo que se pueda aceptar por parte de las áreas, que se pueda hacer con un check".
-- En la lista de Vacaciones y de Permisos cada área (Gestión Humana, Gerencia, Nómina) marca su
-- casilla y queda aprobado, sin abrir la solicitud. Desmarcarla quita la aprobación, para que un
-- clic equivocado se arregle con otro clic. Negar sigue siendo desde la ficha, porque pide motivo.
--
-- Como una casilla se marca y se desmarca sin dejar rastro en la fila, cada decisión (aprobar,
-- negar, quitar, recibir en nómina) queda en aprobaciones_log: quién, qué y cuándo.
-- Se aplica sobre sql/97 (permisos) y sql/163 (vacaciones).
-- ============================================================================================

create table if not exists public.aprobaciones_log (
  id          bigserial primary key,
  modulo      text not null check (modulo in ('VACACIONES', 'PERMISOS')),
  registro_id bigint not null,
  instancia   text not null,          -- GH / GERENCIA / NOMINA
  estado      text not null,          -- APROBADO / NEGADO / PENDIENTE (quitó) / RECIBIDO / QUITADO
  nota        text,
  por         text,
  en          timestamptz not null default now()
);
create index if not exists aprobaciones_log_idx on public.aprobaciones_log (modulo, registro_id, en);
alter table public.aprobaciones_log enable row level security;
revoke all on public.aprobaciones_log from public, anon;
grant select on public.aprobaciones_log to authenticated;
drop policy if exists aprobaciones_log_ver on public.aprobaciones_log;
create policy aprobaciones_log_ver on public.aprobaciones_log
  for select to authenticated using ((select public.es_vac_ver()) or (select public.es_permiso_ver()));

-- 1) Permisos: ahora también se puede QUITAR la decisión propia (p_estado = 'PENDIENTE') ----------
create or replace function public.permiso_decidir(
  p_id bigint, p_instancia text, p_estado text, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_yo   text := lower(coalesce(auth.email(), ''));
  v_nota text := nullif(trim(coalesce(p_nota, '')), '');
  v_est  text := nullif(p_estado, 'PENDIENTE');      -- null = quitar la decisión
begin
  if p_estado not in ('APROBADO', 'NEGADO', 'PENDIENTE') then
    return jsonb_build_object('ok', false, 'error', 'Decision no valida.');
  end if;
  if p_instancia = 'GH' then
    if not public.es_talento_humano() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gestion Humana.');
    end if;
    update public.permisos
       set gh_estado = v_est,
           gh_nota = case when v_est is null then null else v_nota end,
           gh_por  = case when v_est is null then null else v_yo end,
           gh_en   = case when v_est is null then null else now() end
     where id = p_id and anulado_en is null;
  elsif p_instancia = 'GERENCIA' then
    if not public.es_permiso_gerencia() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gerencia.');
    end if;
    update public.permisos
       set ger_estado = v_est,
           ger_nota = case when v_est is null then null else v_nota end,
           ger_por  = case when v_est is null then null else v_yo end,
           ger_en   = case when v_est is null then null else now() end
     where id = p_id and anulado_en is null;
  else
    return jsonb_build_object('ok', false, 'error', 'Instancia no valida.');
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No se encontro la solicitud (o esta anulada).');
  end if;
  insert into public.aprobaciones_log (modulo, registro_id, instancia, estado, nota, por)
  values ('PERMISOS', p_id, p_instancia, p_estado, v_nota, v_yo);
  return (select jsonb_build_object('ok', true, 'estado', p.estado) from public.permisos p where p.id = p_id);
end $$;
revoke all on function public.permiso_decidir(bigint, text, text, text) from public, anon;
grant execute on function public.permiso_decidir(bigint, text, text, text) to authenticated;

-- 2) Vacaciones: lo mismo, y después de "recibido en nómina" ya no se cambia ----------------------
create or replace function public.vacaciones_decidir(
  p_id bigint, p_instancia text, p_estado text, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_yo   text := lower(coalesce(auth.email(), ''));
  v_nota text := nullif(trim(coalesce(p_nota, '')), '');
  v_est  text := nullif(p_estado, 'PENDIENTE');      -- null = quitar la decisión
begin
  if p_estado not in ('APROBADO', 'NEGADO', 'PENDIENTE') then
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
    update public.vacaciones
       set gh_estado = v_est,
           gh_nota = case when v_est is null then null else v_nota end,
           gh_por  = case when v_est is null then null else v_yo end,
           gh_en   = case when v_est is null then null else now() end
     where id = p_id and anulado_en is null and nom_en is null;
  elsif p_instancia = 'GERENCIA' then
    if not public.es_permiso_gerencia() then
      return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Gerencia.');
    end if;
    update public.vacaciones
       set ger_estado = v_est,
           ger_nota = case when v_est is null then null else v_nota end,
           ger_por  = case when v_est is null then null else v_yo end,
           ger_en   = case when v_est is null then null else now() end
     where id = p_id and anulado_en is null and nom_en is null and req_gerencia;
  else
    return jsonb_build_object('ok', false, 'error', 'Instancia no válida.');
  end if;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No se puede: la solicitud no existe, está anulada o ya la recibió Nómina.');
  end if;
  insert into public.aprobaciones_log (modulo, registro_id, instancia, estado, nota, por)
  values ('VACACIONES', p_id, p_instancia, p_estado, v_nota, v_yo);
  return (select jsonb_build_object('ok', true, 'estado', v.estado) from public.vacaciones v where v.id = p_id);
end $$;
revoke all on function public.vacaciones_decidir(bigint, text, text, text) from public, anon;
grant execute on function public.vacaciones_decidir(bigint, text, text, text) to authenticated;

create or replace function public.vacaciones_nomina_recibir(p_id bigint, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_vac_nomina() then
    return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Nómina.');
  end if;
  update public.vacaciones
     set nom_por = v_yo, nom_en = now(), nom_nota = nullif(trim(coalesce(p_nota, '')), '')
   where id = p_id and estado = 'APROBADO' and nom_en is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Solo se recibe una solicitud aprobada que Nómina no haya recibido.');
  end if;
  insert into public.aprobaciones_log (modulo, registro_id, instancia, estado, nota, por)
  values ('VACACIONES', p_id, 'NOMINA', 'RECIBIDO', nullif(trim(coalesce(p_nota, '')), ''), v_yo);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.vacaciones_nomina_recibir(bigint, text) from public, anon;
grant execute on function public.vacaciones_nomina_recibir(bigint, text) to authenticated;

-- Desmarcar "recibido en nómina" (el clic equivocado de Nómina).
create or replace function public.vacaciones_nomina_quitar(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_vac_nomina() then
    return jsonb_build_object('ok', false, 'error', 'Esta casilla la firma Nómina.');
  end if;
  update public.vacaciones set nom_por = null, nom_en = null, nom_nota = null
   where id = p_id and nom_en is not null and anulado_en is null;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Esa solicitud no estaba recibida en nómina.');
  end if;
  insert into public.aprobaciones_log (modulo, registro_id, instancia, estado, por)
  values ('VACACIONES', p_id, 'NOMINA', 'QUITADO', v_yo);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.vacaciones_nomina_quitar(bigint) from public, anon;
grant execute on function public.vacaciones_nomina_quitar(bigint) to authenticated;
