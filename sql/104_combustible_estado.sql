-- ===================================================================================
-- 104: COMBUSTIBLE — el estado que la app consulta al arrancar (va con sql/103).
-- ===================================================================================
-- La app pregunta esto una sola vez al entrar: si puede ver el módulo, si puede traer,
-- y cómo va la traída. Con eso decide si pinta la entrada del menú y qué avisa.
-- Nunca devuelve datos de tanqueos: solo conteos.

create or replace function public.combustible_estado()
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_ver boolean; v_traer boolean;
  v_total int; v_ultimo date; v_pos int; v_est text; v_dias int; v_sin_movil int;
begin
  v_ver := (select public.es_admin()) or (select public.es_operaciones())
        or (select public.es_auditor()) or (select public.es_afiliado());
  if not v_ver then
    return jsonb_build_object('ok', false);
  end if;
  v_traer := (select public.es_admin());

  select id_punto_venta, estacion into v_pos, v_est from public.combustible_config where id = 1;

  -- El afiliado cuenta solo lo suyo; los demás, todo.
  if (select public.es_afiliado()) and not (select public.es_admin()) then
    select count(*), max(fecha) into v_total, v_ultimo
      from public.combustible_tanqueos
     where movil = any (public.mis_moviles_afiliado());
    v_sin_movil := 0;
  else
    select count(*), max(fecha) into v_total, v_ultimo from public.combustible_tanqueos;
    -- Tanqueos cuya placa ya no está en el parque: se quedaron sin móvil y no cuadran por carro.
    select count(*) into v_sin_movil from public.combustible_tanqueos where movil is null;
  end if;

  if v_ultimo is not null then
    v_dias := (now() at time zone 'America/Bogota')::date - v_ultimo;
  end if;

  return jsonb_build_object(
    'ok', true,
    'puede_traer', v_traer,
    'total', coalesce(v_total, 0),
    'ultimo', v_ultimo,
    'dias_sin_datos', v_dias,          -- si crece, la traída se cayó
    'sin_movil', coalesce(v_sin_movil, 0),
    'punto_venta', v_pos,
    'estacion', v_est,
    'configurado', (v_pos is not null));
end $fn$;

revoke all on function public.combustible_estado() from public, anon;
grant execute on function public.combustible_estado() to authenticated;

comment on function public.combustible_estado() is
  'Estado del módulo de combustible para la app: si puede ver, si puede traer y cómo va la traída. Sin datos de tanqueos.';
