-- ===================================================================================
-- 119: EL CONTROL EN VÍA SE PASABA DEL TIEMPO — caché y cron, como ya se hizo en sql/18.
-- ===================================================================================
-- SÍNTOMA (28/09/2026, 7:51 a.m.): el Control Av. Oriental mostraba
--   "No se pudo consultar SONAR · canceling statement due to statement timeout".
--
-- LA CAUSA NO ES SONAR, ES NUESTRA CONSULTA. `_control_oriental_core` (sql/98) hace UNA
-- llamada SOAP POR CADA ITINERARIO que tenga la geocerca del punto —hoy son once— y las
-- hace en fila, una detrás de otra, dentro de la misma transacción. El rol `authenticated`
-- tiene statement_timeout = 8 segundos. Para caber, SONAR tendría que contestar cada
-- itinerario en menos de 730 milisegundos, las once veces seguidas. Y el timeout de cada
-- llamada HTTP está en 12 segundos: UNA sola respuesta lenta ya se come el presupuesto
-- entero de la transacción.
--
-- Por eso el tablero funcionaba cuando SONAR estaba ágil y fallaba en la hora pico de la
-- mañana, que es justo cuando el controlador lo necesita. No era intermitencia: era una
-- consulta que siempre estuvo por encima del límite y que solo pasaba de milagro.
--
-- ESTO YA SE HABÍA RESUELTO EN ESTE MISMO SISTEMA. sql/18 (rutas en vivo) dice, textual:
-- "esa llamada SOAP tarda ~17 s... el cliente NO puede llamarla en vivo. Patrón: un pg_cron
-- refresca un CACHÉ cada minuto (corre como postgres, sin tope) y el cliente lee el caché al
-- instante". El control en vía se construyó sin aplicar ese patrón. Aquí se corrige.
--
-- CÓMO QUEDA:
--   · Un cron refresca el tablero de los dos puntos cada 2 minutos, corriendo como postgres,
--     sin límite de tiempo y sin importar cuántas pantallas haya abiertas.
--   · La pantalla lee una fila de una tabla: responde al instante y ya no puede dar timeout.
--   · Cada día queda guardado al cerrar, así que consultar un día pasado tampoco llama a SONAR.
--
-- DE PASO SE QUITA UNA CARGA GRANDE SOBRE SONAR: hoy cada pantalla abierta dispara once
-- llamadas cada minuto por su cuenta. Con tres controladores mirando eran 33 llamadas por
-- minuto pidiendo lo mismo. Ahora son once cada dos minutos, para todos.
--
-- Se aplica a los DOS puntos: la Oriental es la que falló, pero Laureles (sql/24) tiene
-- exactamente el mismo defecto y es el tablero más usado.
-- ===================================================================================

-- ---------- 1) El caché ----------
create table if not exists public.control_vivo (
  punto          text not null,                 -- 'ORIENTAL' | 'LAURELES'
  fecha          date not null,
  datos          jsonb not null,                -- lo que devuelve el core, tal cual
  actualizado_en timestamptz not null default now(),
  ms             int,                           -- lo que tardó el refresco
  error          text,                          -- del último intento fallido, si lo hubo
  primary key (punto, fecha)
);
comment on table public.control_vivo is
  'Cache del tablero de control en via. Lo llena el cron; la pantalla solo lee (sql/119).';

create index if not exists control_vivo_fecha_idx on public.control_vivo (fecha desc);

alter table public.control_vivo enable row level security;
-- Sin políticas de lectura directa: se llega por las funciones, como en Laureles y Oriental.

-- ---------- 2) El refresco (lo corre el cron, sin tope de tiempo) ----------
create or replace function public.control_vivo_refrescar(
  p_punto text default null, p_fecha date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_f date := coalesce(p_fecha, v_hoy);
  v_puntos text[] := case when coalesce(btrim(p_punto), '') = ''
                          then array['ORIENTAL', 'LAURELES'] else array[upper(btrim(p_punto))] end;
  v_p text; v_t0 timestamptz; v_r jsonb; v_ms int; v_n int;
  v_res jsonb := '{}'::jsonb;
begin
  -- El cron corre como postgres: aquí no hay navegador esperando, así que no hay tope.
  perform set_config('statement_timeout', '0', true);

  foreach v_p in array v_puntos loop
    v_t0 := clock_timestamp();
    begin
      v_r := case v_p
               when 'ORIENTAL' then public._control_oriental_core(v_f)
               when 'LAURELES' then public._control_laureles_core(v_f)
             end;
    exception when others then
      v_r := jsonb_build_object('ok', false, 'error', left(sqlerrm, 300));
    end;
    v_ms := (extract(milliseconds from clock_timestamp() - v_t0))::int;

    if coalesce((v_r->>'ok')::boolean, false) then
      -- Solo se pisa el caché con un resultado bueno: un fallo pasajero de SONAR no puede
      -- dejar al controlador con la pantalla en blanco teniendo el dato de hace dos minutos.
      insert into public.control_vivo (punto, fecha, datos, actualizado_en, ms, error)
      values (v_p, v_f, v_r, now(), v_ms, null)
      on conflict (punto, fecha) do update set
        datos = excluded.datos, actualizado_en = now(), ms = excluded.ms, error = null;
      v_n := jsonb_array_length(coalesce(v_r->'viajes', '[]'::jsonb));
    else
      update public.control_vivo set error = left(v_r->>'error', 300), ms = v_ms
       where punto = v_p and fecha = v_f;
      v_n := -1;
    end if;
    v_res := v_res || jsonb_build_object(lower(v_p), jsonb_build_object('viajes', v_n, 'ms', v_ms));
  end loop;

  return jsonb_build_object('ok', true, 'fecha', v_f) || v_res;
end $fn$;
revoke all on function public.control_vivo_refrescar(text, date) from public, anon, authenticated;

-- ---------- 3) Lo que lee la pantalla ----------
-- Devuelve el caché al instante y le agrega cuándo se actualizó, para que el controlador
-- sepa qué tan fresco es lo que está viendo. Nunca llama a SONAR.
create or replace function public._control_vivo_leer(p_punto text, p_fecha date)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_f date := coalesce(p_fecha, v_hoy);
  c record;
begin
  select * into c from public.control_vivo where punto = p_punto and fecha = v_f;
  if c.punto is null then
    return jsonb_build_object('ok', false, 'fecha', v_f, 'sin_cache', true,
      'error', case when v_f = v_hoy
                    then 'Todavía no se ha refrescado el tablero de hoy. Se actualiza solo cada 2 minutos.'
                    else 'No hay datos guardados de ese día.' end);
  end if;
  return c.datos
      || jsonb_build_object(
           'actualizado_en', c.actualizado_en,
           'edad_seg', greatest(0, (extract(epoch from (now() - c.actualizado_en)))::int),
           'en_vivo', (v_f = v_hoy),
           'aviso', c.error);
end $fn$;

create or replace function public.control_oriental(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  return public._control_vivo_leer('ORIENTAL', p_fecha);
end $fn$;
revoke all on function public.control_oriental(date) from public, anon;
grant execute on function public.control_oriental(date) to authenticated;

create or replace function public.control_laureles(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'No autenticado.'); end if;
  return public._control_vivo_leer('LAURELES', p_fecha);
end $fn$;
revoke all on function public.control_laureles(date) from public, anon;
grant execute on function public.control_laureles(date) to authenticated;

-- ---------- 4) Traer un día que no está guardado (administración) ----------
-- Para los días anteriores a esta corrección, que no alcanzaron a quedar en el caché.
-- Tarda, y por eso no está en la pantalla del controlador: es una herramienta de consulta.
create or replace function public.control_vivo_traer(p_punto text, p_fecha date)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
begin
  if not ( (select public.es_admin()) or (select public.es_auditor())
        or (select public.es_operaciones()) or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y auditoría.');
  end if;
  -- 50 s: por encima de lo que tarda el barrido, por debajo del corte de la pasarela.
  perform set_config('statement_timeout', '50000', true);
  return public.control_vivo_refrescar(p_punto, p_fecha);
end $fn$;
revoke all on function public.control_vivo_traer(text, date) from public, anon;
grant execute on function public.control_vivo_traer(text, date) to authenticated;

-- ---------- 5) El cron ----------
-- Cada 2 minutos entre las 4:00 a.m. y las 11:59 p.m. DE COLOMBIA. Fuera de esa franja no hay
-- operación que controlar y no tiene sentido seguirle pidiendo datos a SONAR.
--
-- OJO CON LA HORA: pg_cron programa en la zona de la base, que en Supabase es UTC. Colombia
-- es UTC-5, así que la franja se escribe corrida: 09-23 UTC son las 4:00 a.m.–6:59 p.m. de
-- Colombia, y 00-04 UTC son las 7:00–11:59 p.m. Escribirla como '4-23' —que fue el error de
-- la primera versión de este archivo, corregido el 29/09/2026— deja el tablero sin refrescar
-- entre las 7 y las 11 de la noche, que es operación, y lo pone a trabajar de madrugada,
-- cuando no hay un solo bus rodando. Se comprobó con cron.job_run_details: había corridas a
-- las 05, 06, 07 y 08 UTC (medianoche a 4 a.m. de Colombia).
-- Los demás crons del sistema ya estaban escritos en UTC a propósito (ver sql/81).
select cron.unschedule('refrescar-control-vivo')
 where exists (select 1 from cron.job where jobname = 'refrescar-control-vivo');

select cron.schedule('refrescar-control-vivo', '*/2 0-4,9-23 * * *',
  $$ select public.control_vivo_refrescar(); $$);

-- Primer llenado, para no dejar la pantalla vacía hasta el próximo minuto par.
select public.control_vivo_refrescar();

-- ===================================================================================
-- PARA VERIFICAR:
--   select punto, fecha, actualizado_en, ms, error,
--          jsonb_array_length(datos->'viajes') as viajes
--     from public.control_vivo order by fecha desc, punto;
--   select public.control_oriental(current_date) -> 'edad_seg';   -- segundos de antigüedad
-- Para un día viejo que no quedó guardado:
--   select public.control_vivo_traer('ORIENTAL', date '2026-09-27');
-- ===================================================================================
