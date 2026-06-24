-- ============================================================
--  Esquema: Despachos de vehículos (APL)
--  Diseño normalizado. Generado a partir de "aplp delibre.csv"
-- ============================================================

-- ---------- Función para updated_at ----------
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

create table if not exists propietarios (
  id          bigint generated always as identity primary key,
  nombre      text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists vehiculos (
  id              bigint generated always as identity primary key,
  numero          text,                                   -- "vehiculo" (móvil / número interno)
  placa           text unique,                            -- PLACA
  propietario_id  bigint references propietarios(id),     -- PROPIETARIO
  created_at      timestamptz not null default now()
);

create table if not exists conductores (
  id          bigint generated always as identity primary key,
  codigo      text unique,        -- codigo
  nombre      text,               -- conductor
  created_at  timestamptz not null default now()
);

create table if not exists rutas (
  id          bigint generated always as identity primary key,
  nombre      text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists despachadores (
  id          bigint generated always as identity primary key,
  nombre      text not null unique,
  created_at  timestamptz not null default now()
);

create table if not exists auditores (
  id          bigint generated always as identity primary key,
  nombre      text not null unique,
  created_at  timestamptz not null default now()
);

-- ============================================================
--  TABLA PRINCIPAL: DESPACHOS
-- ============================================================

create table if not exists despachos (
  id                          text primary key,                       -- KEY (id único del despacho)
  validacion                  text,                                   -- validacion
  fecha                       date,                                   -- fecha
  mes                         smallint generated always as (extract(month from fecha)) stored,
  hora                        time,                                   -- hora

  -- ----- Lo PROGRAMADO -----
  vehiculo_programado_id      bigint references vehiculos(id),        -- vehiculo programado
  hora_programada             time,                                   -- hora programada
  ruta_programada_id          bigint references rutas(id),            -- ruta programada

  -- ----- Lo REAL -----
  vehiculo_id                 bigint references vehiculos(id),        -- vehiculo
  conductor_id                bigint references conductores(id),      -- codigo / conductor
  ruta_id                     bigint references rutas(id),            -- ruta
  despachador_id              bigint references despachadores(id),    -- despachador
  ubicacion                   text,                                   -- ubicacion
  viajes                      integer,                                -- viajes
  hora_real_despacho          time,                                   -- hora real despacho

  -- ----- Banderas (SI/NO -> boolean) -----
  despachado                  boolean,                                -- despachado?
  completo                    boolean,                                -- COMPLETO SI/NO
  cambio                      boolean,                                -- cambio
  perdida_deliberada_tiempo   boolean,                                -- PÉRDIDA DELIBERADA DE TIEMPO SI/NO
  abandono_ruta               boolean,                                -- ABANDONO DE RUTA SI/NO

  -- ----- Resultado del viaje -----
  hora_finalizacion           time,                                   -- HORA DE FINALIZACIÓN
  duracion_viaje              interval,                               -- DURACIÓN VIAJE
  hora_llegada                time,                                   -- HORA DE LLEGADA
  estado                      text,                                   -- ESTADO

  -- ----- Auditoría / control -----
  novedades                   text,                                   -- NOVEDADES
  observacion                 text,                                   -- OBSERVACIÓN
  auditor_id                  bigint references auditores(id),        -- AUDITADOR
  fecha_hora_auditoria        timestamptz,                            -- FECHA Y HORA AUDITORIA
  control_interno             text,                                   -- CONTROL INTERNO
  hora_llegada_control        time,                                   -- HORA LLEGADA CONTROL
  hora_salida_control         time,                                   -- HORA DE SALIDA CONTROL

  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create trigger trg_despachos_updated_at
  before update on despachos
  for each row execute function set_updated_at();

-- ============================================================
--  DETALLE: ABANDONOS DE RUTA (reemplaza las columnas 1/2/3)
-- ============================================================

create table if not exists abandonos_ruta (
  id          bigint generated always as identity primary key,
  despacho_id text not null references despachos(id) on delete cascade,
  secuencia   smallint,        -- 1, 2, 3 ...
  hora        time,            -- HORA ABANDONO DE RUTA n
  direccion   text,            -- DIRECCIÓN ABANDONO DE RUTA n
  created_at  timestamptz not null default now()
);

-- ============================================================
--  ÍNDICES
-- ============================================================
create index if not exists idx_despachos_fecha          on despachos(fecha);
create index if not exists idx_despachos_estado         on despachos(estado);
create index if not exists idx_despachos_vehiculo       on despachos(vehiculo_id);
create index if not exists idx_despachos_conductor      on despachos(conductor_id);
create index if not exists idx_despachos_ruta           on despachos(ruta_id);
create index if not exists idx_abandonos_despacho       on abandonos_ruta(despacho_id);
create index if not exists idx_vehiculos_propietario    on vehiculos(propietario_id);

-- ============================================================
--  SEGURIDAD: RLS activado (secure-by-default)
--  El dashboard y la service_role lo omiten. Para acceso
--  con la anon key habrá que crear políticas después.
-- ============================================================
alter table propietarios   enable row level security;
alter table vehiculos      enable row level security;
alter table conductores    enable row level security;
alter table rutas          enable row level security;
alter table despachadores  enable row level security;
alter table auditores      enable row level security;
alter table despachos      enable row level security;
alter table abandonos_ruta enable row level security;
