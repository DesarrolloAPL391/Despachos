-- ============================================================
--  Esquema CORREGIDO: Despachos de vehículos (APL)
--  Ajustado a los datos reales de "base de datossss.csv"
--  - validacion = estación (catálogo)
--  - viajes     = placa del vehículo
--  - despachado?/cambio = texto
-- ============================================================

-- Quitamos las tablas anteriores (no tenían datos)
drop table if exists abandonos_ruta cascade;
drop table if exists despachos     cascade;
drop table if exists vehiculos     cascade;
drop table if exists conductores   cascade;
drop table if exists rutas         cascade;
drop table if exists despachadores cascade;
drop table if exists auditores     cascade;
drop table if exists propietarios  cascade;
drop table if exists estaciones    cascade;
drop table if exists stg_despachos cascade;

-- ---------- updated_at ----------
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================
--  CATÁLOGOS
-- ============================================================
create table estaciones (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  created_at timestamptz not null default now()
);

create table propietarios (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  created_at timestamptz not null default now()
);

create table vehiculos (
  id bigint generated always as identity primary key,
  numero text not null unique,             -- móvil (col "vehiculo")
  placa text,                              -- placa (col "viajes")
  propietario_id bigint references propietarios(id),
  created_at timestamptz not null default now()
);

create table conductores (
  id bigint generated always as identity primary key,
  nombre text not null unique,             -- "conductor" (el código va en despachos)
  created_at timestamptz not null default now()
);

create table rutas (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  created_at timestamptz not null default now()
);

create table despachadores (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  created_at timestamptz not null default now()
);

create table auditores (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  created_at timestamptz not null default now()
);

-- ============================================================
--  DESPACHOS
-- ============================================================
create table despachos (
  id                          text primary key,                  -- KEY
  estacion_id                 bigint references estaciones(id),   -- validacion
  fecha                       date,
  mes                         smallint generated always as (extract(month from fecha)) stored,
  hora                        time,                               -- hora (turno)

  -- programado
  vehiculo_programado_id      bigint references vehiculos(id),
  hora_programada             time,
  ruta_programada_id          bigint references rutas(id),

  -- real
  vehiculo_id                 bigint references vehiculos(id),
  codigo                      text,                               -- "codigo" (turno)
  conductor_id                bigint references conductores(id),
  ruta_id                     bigint references rutas(id),
  despachador_id              bigint references despachadores(id),
  ubicacion                   text,                               -- coordenadas GPS "lat, lng"
  estado_despacho             text,                               -- DESPACHADO / NO REALIZA EL VIAJE
  cambio                      text,                               -- TABLA, ...
  hora_real_despacho          time,

  -- resultado
  hora_finalizacion           time,
  duracion_viaje              interval,
  completo                    boolean,
  perdida_deliberada_tiempo   boolean,
  abandono_ruta               boolean,
  hora_llegada                time,
  estado                      text,                               -- PESCA / TALLER / ...

  -- auditoría
  novedades                   text,
  observacion                 text,
  auditor_id                  bigint references auditores(id),
  fecha_hora_auditoria        timestamptz,
  control_interno             text,
  hora_llegada_control        time,
  hora_salida_control         time,

  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create trigger trg_despachos_updated_at
  before update on despachos
  for each row execute function set_updated_at();

create table abandonos_ruta (
  id bigint generated always as identity primary key,
  despacho_id text not null references despachos(id) on delete cascade,
  secuencia smallint,
  hora time,
  direccion text,
  created_at timestamptz not null default now()
);

-- ============================================================
--  ÍNDICES
-- ============================================================
create index idx_despachos_fecha     on despachos(fecha);
create index idx_despachos_estacion  on despachos(estacion_id);
create index idx_despachos_estado    on despachos(estado);
create index idx_despachos_vehiculo  on despachos(vehiculo_id);
create index idx_despachos_conductor on despachos(conductor_id);
create index idx_despachos_ruta      on despachos(ruta_id);
create index idx_abandonos_despacho  on abandonos_ruta(despacho_id);

-- ============================================================
--  STAGING (carga cruda, todo texto)
-- ============================================================
create table stg_despachos (
  key text, validacion text, fecha text, vehiculo text, hora text, ruta text,
  despachado text, codigo text, conductor text, viajes text, despachador text,
  ubicacion text, veh_prog text, hora_prog text, ruta_prog text, cambio text,
  hora_real text, mes text, hora_fin text, duracion text, completo text,
  placa text, propietario text, perdida text, abandono text,
  h_ab1 text, h_ab2 text, h_ab3 text, d_ab1 text, d_ab2 text, d_ab3 text,
  novedades text, observacion text, auditador text, fecha_aud text,
  control_interno text, h_lleg_control text, h_sal_control text, estado text, hora_llegada text
);

-- ============================================================
--  RLS
-- ============================================================
alter table estaciones    enable row level security;
alter table propietarios  enable row level security;
alter table vehiculos     enable row level security;
alter table conductores   enable row level security;
alter table rutas         enable row level security;
alter table despachadores enable row level security;
alter table auditores     enable row level security;
alter table despachos     enable row level security;
alter table abandonos_ruta enable row level security;
