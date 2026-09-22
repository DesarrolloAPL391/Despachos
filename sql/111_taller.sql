-- ===================================================================================
-- 111: EL TALLER DENTRO DE LA APP (CloudFleet) — órdenes, novedades y programación.
-- ===================================================================================
-- El taller de APL trabaja en CloudFleet, que tiene API REST propia. Hasta hoy la app no
-- sabía nada de eso: el despachador podía sacar un bus que estaba en el taller, y la
-- programación de mantenimiento vivía en otro sistema que operación no veía.
--
-- POR QUÉ TABLA ESPEJO Y NO CONSULTA EN VIVO:
--   CloudFleet permite 30 peticiones por minuto y 4000 por día. Con 34 despachadores,
--   preguntar en cada despacho se come la cuota antes del mediodía y deja la app ciega el
--   resto de la jornada. Así que un cron trae los datos cada 15 minutos a estas tablas
--   (unas 700 llamadas al día, holgado) y la app lee local — el mismo camino de SONAR.
--
-- POR QUÉ SOLO AVISA Y NO BLOQUEA (decisión del 22/09/2026):
--   El estado de la orden NO sirve para decidir si el bus está varado. Medido ese día: 13
--   órdenes abiertas, decenas más en "cierre técnico" (el bus ya salió del taller y lo que
--   falta es el papeleo de costos), y una abierta hacía 52 días. El campo que sí dice la
--   verdad es `affectsVehicleAvailability`. Aun así, si el taller no cierra la orden el
--   mismo día, bloquear dejaría buses buenos sin despachar. Entonces: se avisa fuerte, se
--   mide, y si las órdenes se cierran a tiempo se vuelve bloqueo — para eso ya queda la
--   bandera `afecta_disponib`, igual que se hizo con las licencias en sql/110.
--
-- LA LLAVE VA EN EL VAULT, NUNCA EN EL CÓDIGO:
--   Project Settings > Vault > New secret, nombre exacto `CF_API_KEY`, valor = la API Key
--   generada en CloudFleet (Empresa > Configuración > Integraciones > API Keys).
--   Este repositorio es público: la llave no puede aparecer en ningún archivo.
--
-- Dos cosas de esta API que hay que tener presentes:
--   - Las fechas de respuesta vienen en UTC-0 (restar 5 para hora Colombia), igual que
--     SONAR. Aquí se guardan como timestamptz, así que Postgres las convierte solo.
--   - Al LEER, la prioridad de la novedad viene con el campo mal escrito (`prority`); al
--     CREARLA hay que mandarla bien escrita (`priority`). No es error nuestro.
-- ===================================================================================

-- ---------- 0) Configuración (una sola fila) ----------
create table if not exists public.taller_config (
  id              int primary key default 1,
  activo          boolean not null default true,
  reporta_por_id  int,                              -- persona de CloudFleet que firma las novedades que envía la app
  dias_ordenes    int not null default 175,         -- ventana de búsqueda de órdenes (la API no acepta más de 180 días)
  prog_atras      int not null default 20,          -- días hacia atrás de programación (para ver las vencidas)
  prog_adelante   int not null default 45,          -- días hacia adelante (lo que viene)
  nota            text,
  actualizado_en  timestamptz not null default now(),
  actualizado_por text,
  constraint taller_config_una_fila check (id = 1)
);

insert into public.taller_config (id, reporta_por_id, nota)
values (1, 338, 'La persona "API" de CloudFleet (id 338), verificada el 22/09/2026. Las novedades '
             || 'salen a nombre de ella, y en el comentario queda quién las reportó de verdad.')
on conflict (id) do nothing;

comment on table public.taller_config is
  'Parámetros de la integración con el taller (CloudFleet). La llave NO vive aquí: va en el Vault como CF_API_KEY.';

-- ---------- 1) Órdenes de trabajo ----------
create table if not exists public.taller_ordenes (
  numero            int primary key,                -- el número de la orden en CloudFleet
  movil             text not null,                  -- vehicleCode = nuestro numero_interno
  estado            text,                           -- opened | onTechnicalCompletion
  tipo              text,                           -- PREVENTIVO | CORRECTIVO
  afecta_disponib   boolean not null default false, -- el campo que dice si el bus queda fuera de servicio
  motivo            text,
  falla             text,
  taller            text,
  etiquetas         text[],                         -- las "etiquetas de mantenimiento" (TALLER INTERNO, ...)
  fecha_taller      timestamptz,
  fecha_inicio      timestamptz,
  fin_estimado      timestamptz,
  odometro          numeric,
  cierre_tecnico_en timestamptz,
  cierre_final_en   timestamptz,
  costo_total       numeric,
  grupo             text,                           -- primaryGroup: los grupos de rutas del taller
  conductor         text,
  fuera_listado     boolean not null default false, -- ya no vino en el listado: se cerró o se anuló
  salio_en          timestamptz,
  vista_en          timestamptz not null default now(),
  crudo             jsonb
);
create index if not exists taller_ord_movil_idx on public.taller_ordenes (movil);
create index if not exists taller_ord_abierta_idx on public.taller_ordenes (movil)
  where estado = 'opened' and not fuera_listado;

-- ---------- 2) Novedades de mantenimiento ----------
create table if not exists public.taller_novedades (
  numero          int primary key,
  movil           text not null,
  reportada_en    timestamptz,
  prioridad       text,                             -- low | medium | high
  observacion     text,
  reportada_por   text,
  responsable     text,
  resuelta        boolean not null default false,
  resuelta_en     timestamptz,
  orden_numero    int,                              -- con qué orden se resolvió
  desde_checklist int,                              -- si nació de un preoperacional
  odometro        numeric,
  vista_en        timestamptz not null default now(),
  crudo           jsonb
);
create index if not exists taller_nov_movil_idx on public.taller_novedades (movil, resuelta);

-- ---------- 3) Programación de mantenimiento ----------
-- Ojo: esto es el mantenimiento del TALLER (tensionar frenos, engrasar, aceite). No
-- confundir con la tabla `preventivas` (sql/57), que es la revisión técnico-mecánica del
-- CDA. Son dos programaciones distintas, de dos partes distintas de la empresa.
create table if not exists public.taller_programacion (
  consecutivo     int primary key,
  movil           text not null,
  trabajo         text,
  rutina          text,
  estado          text,                             -- Vencido | Vence hoy | Próximo | A tiempo | Ejecutada...
  fecha_ejecutar  timestamptz,
  dias_dif        numeric,                          -- negativo = vencida
  odom_objetivo   numeric,
  odom_dif        numeric,
  orden_creada    int,
  orden_ejecucion int,
  fuente          text,
  tipo            text,
  vista_en        timestamptz not null default now(),
  crudo           jsonb
);
create index if not exists taller_prog_movil_idx on public.taller_programacion (movil, fecha_ejecutar);
create index if not exists taller_prog_fecha_idx on public.taller_programacion (fecha_ejecutar);

-- ---------- 4) Lo que la app le manda al taller ----------
-- Aquí queda quién reportó DE VERDAD, con su correo y su rol. En CloudFleet la novedad
-- sale a nombre de la persona "API", así que sin esta tabla se perdería la trazabilidad.
create table if not exists public.taller_novedades_app (
  id              bigint generated always as identity primary key,
  movil           text not null,
  prioridad       text not null,
  texto           text not null,
  odometro        numeric,
  intervencion_id bigint,                           -- si salió de una intervención del auditor
  enviado_por     text not null,
  nombre          text,
  rol             text,
  cf_numero       int,                              -- número que devolvió CloudFleet
  error           text,
  creado_en       timestamptz not null default now()
);
create index if not exists taller_nov_app_idx on public.taller_novedades_app (creado_en desc);

-- ---------- 5) Bitácora de la traída ----------
create table if not exists public.taller_sync (
  id      bigint generated always as identity primary key,
  que     text not null,
  filas   int,
  nuevas  int,
  ms      int,
  error   text,
  cuando  timestamptz not null default now()
);
create index if not exists taller_sync_idx on public.taller_sync (cuando desc);

-- ---------- 6) Quién ve qué ----------
alter table public.taller_config        enable row level security;
alter table public.taller_ordenes       enable row level security;
alter table public.taller_novedades     enable row level security;
alter table public.taller_programacion  enable row level security;
alter table public.taller_novedades_app enable row level security;
alter table public.taller_sync          enable row level security;

-- El despachador NO lee estas tablas: para el aviso del despacho usa taller_estado_movil(),
-- que le entrega solo lo del móvil que tiene en la mano.
drop policy if exists taller_ord_sel on public.taller_ordenes;
create policy taller_ord_sel on public.taller_ordenes for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor()) );

drop policy if exists taller_nov_sel on public.taller_novedades;
create policy taller_nov_sel on public.taller_novedades for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor()) );

drop policy if exists taller_prog_sel on public.taller_programacion;
create policy taller_prog_sel on public.taller_programacion for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor()) );

drop policy if exists taller_sync_sel on public.taller_sync;
create policy taller_sync_sel on public.taller_sync for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) );

drop policy if exists taller_cfg_sel on public.taller_config;
create policy taller_cfg_sel on public.taller_config for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) );

drop policy if exists taller_cfg_all on public.taller_config;
create policy taller_cfg_all on public.taller_config for all to authenticated
  using ( (select public.es_admin()) ) with check ( (select public.es_admin()) );

-- Cada quien ve lo que él reportó; admin, operaciones y auditores ven todo.
drop policy if exists taller_nov_app_sel on public.taller_novedades_app;
create policy taller_nov_app_sel on public.taller_novedades_app for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor())
       or enviado_por = (select auth.jwt() ->> 'email') );

revoke insert, update, delete on public.taller_ordenes       from authenticated;
revoke insert, update, delete on public.taller_novedades     from authenticated;
revoke insert, update, delete on public.taller_programacion  from authenticated;
revoke insert, update, delete on public.taller_novedades_app from authenticated;
revoke insert, update, delete on public.taller_sync          from authenticated;

-- ---------- 7) Quién puede disparar la traída ----------
-- Mismo molde que sca_puede_traer (sql/103): admin desde la app, y además pg_cron y el SQL
-- Editor, que no traen JWT y si no harían fallar la traída automática todas las veces.
create or replace function public.taller_puede_traer()
returns boolean
language sql stable security definer set search_path = public as $fn$
  select (select public.es_admin())
      or (auth.uid() is null and session_user in ('postgres', 'supabase_admin'));
$fn$;
revoke all on function public.taller_puede_traer() from public, anon;
grant execute on function public.taller_puede_traer() to authenticated;

-- ---------- 8) El llamado a CloudFleet ----------
-- Una sola puerta de salida: todas las funciones de abajo pasan por aquí. Devuelve la
-- lista en `datos` y la página siguiente en `next` (la API pagina por header X-NextPage).
-- No se le da permiso a nadie: solo la llaman las funciones de este archivo.
create or replace function public.taller_http(p_ruta text, p_metodo text default 'GET', p_body text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions, vault as $fn$
declare
  v_key text; v_url text; v_next text; v_retry text; v_js jsonb;
  v_resp extensions.http_response;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'CF_API_KEY';
  if coalesce(v_key, '') = '' then
    return jsonb_build_object('ok', false, 'error',
      'Falta CF_API_KEY en el Vault. Se crea en Project Settings > Vault con ese nombre exacto.');
  end if;

  v_url := case when p_ruta like 'http%' then p_ruta
                else 'https://fleet.cloudfleet.com/api/v1/' || ltrim(p_ruta, '/') end;

  perform set_config('http.timeout_msec', '45000', true);
  select * into v_resp from extensions.http((
    p_metodo, v_url,
    array[ extensions.http_header('Authorization', 'Bearer ' || v_key) ],
    case when p_body is null then null else 'application/json; charset=utf-8' end,
    p_body)::extensions.http_request);

  select h.value into v_next  from unnest(v_resp.headers) h where lower(h.field) = 'x-nextpage' limit 1;
  select h.value into v_retry from unnest(v_resp.headers) h where lower(h.field) = 'retry-after' limit 1;

  if v_resp.status in (401, 403) then
    return jsonb_build_object('ok', false, 'error',
      'CloudFleet rechazó la llave (' || v_resp.status || '). Revisa CF_API_KEY en el Vault y los '
      || 'Grupos de Usuario que tenga asignada la llave en CloudFleet.');
  elsif v_resp.status = 429 then
    return jsonb_build_object('ok', false, 'error',
      'CloudFleet cortó por exceso de peticiones (429). Son 30 por minuto y 4000 por día.',
      'reintentar_en_seg', v_retry);
  elsif v_resp.status not in (200, 201, 204) then
    return jsonb_build_object('ok', false, 'error', 'CloudFleet HTTP ' || v_resp.status,
      'detalle', left(coalesce(v_resp.content, ''), 400));
  end if;

  if coalesce(btrim(coalesce(v_resp.content, '')), '') = '' then
    v_js := 'null'::jsonb;
  else
    begin
      v_js := v_resp.content::jsonb;
    exception when others then
      return jsonb_build_object('ok', false, 'error', 'CloudFleet no devolvió JSON.',
        'detalle', left(coalesce(v_resp.content, ''), 400));
    end;
  end if;

  return jsonb_build_object('ok', true, 'status', v_resp.status, 'next', v_next, 'datos', v_js);
end $fn$;
revoke all on function public.taller_http(text, text, text) from public, anon, authenticated;

-- ---------- 9) Traer las órdenes de trabajo ----------
create or replace function public.taller_sync_ordenes()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  cfg public.taller_config%rowtype;
  v_t0 timestamptz := clock_timestamp();
  v_hoy date; v_desde date; v_st text; v_url text; v_pag int;
  v_r jsonb; v_arr jsonb; v_n int; v_nn int;
  v_ids int[]; v_vistos int[] := '{}';
  v_filas int := 0; v_nuevas int := 0; v_cerradas int := 0;
begin
  if not public.taller_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede sincronizar el taller.';
  end if;
  select * into cfg from public.taller_config where id = 1;
  if not coalesce(cfg.activo, false) then
    return jsonb_build_object('ok', false, 'error', 'La integración con el taller está apagada.');
  end if;

  v_hoy := (now() at time zone 'America/Bogota')::date;
  v_desde := v_hoy - cfg.dias_ordenes;

  -- Dos estados: `opened` es el bus que está en el taller; `onTechnicalCompletion` ya salió
  -- y solo le falta el cierre administrativo. Se guardan los dos para que operaciones vea
  -- el represamiento, pero el aviso del despacho solo mira `opened`.
  foreach v_st in array array['opened', 'onTechnicalCompletion'] loop
    v_url := 'work-orders/?status=' || v_st
          || '&startDateFrom=' || to_char(v_desde, 'YYYY-MM-DD') || 'T00:00:00Z'
          || '&startDateTo='   || to_char(v_hoy + 1, 'YYYY-MM-DD') || 'T00:00:00Z';
    v_pag := 0;
    loop
      v_pag := v_pag + 1;
      v_r := public.taller_http(v_url);
      if not coalesce((v_r->>'ok')::boolean, false) then
        insert into public.taller_sync (que, error, ms)
        values ('ordenes/' || v_st, left(v_r->>'error', 300),
                (extract(milliseconds from clock_timestamp() - v_t0))::int);
        return v_r;
      end if;
      v_arr := v_r->'datos';
      exit when jsonb_typeof(v_arr) <> 'array';

      select count(*) into v_n from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$';
      select count(*) into v_nn from jsonb_array_elements(v_arr) t
       where (t->>'number') ~ '^[0-9]+$'
         and not exists (select 1 from public.taller_ordenes o where o.numero = (t->>'number')::int);

      with f as (select t from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$')
      insert into public.taller_ordenes as o (
        numero, movil, estado, tipo, afecta_disponib, motivo, falla, taller, etiquetas,
        fecha_taller, fecha_inicio, fin_estimado, odometro, cierre_tecnico_en, cierre_final_en,
        costo_total, grupo, conductor, fuera_listado, salio_en, vista_en, crudo)
      select (t->>'number')::int,
             btrim(coalesce(t->>'vehicleCode', '')),
             t->>'status', t->>'type',
             coalesce((t->>'affectsVehicleAvailability')::boolean, false),
             nullif(btrim(coalesce(t->>'reason', '')), ''),
             nullif(btrim(coalesce(t->>'detectedIssue', '')), ''),
             t->'vendor'->>'name',
             case when jsonb_typeof(t->'maintenanceLabels') = 'array'
                  then (select array_agg(x #>> '{}') from jsonb_array_elements(t->'maintenanceLabels') x)
             end,
             nullif(t->>'workshopDate', '')::timestamptz,
             nullif(t->>'startDate', '')::timestamptz,
             nullif(t->>'estimatedFinishDate', '')::timestamptz,
             nullif(t->>'odometer', '')::numeric,
             nullif(t->>'technicalCompletionDate', '')::timestamptz,
             nullif(t->>'finalCompletionDate', '')::timestamptz,
             nullif(t->>'totalCost', '')::numeric,
             t->'primaryGroup'->>'name',
             t->'driver'->>'name',
             false, null, now(), t
        from f
      on conflict (numero) do update set
        movil = excluded.movil, estado = excluded.estado, tipo = excluded.tipo,
        afecta_disponib = excluded.afecta_disponib, motivo = excluded.motivo, falla = excluded.falla,
        taller = excluded.taller, etiquetas = excluded.etiquetas,
        fecha_taller = excluded.fecha_taller, fecha_inicio = excluded.fecha_inicio,
        fin_estimado = excluded.fin_estimado, odometro = excluded.odometro,
        cierre_tecnico_en = excluded.cierre_tecnico_en, cierre_final_en = excluded.cierre_final_en,
        costo_total = excluded.costo_total, grupo = excluded.grupo, conductor = excluded.conductor,
        fuera_listado = false, salio_en = null, vista_en = now(), crudo = excluded.crudo;

      select coalesce(array_agg((t->>'number')::int), '{}') into v_ids
        from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$';
      v_vistos := v_vistos || v_ids;
      v_filas  := v_filas + coalesce(v_n, 0);
      v_nuevas := v_nuevas + coalesce(v_nn, 0);

      v_url := v_r->>'next';
      exit when coalesce(v_url, '') = '' or v_pag >= 12;
    end loop;
  end loop;

  -- La orden que ya no vino en el listado se cerró (o se anuló). Solo se marcan las que
  -- CAEN EN LA VENTANA consultada: una orden más vieja que eso no vino porque no se
  -- preguntó por ella, no porque la hubieran cerrado.
  update public.taller_ordenes
     set fuera_listado = true, salio_en = coalesce(salio_en, now())
   where not fuera_listado
     and numero <> all (v_vistos)
     and fecha_inicio >= (v_desde::timestamptz);
  get diagnostics v_cerradas = row_count;

  insert into public.taller_sync (que, filas, nuevas, ms)
  values ('ordenes', v_filas, v_nuevas, (extract(milliseconds from clock_timestamp() - v_t0))::int);

  return jsonb_build_object('ok', true, 'filas', v_filas, 'nuevas', v_nuevas, 'cerradas', v_cerradas);
end $fn$;
revoke all on function public.taller_sync_ordenes() from public, anon;
grant execute on function public.taller_sync_ordenes() to authenticated;

-- ---------- 10) Traer las novedades sin resolver ----------
create or replace function public.taller_sync_novedades()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_t0 timestamptz := clock_timestamp();
  v_url text := 'issues/?includeDone=false';
  v_pag int := 0; v_r jsonb; v_arr jsonb; v_n int; v_nn int;
  v_ids int[]; v_vistos int[] := '{}'; v_filas int := 0; v_nuevas int := 0; v_resueltas int := 0;
begin
  if not public.taller_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede sincronizar el taller.';
  end if;

  loop
    v_pag := v_pag + 1;
    v_r := public.taller_http(v_url);
    if not coalesce((v_r->>'ok')::boolean, false) then
      insert into public.taller_sync (que, error, ms)
      values ('novedades', left(v_r->>'error', 300),
              (extract(milliseconds from clock_timestamp() - v_t0))::int);
      return v_r;
    end if;
    v_arr := v_r->'datos';
    exit when jsonb_typeof(v_arr) <> 'array';

    select count(*) into v_n from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$';
    select count(*) into v_nn from jsonb_array_elements(v_arr) t
     where (t->>'number') ~ '^[0-9]+$'
       and not exists (select 1 from public.taller_novedades n where n.numero = (t->>'number')::int);

    with f as (select t from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$')
    insert into public.taller_novedades as n (
      numero, movil, reportada_en, prioridad, observacion, reportada_por, responsable,
      resuelta, resuelta_en, orden_numero, desde_checklist, odometro, vista_en, crudo)
    select (t->>'number')::int,
           btrim(coalesce(t->>'vehicleCode', '')),
           nullif(t->>'reportedAt', '')::timestamptz,
           -- sí, el campo viene mal escrito desde CloudFleet: `prority`
           coalesce(t->>'prority', t->>'priority'),
           nullif(btrim(coalesce(t->>'comment', '')), ''),
           t->'reporter'->>'name',
           t->'responsible'->>'name',
           coalesce((t->>'isDone')::boolean, false),
           nullif(t->>'doneAt', '')::timestamptz,
           nullif(t->>'workOrderDoneNumber', '')::int,
           nullif(t->>'fromChecklistNumber', '')::int,
           nullif(t->>'odometer', '')::numeric,
           now(), t
      from f
    on conflict (numero) do update set
      movil = excluded.movil, reportada_en = excluded.reportada_en, prioridad = excluded.prioridad,
      observacion = excluded.observacion, reportada_por = excluded.reportada_por,
      responsable = excluded.responsable, resuelta = excluded.resuelta,
      resuelta_en = excluded.resuelta_en, orden_numero = excluded.orden_numero,
      desde_checklist = excluded.desde_checklist, odometro = excluded.odometro,
      vista_en = now(), crudo = excluded.crudo;

    select coalesce(array_agg((t->>'number')::int), '{}') into v_ids
      from jsonb_array_elements(v_arr) t where (t->>'number') ~ '^[0-9]+$';
    v_vistos := v_vistos || v_ids;
    v_filas  := v_filas + coalesce(v_n, 0);
    v_nuevas := v_nuevas + coalesce(v_nn, 0);

    v_url := v_r->>'next';
    exit when coalesce(v_url, '') = '' or v_pag >= 12;
  end loop;

  -- Se pidieron solo las pendientes: la que teníamos y ya no aparece, la resolvieron.
  update public.taller_novedades
     set resuelta = true, resuelta_en = coalesce(resuelta_en, now())
   where not resuelta and numero <> all (v_vistos);
  get diagnostics v_resueltas = row_count;

  insert into public.taller_sync (que, filas, nuevas, ms)
  values ('novedades', v_filas, v_nuevas, (extract(milliseconds from clock_timestamp() - v_t0))::int);

  return jsonb_build_object('ok', true, 'filas', v_filas, 'nuevas', v_nuevas, 'resueltas', v_resueltas);
end $fn$;
revoke all on function public.taller_sync_novedades() from public, anon;
grant execute on function public.taller_sync_novedades() to authenticated;

-- ---------- 11) Traer la programación de mantenimiento ----------
create or replace function public.taller_sync_programacion()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  cfg public.taller_config%rowtype;
  v_t0 timestamptz := clock_timestamp();
  v_hoy date; v_url text; v_pag int := 0;
  v_r jsonb; v_arr jsonb; v_n int; v_nn int;
  v_filas int := 0; v_nuevas int := 0; v_viejas int := 0;
begin
  if not public.taller_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede sincronizar el taller.';
  end if;
  select * into cfg from public.taller_config where id = 1;
  v_hoy := (now() at time zone 'America/Bogota')::date;

  v_url := 'maintenance-schedules/?dateToExecuteFrom=' || to_char(v_hoy - cfg.prog_atras, 'YYYY-MM-DD') || 'T00:00:00Z'
        || '&dateToExecuteTo=' || to_char(v_hoy + cfg.prog_adelante, 'YYYY-MM-DD') || 'T23:59:59Z';

  loop
    v_pag := v_pag + 1;
    v_r := public.taller_http(v_url);
    if not coalesce((v_r->>'ok')::boolean, false) then
      insert into public.taller_sync (que, error, ms)
      values ('programacion', left(v_r->>'error', 300),
              (extract(milliseconds from clock_timestamp() - v_t0))::int);
      return v_r;
    end if;
    v_arr := v_r->'datos';
    exit when jsonb_typeof(v_arr) <> 'array';

    select count(*) into v_n from jsonb_array_elements(v_arr) t where (t->>'consecutive') ~ '^[0-9]+$';
    select count(*) into v_nn from jsonb_array_elements(v_arr) t
     where (t->>'consecutive') ~ '^[0-9]+$'
       and not exists (select 1 from public.taller_programacion p where p.consecutivo = (t->>'consecutive')::int);

    with f as (select t from jsonb_array_elements(v_arr) t where (t->>'consecutive') ~ '^[0-9]+$')
    insert into public.taller_programacion as p (
      consecutivo, movil, trabajo, rutina, estado, fecha_ejecutar, dias_dif,
      odom_objetivo, odom_dif, orden_creada, orden_ejecucion, fuente, tipo, vista_en, crudo)
    select (t->>'consecutive')::int,
           btrim(coalesce(t->'vehicle'->>'code', '')),
           t->'task'->>'name',
           t->'routine'->>'name',
           t->>'status',
           nullif(t->>'dateToExecute', '')::timestamptz,
           nullif(t->>'dateToExecuteDaysDiff', '')::numeric,
           nullif(t->>'odometerToExecute', '')::numeric,
           nullif(t->>'odometerToExecuteDiff', '')::numeric,
           nullif(t->'woCreation'->>'number', '')::int,
           nullif(t->'woExecution'->>'number', '')::int,
           t->>'scheduleSource', t->>'scheduleType', now(), t
      from f
    on conflict (consecutivo) do update set
      movil = excluded.movil, trabajo = excluded.trabajo, rutina = excluded.rutina,
      estado = excluded.estado, fecha_ejecutar = excluded.fecha_ejecutar,
      dias_dif = excluded.dias_dif, odom_objetivo = excluded.odom_objetivo,
      odom_dif = excluded.odom_dif, orden_creada = excluded.orden_creada,
      orden_ejecucion = excluded.orden_ejecucion, fuente = excluded.fuente,
      tipo = excluded.tipo, vista_en = now(), crudo = excluded.crudo;

    v_filas  := v_filas + coalesce(v_n, 0);
    v_nuevas := v_nuevas + coalesce(v_nn, 0);
    v_url := v_r->>'next';
    exit when coalesce(v_url, '') = '' or v_pag >= 12;
  end loop;

  -- Las que estaban en la ventana y ya no vinieron (les movieron la fecha, o se ejecutaron
  -- y salieron del rango) se borran: si no, quedarían "vencidas" para siempre.
  delete from public.taller_programacion
   where fecha_ejecutar >= (v_hoy - cfg.prog_atras)::timestamptz
     and fecha_ejecutar <  (v_hoy + cfg.prog_adelante + 1)::timestamptz
     and vista_en < v_t0;
  get diagnostics v_viejas = row_count;

  insert into public.taller_sync (que, filas, nuevas, ms)
  values ('programacion', v_filas, v_nuevas, (extract(milliseconds from clock_timestamp() - v_t0))::int);

  return jsonb_build_object('ok', true, 'filas', v_filas, 'nuevas', v_nuevas, 'salieron', v_viejas);
end $fn$;
revoke all on function public.taller_sync_programacion() from public, anon;
grant execute on function public.taller_sync_programacion() to authenticated;

-- ---------- 12) La traída completa (lo que corre el cron) ----------
create or replace function public.taller_sync_todo()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare v_o jsonb; v_n jsonb; v_p jsonb;
begin
  if not public.taller_puede_traer() then
    raise exception 'Solo administración (o la traída automática) puede sincronizar el taller.';
  end if;
  -- Cada una aparte: si el taller tiene un problema con las novedades, la programación
  -- igual entra. Y al revés.
  begin v_o := public.taller_sync_ordenes();
  exception when others then v_o := jsonb_build_object('ok', false, 'error', sqlerrm); end;
  begin v_n := public.taller_sync_novedades();
  exception when others then v_n := jsonb_build_object('ok', false, 'error', sqlerrm); end;
  begin v_p := public.taller_sync_programacion();
  exception when others then v_p := jsonb_build_object('ok', false, 'error', sqlerrm); end;
  return jsonb_build_object('ok', true, 'ordenes', v_o, 'novedades', v_n, 'programacion', v_p);
end $fn$;
revoke all on function public.taller_sync_todo() from public, anon;
grant execute on function public.taller_sync_todo() to authenticated;

-- ---------- 13) El aviso del despacho: ¿este móvil está en el taller? ----------
-- Esto lo llama el despachador al elegir el móvil, así que lee del espejo (nunca de la
-- API) y va por el índice parcial de órdenes abiertas. Devuelve también hace cuánto se
-- actualizó el espejo: si el cron está caído, la pantalla lo dice en vez de mentir.
create or replace function public.taller_estado_movil(p_movil text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_mov text := btrim(coalesce(p_movil, ''));
  v_ord jsonb; v_nov jsonb; v_prog jsonb;
  v_abiertas int := 0; v_afectan int := 0; v_min int;
begin
  if not ( (select public.es_admin()) or (select public.es_operaciones())
        or (select public.es_despachador()) or (select public.es_auditor()) ) then
    return jsonb_build_object('en_taller', false);
  end if;
  if v_mov = '' then return jsonb_build_object('en_taller', false); end if;

  select coalesce(jsonb_agg(x order by x->>'afecta' desc, (x->>'dias')::int desc), '[]'::jsonb),
         count(*), count(*) filter (where (x->>'afecta')::boolean)
    into v_ord, v_abiertas, v_afectan
    from (
      select jsonb_build_object(
               'numero', o.numero, 'tipo', o.tipo, 'motivo', left(coalesce(o.motivo, o.falla, ''), 180),
               'taller', o.taller, 'afecta', o.afecta_disponib,
               'desde', o.fecha_inicio,
               'dias', greatest(((now() at time zone 'America/Bogota')::date
                                 - (o.fecha_inicio at time zone 'America/Bogota')::date), 0),
               'etiquetas', coalesce(o.etiquetas, '{}')) as x
        from public.taller_ordenes o
       where o.movil = v_mov and o.estado = 'opened' and not o.fuera_listado) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'numero', n.numero, 'prioridad', n.prioridad,
           'texto', left(coalesce(n.observacion, ''), 160),
           'dias', greatest(((now() at time zone 'America/Bogota')::date
                             - (n.reportada_en at time zone 'America/Bogota')::date), 0))
         order by case n.prioridad when 'high' then 0 when 'medium' then 1 else 2 end,
                  n.reportada_en), '[]'::jsonb)
    into v_nov
    from public.taller_novedades n
   where n.movil = v_mov and not n.resuelta;

  select coalesce(jsonb_agg(jsonb_build_object(
           'trabajo', coalesce(p.trabajo, p.rutina), 'estado', p.estado,
           'fecha', p.fecha_ejecutar, 'dias', p.dias_dif)
         order by p.fecha_ejecutar), '[]'::jsonb)
    into v_prog
    from public.taller_programacion p
   where p.movil = v_mov and p.estado in ('Vencido', 'Vence hoy');

  select (extract(epoch from (now() - max(cuando))) / 60)::int into v_min
    from public.taller_sync where error is null;

  return jsonb_build_object(
    'en_taller', (v_abiertas > 0),
    'abiertas', v_abiertas,
    'afectan', v_afectan,          -- órdenes que dejan el bus fuera de servicio
    'ordenes', v_ord,
    'novedades', v_nov,
    'programacion', v_prog,
    'sync_hace_min', v_min);
end $fn$;
revoke all on function public.taller_estado_movil(text) from public, anon;
grant execute on function public.taller_estado_movil(text) to authenticated;

-- ---------- 14) El tablero del taller (operaciones, auditoría, admin) ----------
create or replace function public.taller_tablero()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v jsonb; v_min int; v_err text; v_falta boolean;
begin
  if not ( (select public.es_admin()) or (select public.es_operaciones()) or (select public.es_auditor()) ) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración, operaciones y auditoría.');
  end if;

  select (extract(epoch from (now() - max(cuando))) / 60)::int into v_min
    from public.taller_sync where error is null;
  select left(error, 200) into v_err
    from public.taller_sync where error is not null order by cuando desc limit 1;
  v_falta := not exists (select 1 from public.taller_sync);

  select jsonb_build_object(
    'abiertas',      count(*) filter (where estado = 'opened' and not fuera_listado),
    'afectan',       count(*) filter (where estado = 'opened' and not fuera_listado and afecta_disponib),
    'correctivas',   count(*) filter (where estado = 'opened' and not fuera_listado and tipo = 'CORRECTIVO'),
    'cierre_tecnico',count(*) filter (where estado = 'onTechnicalCompletion' and not fuera_listado),
    'viejas',        count(*) filter (where estado = 'opened' and not fuera_listado
                                        and fecha_inicio < (v_hoy - 7)::timestamptz))
    into v from public.taller_ordenes;

  return jsonb_build_object('ok', true, 'sync_hace_min', v_min, 'sin_traer', v_falta, 'ultimo_error', v_err,
    'ordenes', v,
    'lista', (select coalesce(jsonb_agg(jsonb_build_object(
                'numero', o.numero, 'movil', o.movil, 'tipo', o.tipo, 'estado', o.estado,
                'afecta', o.afecta_disponib, 'taller', o.taller, 'grupo', o.grupo,
                'motivo', left(coalesce(o.motivo, o.falla, ''), 200),
                'etiquetas', coalesce(o.etiquetas, '{}'),
                'desde', o.fecha_inicio, 'fin_estimado', o.fin_estimado,
                'dias', greatest((v_hoy - (o.fecha_inicio at time zone 'America/Bogota')::date), 0),
                'costo', o.costo_total)
              order by o.afecta_disponib desc, o.fecha_inicio), '[]'::jsonb)
              from public.taller_ordenes o
             where o.estado = 'opened' and not o.fuera_listado),
    'represadas', (select coalesce(jsonb_agg(jsonb_build_object(
                'numero', o.numero, 'movil', o.movil, 'tipo', o.tipo,
                'cierre_tecnico', o.cierre_tecnico_en,
                'dias', greatest((v_hoy - (o.cierre_tecnico_en at time zone 'America/Bogota')::date), 0))
              order by o.cierre_tecnico_en), '[]'::jsonb)
              from public.taller_ordenes o
             where o.estado = 'onTechnicalCompletion' and not o.fuera_listado
               and o.cierre_tecnico_en < (v_hoy - 7)::timestamptz),
    'novedades', (select coalesce(jsonb_agg(jsonb_build_object(
                'numero', n.numero, 'movil', n.movil, 'prioridad', n.prioridad,
                'texto', left(coalesce(n.observacion, ''), 200), 'reporto', n.reportada_por,
                'desde_checklist', n.desde_checklist, 'cuando', n.reportada_en,
                'dias', greatest((v_hoy - (n.reportada_en at time zone 'America/Bogota')::date), 0))
              order by case n.prioridad when 'high' then 0 when 'medium' then 1 else 2 end, n.reportada_en),
              '[]'::jsonb)
              from public.taller_novedades n where not n.resuelta),
    'prog', (select jsonb_build_object(
                'vencidas',   count(*) filter (where estado = 'Vencido'),
                'hoy',        count(*) filter (where estado = 'Vence hoy'),
                'proximas',   count(*) filter (where estado = 'Próximo'),
                'moviles',    count(distinct movil) filter (where estado in ('Vencido', 'Vence hoy')))
              from public.taller_programacion),
    'prog_lista', (select coalesce(jsonb_agg(jsonb_build_object(
                'movil', p.movil, 'trabajo', coalesce(p.trabajo, p.rutina), 'estado', p.estado,
                'fecha', p.fecha_ejecutar, 'dias', p.dias_dif, 'orden', p.orden_creada)
              order by p.fecha_ejecutar), '[]'::jsonb)
              from public.taller_programacion p
             where p.estado in ('Vencido', 'Vence hoy')));
end $fn$;
revoke all on function public.taller_tablero() from public, anon;
grant execute on function public.taller_tablero() to authenticated;

-- ---------- 15) Reportarle una falla al taller ----------
-- El despachador o el auditor ve algo y lo manda: entra a CloudFleet como Novedad de
-- Mantenimiento, en la misma bandeja donde el taller recibe las de los conductores.
-- En CloudFleet la novedad sale a nombre de la persona "API" (la API exige un id de
-- persona existente), así que el comentario arranca diciendo quién la reportó de verdad
-- y queda además en taller_novedades_app con correo y rol.
create or replace function public.taller_novedad_enviar(
  p_movil text, p_prioridad text, p_texto text,
  p_odometro numeric default null, p_intervencion bigint default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  cfg public.taller_config%rowtype;
  v_mov text := btrim(coalesce(p_movil, ''));
  v_pri text := lower(btrim(coalesce(p_prioridad, '')));
  v_txt text := btrim(coalesce(p_texto, ''));
  v_correo text := coalesce(auth.jwt() ->> 'email', '');
  v_nombre text; v_rol text; v_quien text; v_body text; v_r jsonb; v_num int; v_id bigint;
begin
  if not ( (select public.es_admin()) or (select public.es_operaciones())
        or (select public.es_despachador()) or (select public.es_auditor()) ) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para reportarle al taller.');
  end if;
  select * into cfg from public.taller_config where id = 1;
  if not coalesce(cfg.activo, false) then
    return jsonb_build_object('ok', false, 'error', 'La integración con el taller está apagada.');
  end if;
  if coalesce(cfg.reporta_por_id, 0) = 0 then
    return jsonb_build_object('ok', false, 'error',
      'Falta configurar con qué persona de CloudFleet se reportan las novedades (taller_config.reporta_por_id).');
  end if;

  if v_mov = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el móvil.');
  end if;
  if v_pri not in ('low', 'medium', 'high') then
    return jsonb_build_object('ok', false, 'error', 'La prioridad debe ser baja, media o urgente.');
  end if;
  if length(v_txt) < 15 then
    return jsonb_build_object('ok', false, 'error',
      'Describe la falla con detalle: el mecánico tiene que entender qué revisar sin llamar a nadie.');
  end if;
  if not exists (select 1 from public.parque_automotor where numero_interno = v_mov) then
    return jsonb_build_object('ok', false, 'error', 'Ese móvil no existe en el parque automotor.');
  end if;

  select p.nombre, p.rol into v_nombre, v_rol from public.perfiles p where p.email = v_correo;
  v_quien := coalesce(nullif(btrim(coalesce(v_nombre, '')), ''), v_correo);

  insert into public.taller_novedades_app (movil, prioridad, texto, odometro, intervencion_id,
                                           enviado_por, nombre, rol)
  values (v_mov, v_pri, v_txt, p_odometro, p_intervencion, v_correo, v_nombre, v_rol)
  returning id into v_id;

  v_body := jsonb_build_object(
    'vehicleCode', v_mov,
    'reportedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'reportedById', cfg.reporta_por_id,
    'priority', v_pri,                                  -- al crear va bien escrito
    'odometer', p_odometro,
    'comment', left('[App de despachos · ' || coalesce(v_rol, 'usuario') || ' ' || v_quien || '] ' || v_txt, 1000),
    'sendMail', false)::text;

  v_r := public.taller_http('issues', 'POST', v_body);
  if not coalesce((v_r->>'ok')::boolean, false) then
    update public.taller_novedades_app set error = left(v_r->>'error', 300) where id = v_id;
    return v_r;
  end if;

  v_num := nullif(v_r->'datos'->>'number', '')::int;
  update public.taller_novedades_app set cf_numero = v_num where id = v_id;

  -- Que aparezca de una en el espejo, sin esperar los 15 minutos del cron.
  if v_num is not null then
    insert into public.taller_novedades (numero, movil, reportada_en, prioridad, observacion,
                                         reportada_por, resuelta, odometro, crudo)
    values (v_num, v_mov, now(), v_pri,
            left('[App de despachos · ' || coalesce(v_rol, 'usuario') || ' ' || v_quien || '] ' || v_txt, 1000),
            v_quien, false, p_odometro, v_r->'datos')
    on conflict (numero) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'numero', v_num);
end $fn$;
revoke all on function public.taller_novedad_enviar(text, text, text, numeric, bigint) from public, anon;
grant execute on function public.taller_novedad_enviar(text, text, text, numeric, bigint) to authenticated;

-- ---------- 16) Cambiar la configuración (solo admin) ----------
create or replace function public.taller_config_guardar(
  p_activo boolean default null, p_reporta_por_id int default null,
  p_prog_atras int default null, p_prog_adelante int default null, p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración.');
  end if;
  update public.taller_config
     set activo = coalesce(p_activo, activo),
         reporta_por_id = coalesce(p_reporta_por_id, reporta_por_id),
         prog_atras = coalesce(p_prog_atras, prog_atras),
         prog_adelante = coalesce(p_prog_adelante, prog_adelante),
         nota = coalesce(nullif(btrim(coalesce(p_nota, '')), ''), nota),
         actualizado_en = now(), actualizado_por = coalesce(auth.jwt() ->> 'email', 'sistema')
   where id = 1;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.taller_config_guardar(boolean, int, int, int, text) from public, anon;
grant execute on function public.taller_config_guardar(boolean, int, int, int, text) to authenticated;

-- ---------- 17) La traída automática ----------
-- Cada 15 minutos: ~7 llamadas por vuelta, unas 700 al día contra el techo de 4000.
-- Si se necesita más fino, bajar a */10 sigue sobrando (1000 al día).
select cron.unschedule('taller-sync') where exists (select 1 from cron.job where jobname = 'taller-sync');
select cron.schedule('taller-sync', '*/15 * * * *', $$ select public.taller_sync_todo(); $$);

-- ===================================================================================
-- Para arrancar (en este orden):
--   1) Vault: crear el secreto CF_API_KEY con la llave de CloudFleet.
--   2) select public.taller_sync_todo();          -- la primera traída, a mano
--   3) select public.taller_tablero();            -- confirmar que llegó
-- ===================================================================================
