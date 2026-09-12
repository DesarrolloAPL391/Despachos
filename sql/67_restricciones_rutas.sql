-- 67: RESTRICCIONES DE RUTAS (registro de novedades/castigos por incumplir itinerarios).
-- Origen: CSV "restricciones rutas" (control/operaciones). En modo local mientras se ajusta.
-- PK propia (id); el KEY del CSV se guarda como key_origen (no es 100% único: 813/815).

create table if not exists public.restricciones_rutas (
  id                  bigint generated always as identity primary key,
  key_origen          text,                        -- KEY del CSV
  ruta                text,                        -- RUTA INFRACCIÓN (ej: 190, 192, Laureles)
  fecha_novedad       date,
  fecha_restriccion   date,
  vehiculo            text,                        -- número interno del móvil
  novedad             text,
  conductor           text,
  viajes_hora         text,                        -- VIAJES - HORA A RESTRINGIR
  hora_inicial        time,
  hora_finalizacion   time,
  estado              text not null default 'VIGENTE'
                        check (estado in ('VIGENTE','CANCELADA')),
  observaciones       text,
  usuario             text,
  accion_usuario      text,
  propietario         text,
  despachador_am      text,
  numero_am           text,
  despachador_pm      text,
  numero_pm           text,
  correo_propietario  text,
  celular_propietario text,
  creado_en           timestamptz not null default now()
);
create index if not exists restricciones_veh_idx    on public.restricciones_rutas (vehiculo);
create index if not exists restricciones_estado_idx on public.restricciones_rutas (estado);
create index if not exists restricciones_fecha_idx  on public.restricciones_rutas (fecha_novedad desc);
create index if not exists restricciones_ruta_idx   on public.restricciones_rutas (ruta);

alter table public.restricciones_rutas enable row level security;

-- Lectura: control (admin, operaciones, auditor) y despachadores.
drop policy if exists restricciones_sel on public.restricciones_rutas;
create policy restricciones_sel on public.restricciones_rutas
  for select to authenticated
  using ( (select public.es_admin()) or (select public.es_despachador())
       or (select public.es_auditor()) or (select public.es_operaciones()) );

-- Escritura: admin y operaciones (control) — se ajustará más adelante.
drop policy if exists restricciones_write on public.restricciones_rutas;
create policy restricciones_write on public.restricciones_rutas
  for all to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) )
  with check ( (select public.es_admin()) or (select public.es_operaciones()) );

grant select, insert, update, delete on public.restricciones_rutas to authenticated;
