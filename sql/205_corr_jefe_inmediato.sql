-- 205_corr_jefe_inmediato.sql — 📬 Los comunicados los revisa el JEFE INMEDIATO de quien los crea — 25/11/2026
--
-- Regla pedida: «los comunicados se crean con un consecutivo y los revisa el jefe inmediato; las jerarquías se ven
-- desde el perfil». Decisiones del usuario (25/11): si quien crea no tiene jefe inmediato con cuenta, lo revisa
-- ADMINISTRACIÓN; además del jefe, un administrador de la correspondencia también puede aprobar o rechazar; el permiso
-- global «aprueba comunicados» (es_aprobador_comunicados) deja de usarse.
--
-- 1) profiles.jefe_id: el jefe inmediato de cada usuario de la correspondencia (otra cuenta). Solo lo cambia un
--    administrador de la correspondencia (protect_profile_fields), como el área y el rol.
-- 2) radicados.revisor_id: quién revisa ESE comunicado. Lo pone la base al crearlo (el jefe de quien lo crea en ese
--    momento) y no lo puede cambiar sino un administrador. Vacío = lo revisa administración.
-- 3) Decidir (aprobar o rechazar) un comunicado = su revisor o un administrador de la correspondencia, y NUNCA quien lo
--    creó. Solo se decide uno pendiente. La versión «final» la sube quien puede decidir.
-- 4) El revisor ve el comunicado, sus adjuntos y su historial aunque sea de otra área (puede_gestionar_radicado).
-- 5) reenviar_comunicado: un comunicado RECHAZADO vuelve a revisión con el MISMO número (quien lo creó, tras subir el
--    borrador corregido); si no tenía revisor y ya hay jefe, se lo pone.
-- 6) corr_jefes_perfil(): para la pantalla de administración, el jefe que SUGIERE el Perfil (cargo y área de cada
--    persona administrativa activa). Solo sugiere: el jefe lo asigna el administrador. Devuelve cargos y áreas, nunca
--    nombres, cédulas ni salarios del Perfil.
--
-- Idempotente. No toca radicados existentes (los que ya están siguen sin revisor = administración).
set lock_timeout = '5s';

-- 1) y 2) Columnas ----------------------------------------------------------------------------------------------
alter table public.profiles add column if not exists jefe_id uuid;
alter table public.radicados add column if not exists revisor_id uuid;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_jefe_id_fkey') then
    alter table public.profiles add constraint profiles_jefe_id_fkey
      foreign key (jefe_id) references public.profiles(id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_jefe_no_uno_mismo') then
    alter table public.profiles add constraint profiles_jefe_no_uno_mismo check (jefe_id is distinct from id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'radicados_revisor_id_fkey') then
    alter table public.radicados add constraint radicados_revisor_id_fkey
      foreign key (revisor_id) references public.profiles(id) on delete set null;
  end if;
end $$;
create index if not exists idx_profiles_jefe on public.profiles(jefe_id) where jefe_id is not null;
create index if not exists idx_radicados_revisor on public.radicados(revisor_id) where revisor_id is not null;
comment on column public.profiles.jefe_id is 'Jefe inmediato: revisa los comunicados de esta persona (sql/205). Solo lo cambia un administrador.';
comment on column public.radicados.revisor_id is 'Quién revisa este comunicado (el jefe de quien lo creó, al crearlo). Vacío = administración (sql/205).';

-- Solo un administrador cambia rol, área, jefe y el permiso viejo. «auth.uid() is null» = la base misma (por ejemplo
-- el «on delete set null» al borrar la cuenta de un jefe): ahí no se revierte, o borrar esa cuenta fallaría.
create or replace function public.protect_profile_fields()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    new.rol := old.rol;
    new.area_id := old.area_id;
    new.es_aprobador_comunicados := old.es_aprobador_comunicados;
    if auth.uid() is not null then
      new.jefe_id := old.jefe_id;
    end if;
  end if;
  return new;
end;
$$;

-- 3) Quién decide -----------------------------------------------------------------------------------------------
create or replace function public.corr_puede_decidir(p_radicado_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.radicados r
     where r.id = p_radicado_id
       and r.tipo = 'comunicado'
       and r.creado_por is distinct from auth.uid()          -- nadie aprueba el suyo
       and (r.revisor_id = auth.uid() or public.is_admin()));
$$;
revoke all on function public.corr_puede_decidir(uuid) from public, anon;
grant execute on function public.corr_puede_decidir(uuid) to authenticated;

-- El nombre viejo ahora dice si la persona revisa comunicados (es jefe de alguien o administrador)
create or replace function public.puede_aprobar_comunicados()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin() or exists (select 1 from public.profiles where jefe_id = auth.uid());
$$;

-- 4) El revisor también gestiona el comunicado (lo ve, ve y sube adjuntos, ve el historial)
create or replace function public.puede_gestionar_radicado(p_radicado_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.radicados r
    where r.id = p_radicado_id
      and (r.area_actual_id = public.mi_area_id()
           or r.creado_por = auth.uid()
           or r.revisor_id = auth.uid()
           or public.is_admin())
  );
$$;
alter policy radicados_select on public.radicados
  using ((area_actual_id = public.mi_area_id()) or (creado_por = auth.uid()) or (revisor_id = auth.uid()) or public.is_admin());
alter policy adjuntos_insert on public.radicado_adjuntos
  with check (public.puede_gestionar_radicado(radicado_id)
              and ((categoria is distinct from 'final') or public.corr_puede_decidir(radicado_id)));

-- Al crear: el número (como siempre) y quién lo revisa
create or replace function public.trg_radicados_before_insert()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_anio int;
  v_numero int;
  v_formateado text;
begin
  new.fecha_radicado := coalesce(new.fecha_radicado, now());
  v_anio := extract(year from new.fecha_radicado)::int;

  select numero, numero_formateado into v_numero, v_formateado
  from public.generar_numero_radicado(new.tipo, v_anio);

  new.anio := v_anio;
  new.consecutivo := v_numero;
  new.numero_radicado := v_formateado;
  new.estado := 'pendiente';
  new.estado_aprobacion := case when new.tipo = 'comunicado' then 'pendiente' else null end;
  new.creado_por := auth.uid();
  -- El jefe inmediato de quien lo crea; sin jefe, lo revisa administración (revisor vacío)
  new.revisor_id := case when new.tipo = 'comunicado'
                         then (select p.jefe_id from public.profiles p where p.id = auth.uid()) end;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.trg_radicados_before_update()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  new.numero_radicado := old.numero_radicado;
  new.tipo := old.tipo;
  new.anio := old.anio;
  new.consecutivo := old.consecutivo;
  new.fecha_radicado := old.fecha_radicado;
  new.creado_por := old.creado_por;
  new.created_at := old.created_at;
  new.updated_at := now();
  -- Quién lo revisa: solo un administrador (o la base misma, al borrar la cuenta del revisor)
  if new.revisor_id is distinct from old.revisor_id and auth.uid() is not null and not public.is_admin() then
    new.revisor_id := old.revisor_id;
  end if;
  -- Aprobar o rechazar: el revisor o un administrador, nunca quien lo creó. Quien lo creó solo puede devolver a
  -- revisión uno rechazado (reenviar_comunicado).
  if new.estado_aprobacion is distinct from old.estado_aprobacion and auth.uid() is not null then
    if public.corr_puede_decidir(old.id) then
      null;
    elsif old.estado_aprobacion = 'rechazado' and new.estado_aprobacion = 'pendiente' and old.creado_por = auth.uid() then
      null;
    else
      new.estado_aprobacion := old.estado_aprobacion;
    end if;
  end if;
  -- Vuelve a revisión sin revisor y quien lo creó ya tiene jefe: se lo pone
  if old.estado_aprobacion = 'rechazado' and new.estado_aprobacion = 'pendiente' and new.revisor_id is null then
    new.revisor_id := (select p.jefe_id from public.profiles p where p.id = old.creado_por);
  end if;
  return new;
end;
$$;

create or replace function public.decidir_comunicado(p_radicado_id uuid, p_decision text, p_comentario text default null)
returns public.radicados
language plpgsql set search_path = public
as $$
declare
  v_row public.radicados;
  v_ant record;
begin
  if p_decision not in ('aprobado', 'rechazado') then
    raise exception 'Decisión inválida: %', p_decision;
  end if;
  select tipo, estado_aprobacion, creado_por into v_ant from public.radicados where id = p_radicado_id;
  if not found or v_ant.tipo is distinct from 'comunicado' then
    raise exception 'Comunicado no encontrado';
  end if;
  if not public.corr_puede_decidir(p_radicado_id) then
    if v_ant.creado_por = auth.uid() then
      raise exception 'Nadie aprueba su propio comunicado: lo revisa su jefe inmediato o un administrador de la correspondencia';
    end if;
    raise exception 'Este comunicado lo revisa el jefe inmediato de quien lo creó o un administrador de la correspondencia';
  end if;
  if v_ant.estado_aprobacion is distinct from 'pendiente' then
    raise exception 'Este comunicado ya no está pendiente (está %)', coalesce(v_ant.estado_aprobacion, 'sin estado');
  end if;

  perform set_config('app.movimiento_comentario', coalesce(p_comentario, ''), true);

  update public.radicados
     set estado_aprobacion = p_decision
   where id = p_radicado_id and tipo = 'comunicado'
  returning * into v_row;

  if not found or v_row.estado_aprobacion is distinct from p_decision then
    raise exception 'No se pudo registrar la decisión';
  end if;
  return v_row;
end;
$$;

-- 5) Reenviar a revisión un comunicado rechazado (mismo número) --------------------------------------------------
create or replace function public.reenviar_comunicado(p_radicado_id uuid, p_comentario text default null)
returns public.radicados
language plpgsql set search_path = public
as $$
declare
  v_row public.radicados;
  v_ant record;
begin
  select tipo, estado_aprobacion, creado_por into v_ant from public.radicados where id = p_radicado_id;
  if not found or v_ant.tipo is distinct from 'comunicado' then
    raise exception 'Comunicado no encontrado';
  end if;
  if v_ant.estado_aprobacion is distinct from 'rechazado' then
    raise exception 'Solo se reenvía a revisión un comunicado rechazado';
  end if;
  if v_ant.creado_por is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Solo quien creó el comunicado (o un administrador de la correspondencia) lo reenvía a revisión';
  end if;

  perform set_config('app.movimiento_comentario', coalesce(p_comentario, ''), true);

  update public.radicados
     set estado_aprobacion = 'pendiente'
   where id = p_radicado_id and tipo = 'comunicado'
  returning * into v_row;

  if not found or v_row.estado_aprobacion is distinct from 'pendiente' then
    raise exception 'No se pudo reenviar el comunicado';
  end if;
  return v_row;
end;
$$;
revoke all on function public.reenviar_comunicado(uuid, text) from public, anon;
grant execute on function public.reenviar_comunicado(uuid, text) to authenticated;

-- 6) El jefe que sugiere el Perfil ------------------------------------------------------------------------------
-- Texto en mayúsculas, sin tildes y con un solo espacio (para comparar nombres, cargos y áreas)
create or replace function public._corr_norm(p text)
returns text
language sql immutable set search_path = public
as $$
  select nullif(regexp_replace(upper(translate(btrim(coalesce(p, '')), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNAEIOUUN')), '\s+', ' ', 'g'), '');
$$;
revoke all on function public._corr_norm(text) from public, anon;
grant execute on function public._corr_norm(text) to authenticated;

-- Nivel por el cargo: 1 gerente, 2 director, 3 coordinador / líder / jefe, 4 subcoordinador, 5 los demás.
-- Cabeza de cada área del Perfil: la persona de menor nivel si es una sola (y es nivel 4 o menos); si no, un
-- coordinador cuyo cargo nombra el área (Seguridad Vial). El jefe de cada persona es la cabeza de su área si está por
-- encima; las cabezas (y quien no tiene cabeza) van al Gerente.
-- Cada cuenta de correspondencia se une a su persona del Perfil por el correo, el nombre exacto (el del ERP o el de
-- la correspondencia) o todas las palabras del nombre, y solo si da UNA persona. Las cuentas por área («Taller»…) que
-- no son de una persona se sugieren con la cabeza de esa área.
create or replace function public.corr_jefes_perfil()
returns table (profile_id uuid, enlace text, cargo text, area_perfil text,
               jefe_cargo text, jefe_area text, jefe_profile_id uuid, jefe_cuentas int)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador de la correspondencia ve la jerarquía' using errcode = '42501';
  end if;
  return query
  with ps as (
    select s.id, s.cargo, s.area, public._corr_norm(s.area) as narea, lower(btrim(s.correo)) as correo,
           public._corr_norm(s.nombre) as nom,
           case when public._corr_norm(s.cargo) ~ '\mGERENTE\M' then 1
                when public._corr_norm(s.cargo) ~ '\mDIRECTOR' then 2
                when public._corr_norm(s.cargo) ~ '\mSUBCOORDINADOR' then 4
                when public._corr_norm(s.cargo) ~ '^(COORDINADOR|LIDER|JEFE)\M' then 3
                else 5 end as nivel
      from public.perfilsociodemografico s
     where s.tipo = 'ADMINISTRATIVO' and s.estado = 'ACTIVO'),
  areas_p as (select distinct narea from ps where narea is not null),
  cab as (
    select a.narea, coalesce(
      (select x.id from ps x
        where x.narea = a.narea and x.nivel <= 4
          and x.nivel = (select min(y.nivel) from ps y where y.narea = a.narea)
          and (select count(*) from ps y where y.narea = a.narea
                 and y.nivel = (select min(z.nivel) from ps z where z.narea = a.narea)) = 1),
      (select min(x.id) from ps x where x.nivel <= 3 and public._corr_norm(x.cargo) like '%' || a.narea || '%'
        having count(*) = 1)) as cabeza
      from areas_p a),
  gerente as (select (select min(id) from ps where nivel = 1 having count(*) = 1) as id),
  jefe_de as (
    select p.id,
           case when p.nivel = 1 then null
                when c.cabeza is not null and c.cabeza <> p.id
                     and (select h.nivel from ps h where h.id = c.cabeza) < p.nivel then c.cabeza
                when (select g.id from gerente g) is distinct from p.id then (select g.id from gerente g)
           end as jefe
      from ps p left join cab c on c.narea = p.narea),
  cu as (
    select pr.id as prof, pr.area_id, lower(btrim(u.email)) as email,
           public._corr_norm(e.nombre) as nom1, public._corr_norm(pr.nombre_completo) as nom2,
           public._corr_norm((select ar.nombre from public.areas ar where ar.id = pr.area_id)) as narea_corr
      from public.profiles pr
      join auth.users u on u.id = pr.id
      left join public.perfiles e on e.id = pr.id),
  enl as (
    select cu.prof, cu.area_id, cu.narea_corr,
           (select min(ps.id) from ps where ps.correo = cu.email having count(*) = 1) as p_correo,
           (select min(ps.id) from ps where ps.nom in (cu.nom1, cu.nom2) having count(*) = 1) as p_nombre,
           (select min(ps.id) from ps
             where exists (select 1 from unnest(array[cu.nom1, cu.nom2]) n(nom)
                            where n.nom is not null
                              and (select count(*) from regexp_split_to_table(n.nom, ' ') w where length(w) >= 3) >= 2
                              and not exists (select 1 from regexp_split_to_table(n.nom, ' ') w
                                               where length(w) >= 3 and position(' ' || w || ' ' in ' ' || ps.nom || ' ') = 0))
            having count(*) = 1) as p_palabras
      from cu),
  enl2 as (
    select e.prof, e.area_id, e.narea_corr,
           coalesce(e.p_correo, e.p_nombre, e.p_palabras) as persona,
           case when e.p_correo is not null then 'correo' when e.p_nombre is not null then 'nombre'
                when e.p_palabras is not null then 'palabras' end as como
      from enl e),
  -- Cuenta de una persona -> su cuenta (solo si es una)
  cuenta_de as (select persona, min(prof::text)::uuid as prof, count(*)::int as n from enl2 where persona is not null group by persona),
  base as (
    select e.prof, e.area_id, e.persona, e.como,
           -- área del Perfil para la cuenta por área: el nombre exacto o la primera palabra («Control y Despacho» -> CONTROL)
           (select ap.narea from areas_p ap
             where e.persona is null and e.narea_corr is not null
               and (ap.narea = e.narea_corr or ap.narea = split_part(e.narea_corr, ' ', 1))
             order by (ap.narea = e.narea_corr) desc limit 1) as narea_cuenta
      from enl2 e)
  select b.prof,
         coalesce(b.como, case when b.narea_cuenta is not null then 'area' end),
         p.cargo,
         coalesce(p.area, (select min(x.area) from ps x where x.narea = b.narea_cuenta)),
         j.cargo,
         j.area,
         case when cd.n = 1 and cd.prof <> b.prof then cd.prof end,
         coalesce(cd.n, 0)
    from base b
    left join ps p on p.id = b.persona
    left join jefe_de jd on jd.id = b.persona
    left join ps j on j.id = coalesce(jd.jefe, (select c.cabeza from cab c where c.narea = b.narea_cuenta))
    left join cuenta_de cd on cd.persona = j.id
   where b.persona is not null or b.narea_cuenta is not null;
end;
$$;
revoke all on function public.corr_jefes_perfil() from public, anon;
grant execute on function public.corr_jefes_perfil() to authenticated;

notify pgrst, 'reload schema';

-- DESHACER (si hiciera falta): volver a las definiciones de antes (protect_profile_fields, puede_aprobar_comunicados,
--   puede_gestionar_radicado, trg_radicados_before_insert/update y decidir_comunicado del schema.sql de la app, con
--   «not public.puede_aprobar_comunicados()» en el before_update), la política radicados_select sin revisor_id y
--   adjuntos_insert con «or puede_aprobar_comunicados()»; drop function corr_puede_decidir, reenviar_comunicado,
--   corr_jefes_perfil y _corr_norm; las columnas jefe_id y revisor_id se pueden dejar (vacías no hacen nada).
