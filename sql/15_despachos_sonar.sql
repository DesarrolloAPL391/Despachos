-- ============================================================================
-- 15_despachos_sonar.sql  (v131)
-- Trae los despachos REALES desde SONAR y marca los INCOMPLETOS para auditar.
--
-- Por qué: la operación se despacha en SONAR, no en la app. La app tiene la
-- programación; SONAR tiene lo que de verdad pasó. Esto trae lo segundo.
--
-- Usa GET_DispatchedVehicles (endpoint sapps.asmx), que devuelve los nombres YA
-- resueltos (móvil 5579, ruta 135I, conductor con nombre y apellido) en vez de
-- códigos, más las banderas lclose/lrunning/lcanceled/lcanceledbyuser.
-- Verificado contra la flota 990 con la cuenta del vault.
--
-- La regla de estado NO es inventada: es la misma de webapp/vuelos/despachos.py,
-- que ya se usa para el informe del aeropuerto.
--   lclose=1 + lcanceled=0  -> Completo    (cerró bien)
--   lclose=1 + lcanceled=1  -> Incompleto  (cerró pero quedó marcado)
--   lclose=0 + lcanceled=1  -> Cancelado
--   lrunning=1              -> En progreso
--
-- Ojo: SONAR EXIGE el mId (probado: con mId vacío responde ERROR), así que es una
-- llamada por móvil (~340). Por eso el sync va POR LOTES y no en vivo.
-- GET_DispatchedVehicles entrega las horas en hora de COLOMBIA (no UTC): el rango
-- se manda en local y initTime se guarda tal cual.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Los despachos reales de SONAR
-- ---------------------------------------------------------------------------
create table if not exists public.despachos_sonar (
  itl_id          bigint primary key,          -- id del despacho en SONAR (itlId)
  fecha           date    not null,
  mid             text    not null,            -- tracker en SONAR
  movil           text,                        -- mDesc  (ej. 5579)
  placa           text,                        -- mPlaca
  ruta            text,                        -- itDesc (ej. 135I)
  conductor       text,                        -- drName
  hora_inicio     time,                        -- initTime (hora de Colombia)
  elapsed_seg     int,                         -- 'elapsed' de SONAR, tal cual
  comentario      text,
  lclose          boolean,
  lrunning        boolean,
  lcanceled       boolean,
  lcanceledbyuser boolean,
  -- Estado calculado: una sola verdad, imposible que se desincronice
  estado text generated always as (
    case
      when lrunning then 'En progreso'
      when lclose then (case when (coalesce(lcanceled,false) or coalesce(lcanceledbyuser,false))
                             then 'Incompleto' else 'Completo' end)
      when (coalesce(lcanceled,false) or coalesce(lcanceledbyuser,false)) then 'Cancelado'
      else 'Incompleto'
    end
  ) stored,
  -- Trabajo del auditor
  auditado        boolean not null default false,
  auditor_email   text,
  auditado_en     timestamptz,
  observacion     text,
  sincronizado_en timestamptz not null default now()
);
create index if not exists ix_dsonar_fecha  on public.despachos_sonar (fecha desc);
create index if not exists ix_dsonar_ruta   on public.despachos_sonar (lower(trim(ruta)));
create index if not exists ix_dsonar_estado on public.despachos_sonar (estado);

-- Control del sync: permite ir por lotes y saber qué móviles faltan.
-- (Un móvil sin viajes ese día también queda registrado, con viajes=0; si no,
--  se reintentaría eternamente.)
create table if not exists public.despachos_sonar_sync (
  fecha           date not null,
  mid             text not null,
  viajes          int  not null default 0,
  sincronizado_en timestamptz not null default now(),
  primary key (fecha, mid)
);

-- ---------------------------------------------------------------------------
-- 2) Quién lo ve: el auditor SOLO sus rutas; el admin todo. El despachador NO
--    (es una herramienta de auditoría).
-- ---------------------------------------------------------------------------
alter table public.despachos_sonar enable row level security;
alter table public.despachos_sonar_sync enable row level security; -- sin políticas: solo el sync

drop policy if exists dsonar_select on public.despachos_sonar;
create policy dsonar_select on public.despachos_sonar
  for select to authenticated
  using (
    public.es_admin()
    or (public.es_auditor() and lower(trim(coalesce(ruta,''))) in (
          select lower(trim(r.nombre)) from public.rutas r where r.id = any(public.rutas_auditor())))
  );

-- El auditor solo puede marcar lo suyo como auditado (y el admin todo).
drop policy if exists dsonar_update on public.despachos_sonar;
create policy dsonar_update on public.despachos_sonar
  for update to authenticated
  using (
    public.es_admin()
    or (public.es_auditor() and lower(trim(coalesce(ruta,''))) in (
          select lower(trim(r.nombre)) from public.rutas r where r.id = any(public.rutas_auditor())))
  )
  with check (
    public.es_admin()
    or (public.es_auditor() and lower(trim(coalesce(ruta,''))) in (
          select lower(trim(r.nombre)) from public.rutas r where r.id = any(public.rutas_auditor())))
  );

-- Nadie inserta/borra a mano: eso lo hace el sync (SECURITY DEFINER).
revoke all on public.despachos_sonar from anon;
revoke all on public.despachos_sonar_sync from anon, authenticated;
grant select, update on public.despachos_sonar to authenticated;

-- ---------------------------------------------------------------------------
-- 3) El sync, por lotes. Devuelve cuántos faltan para poder llamarlo en bucle.
-- ---------------------------------------------------------------------------
create or replace function public.sync_despachos_sonar(p_fecha date, p_limite int default 25)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text; v_usr text; v_pwd text; v_ns text; v_sapps text; v_action text;
  v_mid text; v_body text; v_resp text; v_xml xml;
  v_ini text; v_fin text;
  v_n int; v_tot int := 0; v_mov int := 0; v_pend int;
begin
  -- Solo el admin (o el cron por service_role) dispara el sync: son ~340 llamadas a SONAR.
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador puede sincronizar.');
  end if;

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'SONAR_URL';
  select decrypted_secret into v_usr from vault.decrypted_secrets where name = 'SONAR_USER';
  select decrypted_secret into v_pwd from vault.decrypted_secrets where name = 'SONAR_PASSWORD';
  select decrypted_secret into v_ns  from vault.decrypted_secrets where name = 'SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;

  -- GET_DispatchedVehicles vive en el OTRO endpoint (sapps.asmx), no en el del vault.
  v_sapps  := rtrim(v_url, '/') || '/sapps.asmx';
  v_action := rtrim(v_ns, '/') || '/GET_DispatchedVehicles';
  v_ini := to_char(p_fecha, 'YYYY-MM-DD') || ' 00:00:00';        -- hora de Colombia
  v_fin := to_char(p_fecha + 1, 'YYYY-MM-DD') || ' 00:00:00';

  perform set_config('http.timeout_msec', '50000', true);

  -- Móviles que todavía no se han traído para esa fecha
  for v_mid in
    select distinct g.tracker_id
    from public.vehiculosgps g
    where coalesce(g.tracker_id, '') <> ''
      and not exists (select 1 from public.despachos_sonar_sync s
                      where s.fecha = p_fecha and s.mid = g.tracker_id)
    order by g.tracker_id
    limit greatest(p_limite, 1)
  loop
    v_body :=
      '<?xml version="1.0" encoding="utf-8"?>'
      || '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      || '<GET_DispatchedVehicles xmlns="' || v_ns || '">'
      || '<User>' || v_usr || '</User><Password>' || v_pwd || '</Password>'
      || '<fleetId>990</fleetId><mId>' || v_mid || '</mId>'
      || '<UTC_datetime_init>' || v_ini || '</UTC_datetime_init>'
      || '<UTC_datetime_end>' || v_fin || '</UTC_datetime_end>'
      || '</GET_DispatchedVehicles></soap:Body></soap:Envelope>';

    v_n := 0;
    begin
      select content into v_resp from extensions.http((
        'POST', v_sapps, array[extensions.http_header('SOAPAction', v_action)],
        'text/xml; charset=utf-8', v_body)::extensions.http_request);
      v_xml := v_resp::xml;

      insert into public.despachos_sonar as d
        (itl_id, fecha, mid, movil, placa, ruta, conductor, hora_inicio, elapsed_seg,
         comentario, lclose, lrunning, lcanceled, lcanceledbyuser, sincronizado_en)
      select
        ((xpath('/x:ItDispatches/x:itlId/text()', n, array[array['x', v_ns]]))[1]::text)::bigint,
        p_fecha,
        (xpath('/x:ItDispatches/x:mId/text()',    n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:mDesc/text()',  n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:mPlaca/text()', n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:itDesc/text()', n, array[array['x', v_ns]]))[1]::text,
        (xpath('/x:ItDispatches/x:drName/text()', n, array[array['x', v_ns]]))[1]::text,
        nullif((xpath('/x:ItDispatches/x:initTime/text()', n, array[array['x', v_ns]]))[1]::text, '')::time,
        nullif((xpath('/x:ItDispatches/x:elapsed/text()',  n, array[array['x', v_ns]]))[1]::text, '')::int,
        (xpath('/x:ItDispatches/x:comments/text()', n, array[array['x', v_ns]]))[1]::text,
        nullif((xpath('/x:ItDispatches/x:lclose/text()',          n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        nullif((xpath('/x:ItDispatches/x:lrunning/text()',        n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        nullif((xpath('/x:ItDispatches/x:lcanceled/text()',       n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        nullif((xpath('/x:ItDispatches/x:lcanceledbyuser/text()', n, array[array['x', v_ns]]))[1]::text, '')::boolean,
        now()
      from unnest(xpath('//x:ItDispatches', v_xml, array[array['x', v_ns]])) as n
      on conflict (itl_id) do update set
        -- Se refresca lo que puede cambiar (un viaje en curso que luego cierra),
        -- pero NO se toca el trabajo del auditor.
        lclose = excluded.lclose, lrunning = excluded.lrunning,
        lcanceled = excluded.lcanceled, lcanceledbyuser = excluded.lcanceledbyuser,
        elapsed_seg = excluded.elapsed_seg, sincronizado_en = now();
      get diagnostics v_n = row_count;
    exception when others then
      v_n := 0;  -- un móvil que falle no puede tumbar el lote
    end;

    insert into public.despachos_sonar_sync (fecha, mid, viajes)
      values (p_fecha, v_mid, v_n)
      on conflict (fecha, mid) do update set viajes = excluded.viajes, sincronizado_en = now();
    v_tot := v_tot + v_n; v_mov := v_mov + 1;
  end loop;

  select count(*) into v_pend
    from public.vehiculosgps g
    where coalesce(g.tracker_id, '') <> ''
      and not exists (select 1 from public.despachos_sonar_sync s
                      where s.fecha = p_fecha and s.mid = g.tracker_id);

  return jsonb_build_object('ok', true, 'fecha', p_fecha, 'moviles', v_mov,
                            'viajes', v_tot, 'pendientes', v_pend);
end $$;

revoke all on function public.sync_despachos_sonar(date, int) from public, anon;
grant execute on function public.sync_despachos_sonar(date, int) to authenticated;
