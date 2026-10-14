-- 126_horarios_puntos_despacho.sql  (v322)
-- HORA REAL DE ENTRADA POR PUNTO DE DESPACHO.
--
-- Por que existe esta tabla: la puntualidad se estaba midiendo contra
-- `horarios.hora_inicio` (03:30 / 12:30), que es la franja en la que el despachador PUEDE
-- ENTRAR AL APLICATIVO, no la hora a la que debe estar en su punto. Por eso el tablero
-- marcaba tarde a todo el turno de la madrugada: la mediana de marcacion era 04:53 contra
-- una referencia de 03:30. Medido sobre 141 marcaciones de 7 dias (13/10/2026).
--
-- La hora que manda es la de este cuadro, que entrego la empresa
-- ("HORARIOS DE PUNTOS DE DESPACHOS"): turno AM entra 5:00 y turno PM entra 13:00, en todos
-- los puntos y tambien el domingo. Lo que cambia de un punto a otro es la hora de SALIDA
-- (12:00, 13:00, 20:00, 20:40 o 21:00), que se guarda para poder medirla mas adelante.
--
-- `puesto` es el nombre EXACTO del puesto en public.puestos, para poder cruzar; `punto` es
-- como lo llama el cuadro de la empresa. Dos nombres del cuadro no se parecen al puesto y los
-- confirmo el usuario (14/10/2026): EXPOSICIONES = puesto 136II, y AVENIDA ORIENTAL POBLADO
-- (el del domingo) = puesto CONTROL ORIENTAL.

create table if not exists public.puesto_horarios (
  id          bigserial primary key,
  punto       text not null,                 -- nombre en el cuadro de la empresa
  puesto      text,                          -- nombre en public.puestos (null = sin equivalencia clara)
  turno       text not null check (turno in ('AM', 'PM')),
  tipo_dia    text not null default 'HABIL' check (tipo_dia in ('HABIL', 'DOMINGO')),
  hora_inicio time not null,
  hora_fin    time,
  actualizado timestamptz not null default now()
);

-- Un solo horario por punto/turno/tipo de dia (permite recargar el cuadro sin duplicar)
create unique index if not exists puesto_horarios_uk
  on public.puesto_horarios (punto, turno, tipo_dia);

alter table public.puesto_horarios enable row level security;

drop policy if exists puesto_horarios_sel on public.puesto_horarios;
create policy puesto_horarios_sel on public.puesto_horarios
  for select using (true);          -- la hora del punto no es un dato reservado

drop policy if exists puesto_horarios_write on public.puesto_horarios;
create policy puesto_horarios_write on public.puesto_horarios
  for all using ((select public.es_admin())) with check ((select public.es_admin()));

grant select on public.puesto_horarios to authenticated;
grant all    on public.puesto_horarios to service_role;

-- ---------------------------------------------------------------------------
-- El cuadro, tal cual lo entrego la empresa. Idempotente: se puede volver a correr.
-- ---------------------------------------------------------------------------
insert into public.puesto_horarios (punto, puesto, turno, tipo_dia, hora_inicio, hora_fin) values
  ('PALACE (136-136A)(130 - 132A) Control 135',        'Nutibara',            'AM', 'HABIL', '05:00', '13:00'),
  ('PALACE (136-136A)(130 - 132A) Control 135',        'Nutibara',            'PM', 'HABIL', '13:00', '21:00'),
  ('JUNIN(133-133D)',                                  '133-133D-132',        'AM', 'HABIL', '05:00', '13:00'),
  ('JUNIN(133-133D)',                                  '133-133D-132',        'PM', 'HABIL', '13:00', '20:00'),
  ('LA Y(134 - 134CH)',                                '134Y-134CH',          'AM', 'HABIL', '05:00', '13:00'),
  ('LA Y(134 - 134CH)',                                '134Y-134CH',          'PM', 'HABIL', '13:00', '20:00'),
  ('SAN LUCAS(135)',                                   '135 San lucas',       'AM', 'HABIL', '05:00', '13:00'),
  ('SAN LUCAS(135)',                                   '135 San lucas',       'PM', 'HABIL', '13:00', '20:00'),
  ('ESTACION INDUSTRIALES(130i-136i-136iA)',           'Industriales',        'AM', 'HABIL', '05:00', '13:00'),
  ('ESTACION INDUSTRIALES(130i-136i-136iA)',           'Industriales',        'PM', 'HABIL', '13:00', '20:00'),
  ('METRO POBLADO (133i-132ii-134iA-134i y 135ii)',    'Estacion poblado',    'AM', 'HABIL', '05:00', '13:00'),
  ('METRO POBLADO (133i-132ii-134iA-134i y 135ii)',    'Estacion poblado',    'PM', 'HABIL', '13:00', '20:00'),
  ('METRO AGUACATALA (132i-133iiA-133ii-135i)',        'Estacion aguacatala', 'AM', 'HABIL', '05:00', '13:00'),
  ('METRO AGUACATALA (132i-133iiA-133ii-135i)',        'Estacion aguacatala', 'PM', 'HABIL', '13:00', '20:00'),
  ('TERMINAL DEL NORTE(287)',                          '287 TERMINAL',        'AM', 'HABIL', '05:00', '13:00'),
  ('TERMINAL DEL NORTE(287)',                          '287 TERMINAL',        'PM', 'HABIL', '13:00', '21:00'),
  ('CIRCULAR SUR (302)',                               'CIRCULAR',            'AM', 'HABIL', '05:00', '13:00'),
  ('CIRCULAR SUR (302)',                               'CIRCULAR',            'PM', 'HABIL', '13:00', '21:00'),
  ('ALMERIA (190 - 191 - 192 - 193)',                  'Laureles',            'AM', 'HABIL', '05:00', '13:00'),
  ('ALMERIA (190 - 191 - 192 - 193)',                  'Laureles',            'PM', 'HABIL', '13:00', '21:00'),
  ('METRO ESTADIO(193i-193ii)',                        '193I',                'AM', 'HABIL', '05:00', '13:00'),
  ('METRO ESTADIO(193i-193ii)',                        '193I',                'PM', 'HABIL', '13:00', '20:00'),
  ('AV. ORIENTAL CONTROL ( 130-134-135-136-136A)',     'CONTROL ORIENTAL',    'AM', 'HABIL', '05:00', '12:00'),
  ('AV. ORIENTAL CONTROL ( 130-134-135-136-136A)',     'CONTROL ORIENTAL',    'PM', 'HABIL', '13:00', '20:00'),
  ('AV. ORIENTAL CONTROL ( 190-192)',                  'CONTROL LAURELES',    'AM', 'HABIL', '05:00', '12:00'),
  ('AV. ORIENTAL CONTROL ( 190-192)',                  'CONTROL LAURELES',    'PM', 'HABIL', '13:00', '20:00'),
  ('EXPOSICIONES',                                     '136II',               'AM', 'HABIL', '05:00', '13:00'),
  ('EXPOSICIONES',                                     '136II',               'PM', 'HABIL', '13:00', '20:00'),
  -- Domingo
  ('CIRCULAR SUR 302',                                 'CIRCULAR',            'AM', 'DOMINGO', '05:00', '13:00'),
  ('CIRCULAR SUR 302',                                 'CIRCULAR',            'PM', 'DOMINGO', '13:00', '20:40'),
  ('TERMINAL DEL NORTE 287-313',                       '287 TERMINAL',        'AM', 'DOMINGO', '05:00', '13:00'),
  ('TERMINAL DEL NORTE 287-313',                       '287 TERMINAL',        'PM', 'DOMINGO', '13:00', '20:00'),
  ('ALMERIA LAURELES 190, 191, 192 Y 193.',            'Laureles',            'AM', 'DOMINGO', '05:00', '12:00'),
  ('ALMERIA LAURELES 190, 191, 192 Y 193.',            'Laureles',            'PM', 'DOMINGO', '13:00', '20:00'),
  ('AVENIDA ORIENTAL POBLADO 130,132, 134, 135, 136.', 'CONTROL ORIENTAL',    'AM', 'DOMINGO', '05:00', '12:00'),
  ('AVENIDA ORIENTAL POBLADO 130,132, 134, 135, 136.', 'CONTROL ORIENTAL',    'PM', 'DOMINGO', '13:00', '20:00')
on conflict (punto, turno, tipo_dia) do update
  set puesto      = excluded.puesto,
      hora_inicio = excluded.hora_inicio,
      hora_fin    = excluded.hora_fin,
      actualizado = now();

-- Comprobaciones
select 'filas cargadas' as dato, count(*)::text as valor from public.puesto_horarios
union all
select 'hora de ENTRADA por turno',
       string_agg(distinct turno || ' ' || tipo_dia || ' -> ' || to_char(hora_inicio, 'HH24:MI'), ' | ')
  from public.puesto_horarios
union all
select 'puntos sin puesto equivalente (no se usan para medir)',
       coalesce(string_agg(distinct punto, ' | '), 'ninguno')
  from public.puesto_horarios where puesto is null
union all
select 'puestos de la app SIN horario en el cuadro',
       coalesce(string_agg(p.nombre, ' | ' order by p.nombre), 'ninguno')
  from public.puestos p
 where coalesce(p.activo, true)
   and not exists (select 1 from public.puesto_horarios ph where ph.puesto = p.nombre);
