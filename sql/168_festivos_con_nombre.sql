-- ===================================================================================
-- 168: FESTIVOS CON NOMBRE + VIRGEN DE CHIQUINQUIRÁ (Ley 2578 de 2026), Y LAS FECHAS
--      DE VACACIONES CON EL DETALLE DE LOS DÍAS QUE NO CUENTAN
-- ===================================================================================
-- DE DÓNDE SALE ESTO. Al pedir que el link de vacaciones le muestre al empleado la fecha de
-- inicio, la de culminación y el día que entra, con los domingos y festivos identificados, se
-- comparó es_festivo() contra la API pública date.nager.at (2026 a 2030): coinciden los 89
-- festivos que ya calculábamos, pero a la base le faltaba uno.
--
-- LA LEY 2578 DEL 1 DE JUNIO DE 2026 declaró festivo nacional el Día de Nuestra Señora del
-- Rosario de Chiquinquirá (9 de julio), que se traslada al lunes siguiente por la Ley 51 de 1983
-- (Ley Emiliani): en 2026 se descansó el lunes 13 de julio. Rige desde su promulgación, por eso
-- solo cuenta desde 2026: los análisis de años anteriores no cambian. Hay una demanda en la
-- Corte Constitucional; si la tumban, se quita la línea marcada abajo.
--
-- POR QUÉ NO SE CONSULTA LA API EN VIVO. Los festivos de Colombia salen de reglas fijas (fecha
-- fija, Ley Emiliani y la Pascua), así que la base los calcula sola y sin depender de un
-- servicio de afuera: si la API se cae, el link no se queda sin fechas. La API sirvió para
-- verificar, y se puede volver a usar igual cada vez que salga una ley nueva.
--
-- QUÉ CAMBIA PARA TODOS. es_festivo() la usan los despachos (tipo_dia: horario de domingo y
-- festivo), los análisis por franja, seguridad vial, permisos (luto en días hábiles) y
-- vacaciones. Con este cambio el lunes de la Virgen de Chiquinquirá se trata como festivo en
-- todos ellos (el próximo: lunes 12 de julio de 2027).
-- ===================================================================================

-- 1) El nombre de cada festivo: una sola lista, y es_festivo() sale de ella -------------------
create or replace function public.festivo_nombre(d date)
returns text
language plpgsql immutable
as $$
declare y int := extract(year from d)::int; p date := public.pascua(y); v_nombre text;
begin
  select n into v_nombre from (values
    (make_date(y, 1, 1),                              'Año Nuevo'),
    (public.lunes_emiliani(make_date(y, 1, 6)),       'Reyes Magos'),
    (public.lunes_emiliani(make_date(y, 3, 19)),      'San José'),
    (p - 3,                                           'Jueves Santo'),
    (p - 2,                                           'Viernes Santo'),
    (make_date(y, 5, 1),                              'Día del Trabajo'),
    (public.lunes_emiliani(p + 39),                   'Ascensión del Señor'),
    (public.lunes_emiliani(p + 60),                   'Corpus Christi'),
    (public.lunes_emiliani(p + 68),                   'Sagrado Corazón'),
    (public.lunes_emiliani(make_date(y, 6, 29)),      'San Pedro y San Pablo'),
    -- Ley 2578 de 2026: desde 2026. Si la Corte la tumba, se borra esta línea.
    (case when y >= 2026 then public.lunes_emiliani(make_date(y, 7, 9)) end, 'Virgen de Chiquinquirá'),
    (make_date(y, 7, 20),                             'Independencia de Colombia'),
    (make_date(y, 8, 7),                              'Batalla de Boyacá'),
    (public.lunes_emiliani(make_date(y, 8, 15)),      'Asunción de la Virgen'),
    (public.lunes_emiliani(make_date(y, 10, 12)),     'Día de la Raza'),
    (public.lunes_emiliani(make_date(y, 11, 1)),      'Todos los Santos'),
    (public.lunes_emiliani(make_date(y, 11, 11)),     'Independencia de Cartagena'),
    (make_date(y, 12, 8),                             'Inmaculada Concepción'),
    (make_date(y, 12, 25),                            'Navidad')
  ) v(f, n) where f = d limit 1;
  return v_nombre;
end $$;
-- Los festivos son públicos y es_festivo() siempre la pudo llamar cualquiera; si festivo_nombre()
-- se le negara a anon, todo camino anónimo que pase por es_festivo() fallaría.
revoke all on function public.festivo_nombre(date) from public;
grant execute on function public.festivo_nombre(date) to anon, authenticated;

-- La misma firma y los mismos permisos de siempre: quien la usa no se entera del cambio.
create or replace function public.es_festivo(d date)
returns boolean
language sql immutable
as $$ select public.festivo_nombre(d) is not null $$;

-- 2) Las fechas de vacaciones, ahora con el detalle de los días que no cuentan ---------------
--    Igual que en sql/163 (fin y regreso no cambian), más 'festivos_det': cada festivo entre el
--    inicio y el día anterior al regreso, con su nombre, aunque caiga en domingo, para que el
--    link pinte el calendario y diga por qué ese día no cuenta.
create or replace function public.vacaciones_fechas(p_inicio date, p_dias int, p_sabado boolean)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  d date := p_inicio; n int := 0; v_fin date; v_fest jsonb := '[]'::jsonb; v_det jsonb;
  v_sab boolean := coalesce(p_sabado, false);
begin
  if p_inicio is null or coalesce(p_dias, 0) < 1 or p_dias > 60 then
    return jsonb_build_object('ok', false);
  end if;
  loop
    if extract(dow from d) = 0 or (extract(dow from d) = 6 and not v_sab) then
      null;                                            -- no es hábil para esta persona
    elsif public.es_festivo(d) then
      v_fest := v_fest || to_jsonb(d);                 -- festivo: no cuenta, pero se dice
    else
      n := n + 1;
      if n = p_dias then v_fin := d; exit; end if;
    end if;
    d := d + 1;
  end loop;
  -- Regresa el siguiente día hábil.
  d := v_fin + 1;
  while extract(dow from d) = 0 or (extract(dow from d) = 6 and not v_sab) or public.es_festivo(d) loop
    d := d + 1;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('fecha', g::date, 'nombre', public.festivo_nombre(g::date)) order by g), '[]'::jsonb)
    into v_det
    from generate_series(p_inicio, d - 1, interval '1 day') g
   where public.es_festivo(g::date);
  return jsonb_build_object('ok', true, 'fin', v_fin, 'regreso', d, 'festivos', v_fest, 'festivos_det', v_det,
                            'calendario', v_fin - p_inicio + 1);
end $$;
revoke all on function public.vacaciones_fechas(date, int, boolean) from public;
grant execute on function public.vacaciones_fechas(date, int, boolean) to anon, authenticated;
