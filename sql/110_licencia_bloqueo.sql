-- ===================================================================================
-- 110: BLOQUEO DE DESPACHO POR LICENCIA VENCIDA — se enciende solo el domingo 27.
-- ===================================================================================
-- Decisión del 22/09/2026, anunciada a despachadores y auditores en el aviso
-- LICENCIAS-2026-09 (sql/109): hasta el sábado 26 hay plazo para subir las licencias;
-- desde el domingo 27 no se puede despachar a un conductor con la licencia vencida.
--
-- La fecha va en una tabla de configuración y no en el código: así el bloqueo se
-- enciende solo el 27, sin que nadie tenga que acordarse el domingo de activarlo. Y si
-- el plazo se corre, se cambia la fecha sin publicar una versión nueva de la app.
--
-- DOS REGLAS, tal como se decidieron:
--   1. BLOQUEO DURO: licencia vencida = no se despacha. Sin excusas ni saltos.
--   2. EN REVISIÓN NO BLOQUEA: si el despachador ya subió las fotos y operaciones
--      todavía no las ha aprobado, el conductor y el despachador ya cumplieron. Lo
--      que falta es que la empresa revise, y eso no se le cobra a ellos.
--
-- Lo que NO bloquea: la licencia POR VENCER (que todavía está vigente) sigue siendo
-- solo alerta. Se bloquea lo vencido, que es lo que no puede circular.
-- ===================================================================================

create table if not exists public.licencia_bloqueo_config (
  id             int primary key default 1,
  activo         boolean not null default true,
  desde          date not null,
  nota           text,
  actualizado_en timestamptz not null default now(),
  actualizado_por text,
  constraint licencia_bloqueo_una_fila check (id = 1)
);

insert into public.licencia_bloqueo_config (id, activo, desde, nota)
values (1, true, date '2026-09-27',
        'Anunciado el 22/09/2026 en el aviso LICENCIAS-2026-09: plazo hasta el sabado 26.')
on conflict (id) do nothing;

comment on table public.licencia_bloqueo_config is
  'Desde cuando la licencia vencida bloquea el despacho. La fecha vive aqui para que se encienda sola.';

alter table public.licencia_bloqueo_config enable row level security;
drop policy if exists lic_blq_cfg_sel on public.licencia_bloqueo_config;
create policy lic_blq_cfg_sel on public.licencia_bloqueo_config for select to authenticated using (true);
revoke insert, update, delete on public.licencia_bloqueo_config from authenticated;

-- Cambiar la fecha o apagar el bloqueo (solo admin).
create or replace function public.licencia_bloqueo_config_guardar(
  p_desde date default null, p_activo boolean default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración cambia el bloqueo de licencias.');
  end if;
  update public.licencia_bloqueo_config
     set desde = coalesce(p_desde, desde),
         activo = coalesce(p_activo, activo),
         nota = coalesce(nullif(trim(coalesce(p_nota, '')), ''), nota),
         actualizado_en = now(), actualizado_por = coalesce(auth.jwt() ->> 'email', 'sistema')
   where id = 1;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.licencia_bloqueo_config_guardar(date, boolean, text) from public, anon;
grant execute on function public.licencia_bloqueo_config_guardar(date, boolean, text) to authenticated;

-- ---------- ¿Se puede despachar a este conductor? ----------
-- Mismo molde que doc_bloqueo_estado (sql/66): la pantalla pregunta antes de despachar
-- y vuelve a preguntar al guardar. Devuelve siempre algo: si falla, no bloquea.
create or replace function public.licencia_bloqueo_estado(p_dr_id text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  cfg     public.licencia_bloqueo_config%rowtype;
  v_ced   text; v_nom text;
  p       public.perfilsociodemografico;
  s       public.licencia_actualizaciones;
  v_dias  int; v_rev boolean := false; v_vig boolean;
begin
  if not (public.es_admin() or public.es_despachador() or public.es_auditor()) then
    return jsonb_build_object('bloqueado', false);
  end if;
  select * into cfg from public.licencia_bloqueo_config where id = 1;
  v_vig := coalesce(cfg.activo, false) and cfg.desde is not null and v_hoy >= cfg.desde;

  select regexp_replace(coalesce(cedula, ''), '\D', '', 'g'), nombre into v_ced, v_nom
    from public.conductores_sonar where dr_id::text = p_dr_id limit 1;
  if coalesce(v_ced, '') = '' then
    return jsonb_build_object('bloqueado', false, 'desde', cfg.desde, 'vigente', v_vig);
  end if;

  select * into p from public.perfilsociodemografico where cedula = v_ced;
  -- Sin perfil o sin fecha registrada no se bloquea: el dato falta en la empresa, no en
  -- el conductor. Eso se arregla en Gestión Humana, no trancando el despacho.
  if p.id is null or p.licencia_vencimiento is null then
    return jsonb_build_object('bloqueado', false, 'desde', cfg.desde, 'vigente', v_vig,
                              'nombre', coalesce(v_nom, p.nombre), 'sin_dato', true);
  end if;

  v_dias := p.licencia_vencimiento - v_hoy;

  -- ¿Ya subieron las fotos de este mismo ciclo y están esperando revisión?
  select * into s from public.licencia_actualizaciones
   where cedula = v_ced and vence_anterior is not distinct from p.licencia_vencimiento
   order by subido_en desc limit 1;
  v_rev := (s.id is not null and s.estado = 'PENDIENTE');

  return jsonb_build_object(
    'bloqueado', (v_vig and v_dias < 0 and not v_rev),
    'vigente', v_vig,                 -- si el bloqueo ya está encendido
    'desde', cfg.desde,               -- desde cuándo bloquea (para la cuenta regresiva)
    'faltan', greatest(cfg.desde - v_hoy, 0),
    'nombre', coalesce(v_nom, p.nombre),
    'vence', p.licencia_vencimiento,
    'dias', v_dias,
    'categoria', p.categoria_licencia,
    'en_revision', v_rev,
    'subido_en', s.subido_en,
    'motivo_rechazo', case when s.estado = 'RECHAZADO' then s.motivo_rechazo else null end);
end $fn$;
revoke all on function public.licencia_bloqueo_estado(text) from public, anon;
grant execute on function public.licencia_bloqueo_estado(text) to authenticated;

-- ---------- Cuántos quedan por poner al día (para el tablero de administración) ----------
create or replace function public.licencia_bloqueo_resumen()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare cfg public.licencia_bloqueo_config%rowtype; v_hoy date; v jsonb;
begin
  if not (public.es_admin() or public.es_operaciones()) then
    return jsonb_build_object('ok', false);
  end if;
  select * into cfg from public.licencia_bloqueo_config where id = 1;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  select jsonb_build_object(
    'vencidas',    count(*) filter (where a.dias < 0 and not a.en_revision),
    'en_revision', count(*) filter (where a.dias < 0 and a.en_revision),
    'por_vencer',  count(*) filter (where a.dias >= 0 and a.dias <= 30))
    into v
    from (
      -- distinct on: un mismo conductor puede tener dos dr_id en SONAR y contaria doble
      select distinct on (p.cedula)
             (p.licencia_vencimiento - v_hoy) as dias,
             exists (select 1 from public.licencia_actualizaciones l
                      where l.cedula = p.cedula and l.estado = 'PENDIENTE') as en_revision
        from public.conductores_sonar c
        join public.perfilsociodemografico p
          on p.cedula = regexp_replace(coalesce(c.cedula, ''), '\D', '', 'g')
       where c.status = 'ENABLED' and p.estado = 'ACTIVO'
         and p.licencia_vencimiento is not null
       order by p.cedula, c.dr_id) a;

  return jsonb_build_object('ok', true, 'desde', cfg.desde, 'activo', cfg.activo,
    'faltan_dias', greatest(cfg.desde - v_hoy, 0),
    'vigente', (coalesce(cfg.activo, false) and v_hoy >= cfg.desde)) || coalesce(v, '{}'::jsonb);
end $fn$;
revoke all on function public.licencia_bloqueo_resumen() from public, anon;
grant execute on function public.licencia_bloqueo_resumen() to authenticated;
