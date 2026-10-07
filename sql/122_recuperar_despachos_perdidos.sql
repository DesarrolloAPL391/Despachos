-- ===================================================================================
-- 122: RECUPERAR LOS DÍAS DE DESPACHOS QUE EL PROCESO NOCTURNO NUNCA ALCANZÓ A GUARDAR
-- ===================================================================================
-- DE DÓNDE SALE ESTO. El 07/10/2026 se descubrió que `sync_despachos_sonar_nocturno` se
-- venía cortando a los 120 segundos todas las noches (ver sql/120). Como la función corre
-- dentro de una sola transacción, cada corte revertía TODO su trabajo: el día quedaba solo
-- con lo que la app hubiera alcanzado a traer mientras tanto.
--
-- Comparando cada día contra el mismo día de la semana de una semana ya verificada
-- (29/09–06/10) aparecieron 27 días por debajo del 85%: del 23/08 al 27/09.
--
-- POR QUÉ UN PROCESO Y NO HACERLO A MANO: cada día tarda entre 1 y 2 minutos. 27 días son
-- más de una hora pegando fechas en el editor, y una sola pestaña no aguanta tanto.
--
-- CÓMO FUNCIONA:
--   · Se siembra una lista de los días que faltan (se calcula una sola vez, ahora).
--   · Un cron toma UNO cada 5 minutos, lo sincroniza y lo marca.
--   · Corre SOLO DE MADRUGADA, cuando el servidor está libre: cada día son 338 llamadas
--     a SONAR y no tiene por qué competir con la operación.
--   · Cuando no queda ninguno, el propio proceso se desprograma. No hay que acordarse
--     de apagarlo.
--   · Si un día falla dos veces (porque SONAR ya no conserva ese histórico), se marca
--     como agotado y no se vuelve a intentar. Así no se queda dando vueltas sobre el
--     mismo día para siempre.
--
-- En una sola madrugada (01:00–06:55 Colombia, 72 turnos de 5 minutos) alcanza de sobra
-- para los 27 días.
-- ===================================================================================

-- ---------- 1) La lista de lo que hay que recuperar ----------
create table if not exists public.recuperacion_despachos (
  fecha          date primary key,
  viajes_antes   int,
  viajes_despues int,
  intentos       int  not null default 0,
  hecho          boolean not null default false,
  ultimo_intento timestamptz,
  nota           text
);
comment on table public.recuperacion_despachos is
  'Dias de despachos_sonar que quedaron incompletos por el corte de 120 s (sql/120). Lo vacia el cron de sql/122.';

-- Se siembra con los días que hoy están por debajo del 85% de su mismo día de la semana,
-- tomando como referencia la semana del 29/09 al 06/10, que ya quedó verificada.
with sano as (
  select extract(isodow from fecha)::int as dow, fecha, count(*) as viajes
    from public.despachos_sonar
   where fecha between date '2026-09-29' and date '2026-10-06'
   group by 1, 2
),
ref as (select dow, max(viajes) as referencia from sano group by dow),
dias as (
  select d::date                     as fecha,
         extract(isodow from d)::int as dow,
         count(s.itl_id)             as viajes
    from generate_series(current_date - 45, current_date - 1, interval '1 day') g(d)
    left join public.despachos_sonar s on s.fecha = d::date
   group by 1, 2
)
insert into public.recuperacion_despachos (fecha, viajes_antes)
select d.fecha, d.viajes
  from dias d join ref r on r.dow = d.dow
 where d.viajes < r.referencia * 0.85
on conflict (fecha) do nothing;

-- ---------- 2) El que hace el trabajo ----------
create or replace function public.recuperar_despachos_pendientes()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_fecha date; v_antes int; v_r jsonb; v_despues int; v_quedan int;
begin
  -- Corre como postgres desde el cron: sin tope. Este es justamente el descuido que
  -- causó todo el problema (sql/120).
  perform set_config('statement_timeout', '0', true);

  -- El más reciente primero: son los días que más se consultan.
  select fecha, viajes_antes into v_fecha, v_antes
    from public.recuperacion_despachos
   where not hecho and intentos < 2
   order by fecha desc
   limit 1;

  if v_fecha is null then
    -- No queda nada: el proceso se apaga solo. Si no pudiera desprogramarse, no es grave
    -- (seguiría despertando para no hacer nada), pero no debe tumbar la corrida.
    begin
      perform cron.unschedule('recuperar-despachos')
        where exists (select 1 from cron.job where jobname = 'recuperar-despachos');
    exception when others then
      return jsonb_build_object('ok', true, 'terminado', true,
                                'aviso', 'no se pudo desprogramar: ' || left(sqlerrm, 120));
    end;
    return jsonb_build_object('ok', true, 'terminado', true);
  end if;

  update public.recuperacion_despachos
     set intentos = intentos + 1, ultimo_intento = now()
   where fecha = v_fecha;

  begin
    v_r := public.sync_despachos_sonar_core(v_fecha, 500);
  exception when others then
    update public.recuperacion_despachos
       set nota = left(sqlerrm, 200) where fecha = v_fecha;
    return jsonb_build_object('ok', false, 'fecha', v_fecha, 'error', left(sqlerrm, 200));
  end;

  select count(*) into v_despues from public.despachos_sonar where fecha = v_fecha;

  update public.recuperacion_despachos
     set viajes_despues = v_despues,
         -- se da por hecho si trajo algo; si ya se intentó dos veces y no mejoró, se
         -- cierra igual con la nota, para no reintentar un día que SONAR ya no tiene.
         hecho = (v_despues > coalesce(v_antes, 0)) or intentos >= 2,
         nota  = case when v_despues > coalesce(v_antes, 0)
                      then format('recuperados %s viajes', v_despues - coalesce(v_antes, 0))
                      else 'SONAR no devolvio mas viajes para este dia' end
   where fecha = v_fecha;

  select count(*) into v_quedan
    from public.recuperacion_despachos where not hecho and intentos < 2;

  return jsonb_build_object('ok', true, 'fecha', v_fecha,
                            'antes', v_antes, 'despues', v_despues,
                            'recuperados', v_despues - coalesce(v_antes, 0),
                            'quedan', v_quedan);
end $fn$;
revoke all on function public.recuperar_despachos_pendientes() from public, anon, authenticated;

-- ---------- 3) El cron ----------
-- Cada 5 minutos entre las 06:00 y las 11:55 UTC = 01:00 a 06:55 de Colombia. Son 72
-- turnos por noche, de sobra para los 27 días. (pg_cron va en UTC: ver sql/119 y sql/121.)
select cron.unschedule('recuperar-despachos')
 where exists (select 1 from cron.job where jobname = 'recuperar-despachos');

select cron.schedule('recuperar-despachos', '*/5 6-11 * * *',
                     'select public.recuperar_despachos_pendientes();');

-- ===================================================================================
-- PARA SEGUIRLO MAÑANA:
--   select count(*) filter (where hecho)            as recuperados,
--          count(*) filter (where not hecho)        as faltan,
--          sum(viajes_despues - viajes_antes)       as viajes_rescatados
--     from public.recuperacion_despachos;
--
--   select fecha, viajes_antes, viajes_despues, intentos, hecho, nota
--     from public.recuperacion_despachos order by fecha desc;
--
-- SI SE QUIERE ARRANCAR YA MISMO SIN ESPERAR A LA MADRUGADA (cada llamada = un día,
-- tarda 1-2 minutos):
--   select public.recuperar_despachos_pendientes();
--
-- PARA PARARLO:
--   select cron.unschedule('recuperar-despachos');
--
-- CUANDO TERMINE, la tabla `recuperacion_despachos` queda como registro de qué se
-- recuperó y qué no. Se puede borrar sin consecuencias.
-- ===================================================================================
