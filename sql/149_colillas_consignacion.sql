-- ============================================================================================
-- 149 · COLILLAS DE CONSIGNACIÓN — el conductor sube la foto y la app le dice si quedó al día
--
-- "hagamos un ejemplo desde el conductor montando una foto de una colilla de consignacion, esto
--  usara ocr para leer y decir si consigno el dinero" (31/10/2026).
--
-- CÓMO FUNCIONA
--   1. El conductor entra por un link público (consignacion.html) con su CÉDULA y el NÚMERO DEL
--      BUS de una de sus liquidaciones del último mes. A diferencia del preoperacional, aquí se
--      muestra plata (lo que debe), así que la cédula sola no basta: con el bus, y con un tope de
--      5 intentos fallidos por hora, una cédula ajena no abre nada.
--   2. El celular lee la colilla con OCR (Tesseract, en el mismo teléfono) y saca valor, fecha,
--      referencia y comprobante. El conductor puede corregir el valor; si lo hace, queda marcado.
--   3. UNA COLILLA POR LIQUIDACIÓN: el conductor la sube desde la liquidación que paga y el
--      servidor — nunca el celular — la compara contra ella: COMPLETO / PARCIAL (cuánto falta) /
--      DE_MAS. No acepta una colilla de antes del día liquidado ni la misma colilla dos veces.
--   4. La prueba de verdad es el extracto del banco: la colilla queda CONFIRMADA cuando aparece
--      una consignación de esa cédula, por ese valor, ese día o el siguiente. Una foto se puede
--      editar; el extracto no. Si el extracto de esos días ya está y no aparece: NO_APARECE.
--
-- La foto va en base64 dentro de la fila, reducida por el celular, igual que la selfie del
-- preoperacional (sql/127). Si se vuelve diario para todos, conviene pasarla a Storage.
--
-- Se aplica sobre sql/138 (liquidaciones), 142 (recaudos_banco) y 148.
-- ============================================================================================

create table if not exists public.liq_colillas (
  id            bigserial primary key,
  creado_en     timestamptz not null default now(),
  cedula        text not null,
  nombre        text,
  movil         text,                       -- el bus con que se identificó
  fecha         date not null,              -- la fecha que dice la colilla
  valor         bigint not null check (valor > 0),
  valor_a_mano  boolean not null default false,   -- el conductor cambió lo que leyó el OCR
  referencia    text,
  ref_cedula    boolean,                    -- la colilla trae la cédula del conductor
  comprobante   text,
  banco         text,
  ocr_texto     text,
  ocr_confianza numeric,
  foto          text,
  cubre         jsonb not null default '[]'::jsonb,  -- [{key, fecha, movil, ruta, dinero, aplicado}]
  veredicto     text not null,
  faltante      bigint not null default 0,
  sobrante      bigint not null default 0
);
create index if not exists liq_colillas_ced_idx on public.liq_colillas (cedula, fecha);

alter table public.liq_colillas enable row level security;
drop policy if exists liq_colillas_admin on public.liq_colillas;
create policy liq_colillas_admin on public.liq_colillas
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
revoke all on public.liq_colillas from anon;
grant select, delete on public.liq_colillas to authenticated;

comment on table public.liq_colillas is
  'Colillas de consignacion que suben los conductores, leidas con OCR y cruzadas con la liquidacion (sql/149).';

-- Intentos fallidos de identificarse (para frenar a quien prueba buses con una cédula ajena).
create table if not exists public.liq_colilla_intentos (
  cedula text not null,
  cuando timestamptz not null default now()
);
create index if not exists liq_colilla_int_idx on public.liq_colilla_intentos (cedula, cuando);
alter table public.liq_colilla_intentos enable row level security;
revoke all on public.liq_colilla_intentos from anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 1) ¿Quién es? Cédula + un bus de sus liquidaciones del último mes.
-- ---------------------------------------------------------------------------------------------
create or replace function public._colilla_quien(p_cedula text, p_movil text,
  out ced text, out nombre text, out error text)
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_mov text := btrim(coalesce(p_movil, ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  ced := regexp_replace(coalesce(p_cedula, ''), '\D', '', 'g');
  if length(ced) < 5 then error := 'Escribe tu número de cédula.'; return; end if;
  if v_mov = '' then error := 'Escribe el número del bus.'; return; end if;

  if (select count(*) from public.liq_colilla_intentos
       where cedula = ced and cuando > now() - interval '1 hour') >= 5 then
    error := 'Demasiados intentos. Espera una hora o pide ayuda en la oficina.';
    return;
  end if;

  select max(l.conductor) into nombre
    from public.liquidaciones l
   where l.fecha >= v_hoy - 45
     and l.movil = v_mov
     and regexp_replace(coalesce(l.conductor_cedula, ''), '\D', '', 'g') = ced;

  if nombre is null then
    insert into public.liq_colilla_intentos (cedula) values (ced);
    -- El mismo mensaje sirva o no la cédula: no se le confirma a nadie que una cédula existe.
    error := 'La cédula y el bus no coinciden con tus liquidaciones del último mes.';
  end if;
end $function$;
revoke all on function public._colilla_quien(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 2) La cuenta del conductor: qué liquidación está paga, con qué, y cuánto falta.
--    Orden de los pagos:
--      a) colillas ya enviadas: pagan exactamente las liquidaciones que el conductor eligió;
--      b) la colilla que se está revisando (p_extra), igual;
--      c) el extracto del banco: cada consignación paga lo más viejo pendiente de hasta 7 días
--         antes (la misma regla de la planilla, sql/148). La línea del banco que ES una colilla
--         no se vuelve a contar.
-- ---------------------------------------------------------------------------------------------
create or replace function public._liq_cuenta(p_ced text, p_desde date, p_extra jsonb default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_bini date := (select min(fecha) from public.recaudos_banco);
  k text[]; f date[]; mv text[]; rt text[]; din bigint[];
  pend bigint[]; pcol bigint[]; pban bigint[]; pext bigint[];
  n int; i int; t bigint; resto bigint; p record; c record;
  v_xf date := nullif(p_extra ->> 'fecha', '')::date;
  v_xv bigint := nullif(p_extra ->> 'valor', '')::bigint;
  v_xkeys text[] := case when p_extra ? 'keys' and jsonb_typeof(p_extra -> 'keys') = 'array'
                         then array(select jsonb_array_elements_text(p_extra -> 'keys')) end;
  v_xbanco bigint; v_xbfecha date;
  v_xsobra bigint := 0;
begin
  select coalesce(array_agg(l.key order by l.fecha, l.movil, l.ruta), '{}'),
         coalesce(array_agg(l.fecha order by l.fecha, l.movil, l.ruta), '{}'),
         coalesce(array_agg(l.movil order by l.fecha, l.movil, l.ruta), '{}'),
         coalesce(array_agg(l.ruta order by l.fecha, l.movil, l.ruta), '{}'),
         -- Una liquidación en 0 o negativa no se cobra.
         coalesce(array_agg(greatest(coalesce(l.dinero, 0), 0) order by l.fecha, l.movil, l.ruta), '{}')
    into k, f, mv, rt, din
    from public.liquidaciones l
   where l.fecha >= p_desde
     and regexp_replace(coalesce(l.conductor_cedula, ''), '\D', '', 'g') = p_ced;
  n := coalesce(array_length(k, 1), 0);
  pend := din;
  pcol := array_fill(0::bigint, array[n]); pban := pcol; pext := pcol;

  -- a) Colillas ya enviadas
  for c in
    select x.key, sum(x.aplicado)::bigint as ap
      from public.liq_colillas lc,
           jsonb_to_recordset(lc.cubre) as x(key text, aplicado bigint)
     where lc.cedula = p_ced
     group by x.key
  loop
    i := array_position(k, c.key);
    if i is not null then
      t := least(pend[i], c.ap); pend[i] := pend[i] - t; pcol[i] := pcol[i] + t;
    end if;
  end loop;

  -- b) La colilla que se está revisando
  if v_xv is not null then
    select r.id, r.fecha into v_xbanco, v_xbfecha
      from public.recaudos_banco r
     where r.cedula = p_ced and r.valor = v_xv and r.fecha between v_xf and v_xf + 1
       and not exists (select 1 from public.liq_colillas lc
                        where lc.cedula = p_ced and lc.valor = r.valor
                          and r.fecha between lc.fecha and lc.fecha + 1)
     order by r.fecha, r.id limit 1;
    resto := v_xv;
    for i in 1 .. n loop
      exit when resto <= 0;
      if k[i] = any (coalesce(v_xkeys, '{}')) and pend[i] > 0 then
        t := least(pend[i], resto); pend[i] := pend[i] - t; pext[i] := pext[i] + t; resto := resto - t;
      end if;
    end loop;
    v_xsobra := resto;
  end if;

  -- c) El extracto del banco
  for p in
    select r.id, r.fecha, r.valor
      from public.recaudos_banco r
     where r.cedula = p_ced and r.fecha >= p_desde
       and r.id is distinct from v_xbanco
       and not exists (select 1 from public.liq_colillas lc
                        where lc.cedula = p_ced and lc.valor = r.valor
                          and r.fecha between lc.fecha and lc.fecha + 1)
     order by r.fecha, r.id
  loop
    resto := p.valor;
    for i in 1 .. n loop
      exit when resto <= 0;
      -- Antes del primer extracto cargado no se sabe qué se pagó: esas no entran al reparto.
      if f[i] <= p.fecha and f[i] >= p.fecha - 7 and f[i] >= v_bini - 1 and pend[i] > 0 then
        t := least(pend[i], resto); pend[i] := pend[i] - t; pban[i] := pban[i] + t; resto := resto - t;
      end if;
    end loop;
  end loop;

  return jsonb_build_object(
    'deudas', (select coalesce(jsonb_agg(jsonb_build_object(
                  'key', k[j], 'fecha', f[j], 'movil', mv[j], 'ruta', rt[j], 'dinero', din[j],
                  'colilla', pcol[j], 'banco', pban[j], 'esta', pext[j], 'pendiente', pend[j],
                  -- ¿ya está el extracto del día en que normalmente se paga?
                  'extracto_sig', exists (select 1 from public.recaudos_banco r where r.fecha = f[j] + 1),
                  -- ¿la colilla que la paga ya la confirmó el banco?
                  'colilla_banco', exists (select 1 from public.liq_colillas lc
                                            where lc.cedula = p_ced
                                              and lc.cubre @> jsonb_build_array(jsonb_build_object('key', k[j]))
                                              and exists (select 1 from public.recaudos_banco r
                                                           where r.cedula = lc.cedula and r.valor = lc.valor
                                                             and r.fecha between lc.fecha and lc.fecha + 1)))
                order by f[j], mv[j], rt[j]), '[]'::jsonb)
                 from generate_series(1, n) j),
    'sobrante', v_xsobra,
    'banco_id', v_xbanco,
    'banco_fecha', v_xbfecha);
end $function$;
revoke all on function public._liq_cuenta(text, date, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 3) Lo que el celular le muestra al conductor: análisis de una colilla (no guarda nada)
--    UNA COLILLA POR LIQUIDACIÓN ("es colilla por liquidacion", 31/10/2026): el conductor sube
--    la colilla desde la liquidación que está pagando y se compara SOLO contra ella.
-- ---------------------------------------------------------------------------------------------
drop function if exists public._colilla_veredicto(text, date, bigint, jsonb, text);
create or replace function public._colilla_veredicto(p_ced text, p_key text, p_fecha date,
  p_valor bigint, p_comprobante text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_desde date := (now() at time zone 'America/Bogota')::date - 45;
  v_base jsonb; v_cta jsonb; d jsonb; x jsonb; v_dup jsonb;
  v_falta bigint; v_sobra bigint; v_ver text;
begin
  -- La liquidación como está ANTES de esta colilla (la línea del banco que sea esta misma
  -- colilla no cuenta como pago todavía: así se puede subir la colilla de algo ya consignado).
  v_base := public._liq_cuenta(p_ced, v_desde,
              jsonb_build_object('fecha', p_fecha, 'valor', p_valor, 'keys', '[]'::jsonb));
  select e into d from jsonb_array_elements(v_base -> 'deudas') e where e ->> 'key' = p_key;

  if d is null then
    return jsonb_build_object('ok', false, 'error', 'Esa liquidación no aparece entre las tuyas.');
  end if;
  if (d ->> 'dinero')::bigint <= 0 then
    return jsonb_build_object('ok', false, 'error', 'Esa liquidación no tiene valor a pagar.');
  end if;
  -- Se consigna después de trabajar, no antes: casi siempre es un error de fecha del OCR.
  if p_fecha < (d ->> 'fecha')::date then
    return jsonb_build_object('ok', false, 'error',
      'La colilla dice ' || to_char(p_fecha, 'DD/MM/YYYY') || ' y la liquidación es del '
      || to_char((d ->> 'fecha')::date, 'DD/MM/YYYY') || ': no puede ser de antes. Revisa la fecha.');
  end if;
  if (d ->> 'pendiente')::bigint <= 0 then
    return jsonb_build_object('ok', false, 'error',
      case when (d ->> 'colilla')::bigint > 0 then 'Esa liquidación ya tiene su colilla.'
           else 'Esa liquidación ya aparece pagada en el banco.' end);
  end if;

  v_cta := public._liq_cuenta(p_ced, v_desde,
             jsonb_build_object('fecha', p_fecha, 'valor', p_valor, 'keys', jsonb_build_array(p_key)));
  select e into x from jsonb_array_elements(v_cta -> 'deudas') e where e ->> 'key' = p_key;
  v_falta := (x ->> 'pendiente')::bigint;
  v_sobra := (v_cta ->> 'sobrante')::bigint;
  v_ver := case when v_falta > 0 then 'PARCIAL' when v_sobra > 0 then 'DE_MAS' else 'COMPLETO' end;

  -- La misma colilla no sirve para dos liquidaciones (mismo día y valor; si las dos traen
  -- comprobante, también el comprobante).
  select jsonb_build_object('id', lc.id, 'enviada', to_char(lc.creado_en at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI'))
    into v_dup
    from public.liq_colillas lc
   where lc.cedula = p_ced and lc.fecha = p_fecha and lc.valor = p_valor
     and (lc.comprobante is null or nullif(btrim(p_comprobante), '') is null
          or lc.comprobante = btrim(p_comprobante))
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'veredicto', v_ver, 'valor', p_valor, 'fecha', p_fecha, 'key', p_key,
    'liquidacion', jsonb_build_object('fecha', x -> 'fecha', 'movil', x -> 'movil', 'ruta', x -> 'ruta',
                                      'dinero', x -> 'dinero'),
    'debia', (d ->> 'pendiente')::bigint,          -- lo que faltaba antes de esta colilla
    'aplicado', (x ->> 'esta')::bigint, 'faltante', v_falta, 'sobrante', v_sobra,
    'cubre', jsonb_build_array(x),
    'banco_confirma', (v_cta ->> 'banco_id') is not null,
    'banco_fecha', v_cta -> 'banco_fecha',
    'duplicada', v_dup);
end $function$;
revoke all on function public._colilla_veredicto(text, text, date, bigint, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 4) Puertas públicas (link del conductor)
-- ---------------------------------------------------------------------------------------------
create or replace function public.colilla_identificar(p_cedula text, p_movil text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare q record; v_cta jsonb;
begin
  select * into q from public._colilla_quien(p_cedula, p_movil);
  if q.error is not null then return jsonb_build_object('ok', false, 'error', q.error); end if;
  -- Tres semanas: alcanza para lo de los fines de semana y lo que se consigna con atraso.
  v_cta := public._liq_cuenta(q.ced, (now() at time zone 'America/Bogota')::date - 20);
  return jsonb_build_object('ok', true, 'nombre', q.nombre, 'deudas', v_cta -> 'deudas');
end $function$;

drop function if exists public.colilla_analizar(text, text, date, numeric, jsonb, text);
create or replace function public.colilla_analizar(p_cedula text, p_movil text, p_key text,
  p_fecha date, p_valor numeric, p_comprobante text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare q record; v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  select * into q from public._colilla_quien(p_cedula, p_movil);
  if q.error is not null then return jsonb_build_object('ok', false, 'error', q.error); end if;
  if coalesce(btrim(p_key), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Elige la liquidación que estás pagando.');
  end if;
  if p_fecha is null or p_fecha > v_hoy + 1 or p_fecha < v_hoy - 45 then
    return jsonb_build_object('ok', false, 'error', 'Revisa la fecha de la colilla.');
  end if;
  if p_valor is null or p_valor <= 0 or p_valor > 10000000 then
    return jsonb_build_object('ok', false, 'error', 'Revisa el valor de la colilla.');
  end if;
  return public._colilla_veredicto(q.ced, btrim(p_key), p_fecha, round(p_valor)::bigint, p_comprobante);
end $function$;

create or replace function public.colilla_guardar(p_cedula text, p_movil text, p_datos jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  q record; v jsonb; v_id bigint;
  v_fecha date; v_valor bigint; v_foto text; v_ref text; v_texto text; v_refced boolean;
  v_key text := btrim(coalesce(p_datos ->> 'key', ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  select * into q from public._colilla_quien(p_cedula, p_movil);
  if q.error is not null then return jsonb_build_object('ok', false, 'error', q.error); end if;
  if v_key = '' then
    return jsonb_build_object('ok', false, 'error', 'Elige la liquidación que estás pagando.');
  end if;

  begin
    v_fecha := (p_datos ->> 'fecha')::date;
    v_valor := round((p_datos ->> 'valor')::numeric)::bigint;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'Revisa la fecha y el valor.');
  end;
  if v_fecha is null or v_fecha > v_hoy + 1 or v_fecha < v_hoy - 45 then
    return jsonb_build_object('ok', false, 'error', 'Revisa la fecha de la colilla.');
  end if;
  if v_valor is null or v_valor <= 0 or v_valor > 10000000 then
    return jsonb_build_object('ok', false, 'error', 'Revisa el valor de la colilla.');
  end if;

  v_foto := p_datos ->> 'foto';
  if v_foto is null or v_foto !~ '^data:image/(jpeg|png|webp);base64,' then
    return jsonb_build_object('ok', false, 'error', 'Falta la foto de la colilla.');
  end if;
  if length(v_foto) > 2000000 then
    return jsonb_build_object('ok', false, 'error', 'La foto es muy pesada. Tómala otra vez.');
  end if;

  -- El veredicto lo calcula el servidor otra vez: lo que mande el celular no se cree.
  v := public._colilla_veredicto(q.ced, v_key, v_fecha, v_valor, p_datos ->> 'comprobante');
  if not coalesce((v ->> 'ok')::boolean, false) then return v; end if;
  if v -> 'duplicada' is not null and v -> 'duplicada' <> 'null'::jsonb then
    return jsonb_build_object('ok', false, 'error',
      'Esta colilla ya la enviaste el ' || (v -> 'duplicada' ->> 'enviada') || ' para otra liquidación.');
  end if;

  -- ¿La colilla trae la cédula? Si no, el banco no sabrá de quién es la plata.
  v_ref := left(btrim(coalesce(p_datos ->> 'referencia', '')), 60);
  v_texto := left(coalesce(p_datos ->> 'ocr_texto', ''), 6000);
  v_refced := regexp_replace(v_ref, '^0+', '') = q.ced
           or exists (select 1 from regexp_matches(v_texto, '\d{5,}', 'g') m
                       where regexp_replace(m[1], '^0+', '') = q.ced);

  insert into public.liq_colillas
    (cedula, nombre, movil, fecha, valor, valor_a_mano, referencia, ref_cedula, comprobante, banco,
     ocr_texto, ocr_confianza, foto, cubre, veredicto, faltante, sobrante)
  values
    (q.ced, q.nombre, btrim(p_movil), v_fecha, v_valor,
     coalesce((p_datos ->> 'valor_a_mano')::boolean, false),
     nullif(v_ref, ''), v_refced,
     nullif(left(btrim(coalesce(p_datos ->> 'comprobante', '')), 40), ''),
     nullif(left(btrim(coalesce(p_datos ->> 'banco', '')), 60), ''),
     nullif(v_texto, ''),
     nullif(p_datos ->> 'ocr_confianza', '')::numeric,
     v_foto,
     (select coalesce(jsonb_agg(jsonb_build_object('key', x ->> 'key', 'fecha', x ->> 'fecha',
                'movil', x ->> 'movil', 'ruta', x ->> 'ruta', 'dinero', (x ->> 'dinero')::bigint,
                'aplicado', (x ->> 'esta')::bigint)), '[]'::jsonb)
        from jsonb_array_elements(v -> 'cubre') x),
     v ->> 'veredicto', (v ->> 'faltante')::bigint, (v ->> 'sobrante')::bigint)
  returning id into v_id;

  return v || jsonb_build_object('id', v_id, 'ref_cedula', v_refced);
exception when others then
  return jsonb_build_object('ok', false, 'error', 'No se pudo guardar: ' || SQLERRM);
end $function$;

revoke all on function public.colilla_identificar(text, text) from public;
revoke all on function public.colilla_analizar(text, text, text, date, numeric, text) from public;
revoke all on function public.colilla_guardar(text, text, jsonb) from public;
grant execute on function public.colilla_identificar(text, text) to anon, authenticated;
grant execute on function public.colilla_analizar(text, text, text, date, numeric, text) to anon, authenticated;
grant execute on function public.colilla_guardar(text, text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------------------------
-- 5) Para administración: las colillas y si el banco las confirma
-- ---------------------------------------------------------------------------------------------
create or replace function public.colillas_listar(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_h date := coalesce(p_hasta, (now() at time zone 'America/Bogota')::date);
  v_d date := coalesce(p_desde, v_h - 30);
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  return jsonb_build_object('ok', true, 'desde', v_d, 'hasta', v_h,
    'filas', (select coalesce(jsonb_agg(x order by x.creado_en desc), '[]'::jsonb) from (
      select c.id, c.creado_en, to_char(c.creado_en at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI') as enviada,
             c.cedula, c.nombre, c.movil, c.fecha, c.valor, c.valor_a_mano, c.referencia, c.ref_cedula,
             c.comprobante, c.banco, c.ocr_confianza, c.cubre, c.veredicto, c.faltante, c.sobrante,
             b.fecha as banco_fecha,
             case when b.id is not null then 'CONFIRMADA'
                  when exists (select 1 from public.recaudos_banco r where r.fecha = c.fecha)
                   and exists (select 1 from public.recaudos_banco r where r.fecha = c.fecha + 1)
                       then 'NO_APARECE'
                  else 'FALTA_EXTRACTO' end as estado_banco
        from public.liq_colillas c
        left join lateral (
          select r.id, r.fecha from public.recaudos_banco r
           where r.cedula = c.cedula and r.valor = c.valor and r.fecha between c.fecha and c.fecha + 1
           order by r.fecha, r.id limit 1) b on true
       where c.fecha between v_d and v_h) x));
end $function$;
revoke all on function public.colillas_listar(date, date) from public, anon;
grant execute on function public.colillas_listar(date, date) to authenticated;

create or replace function public.colilla_foto(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  return jsonb_build_object('ok', true, 'foto', (select foto from public.liq_colillas where id = p_id),
                            'texto', (select ocr_texto from public.liq_colillas where id = p_id));
end $function$;
revoke all on function public.colilla_foto(bigint) from public, anon;
grant execute on function public.colilla_foto(bigint) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- 6) Para la planilla (sql/148): qué colillas tiene cada liquidación. La planilla sigue cruzando
--    VALOR CONSIGNADO solo con el banco; la colilla se informa en OBSERVACIONES, porque mientras
--    el banco no la confirme es lo que dice el conductor, no plata que se vio entrar.
-- ---------------------------------------------------------------------------------------------
create or replace function public.colillas_por_liquidacion(p_desde date, p_hasta date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;
  return jsonb_build_object('ok', true, 'por_key', (
    select coalesce(jsonb_object_agg(s.key, s.info), '{}'::jsonb) from (
      select x.key, jsonb_agg(jsonb_build_object('fecha', c.fecha, 'valor', x.aplicado,
               'confirmada', exists (select 1 from public.recaudos_banco r
                                      where r.cedula = c.cedula and r.valor = c.valor
                                        and r.fecha between c.fecha and c.fecha + 1))
               order by c.fecha) as info
        from public.liq_colillas c,
             jsonb_to_recordset(c.cubre) as x(key text, fecha date, aplicado bigint)
       where x.fecha between p_desde and p_hasta
       group by x.key) s));
end $function$;
revoke all on function public.colillas_por_liquidacion(date, date) from public, anon;
grant execute on function public.colillas_por_liquidacion(date, date) to authenticated;
