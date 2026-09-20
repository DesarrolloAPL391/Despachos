-- ============================================================================================
-- 84) SEGURIDAD VIAL: una categoría simple para las pantallas
--
-- En el menú, "Seguridad vial" agrupa tres cosas: los siniestros, los excesos de velocidad y las
-- puertas abiertas en marcha. Para que la tabla de eventos se pueda abrir directamente filtrada
-- por cada una, se agrega una categoría calculada:
--     tipo 'exceso' | 'velocidad'  → 'VELOCIDAD'       (pasó de 60 o superó el límite de la vía)
--     tipo 'puerta'                → 'PUERTA ABIERTA'  (rodó con la puerta abierta)
-- Es una columna generada: no hay que mantenerla ni puede quedar desincronizada.
--
-- Se aplica sobre una base con sql/81, 82 y 83 ya ejecutados.
-- ============================================================================================

alter table public.eventos_bus
  add column if not exists categoria text
  generated always as (case when tipo = 'puerta' then 'PUERTA ABIERTA' else 'VELOCIDAD' end) stored;

create index if not exists eventos_bus_categoria_idx on public.eventos_bus (categoria, fecha desc);

comment on column public.eventos_bus.categoria is
  'VELOCIDAD (exceso o más de 60) | PUERTA ABIERTA. Calculada desde `tipo`, para el menú Seguridad vial.';
