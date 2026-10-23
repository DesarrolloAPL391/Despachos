-- 136_gps_salud_operando.sql
-- "que estos 13 gps mudos se muestren en la pantalla para los auditores y para el
--  administrador" (23/10/2026).
--
-- La pantalla de sql/135 ya listaba los equipos mudos, pero todos revueltos: hoy son 52 y de
-- esos solo 13 importan de verdad. La diferencia no es de grado, es de naturaleza:
--
--   * 13 buses SALIERON A OPERAR HOY y su GPS no reporta -> estan rodando con pasajeros y no se
--     ven en el mapa. Eso es lo que hay que mandar a reparar.
--   * 39 no salieron (mantenimiento, sin programacion, carro quieto). Un GPS quieto no reporta
--     porque el bus no se movio; no es una falla.
--
-- Por eso la funcion ahora cruza `ubicaciones` con los despachos del dia (misma union por
-- numero interno que usa preop_panel, sql/132: se comprobo que los 152 que salieron hoy cruzan
-- 152/152) y devuelve DOS listas: `operando` (los urgentes, con los viajes que hizo el carro) y
-- `resto` (para que quede el panorama completo, pero abajo).
--
-- Tambien se cubre un caso que antes no se veia: un bus que salio y NO TIENE NI FILA en
-- `ubicaciones`. Hoy son 0, pero si manana se le retira el GPS a un carro que sigue rodando,
-- ese carro desaparece del mapa sin dejar rastro. Entra en `operando` como 'no tiene posicion'.
--
-- Se conservan las claves `pegados_2h` y `detalle` de sql/135: hay celulares con la version
-- anterior de la app en cache y la pantalla vieja debe seguir mostrando algo.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

create or replace function public.gps_salud()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_f   date := (now() at time zone 'America/Bogota')::date;
  v_out jsonb;
begin
  if not ((select public.es_admin()) or (select public.es_auditor())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion y control.');
  end if;

  with sal as ( -- los buses que REALMENTE salieron hoy
    select btrim(v.numero) as movil,
           max(btrim(coalesce(v.placa, ''))) as placa,
           count(*)::int as viajes
      from public.despachos d
      join public.vehiculos v on v.id = d.vehiculo_id
     where d.fecha = v_f
       and btrim(coalesce(v.numero, '')) <> ''
     group by btrim(v.numero)
  ),
  malos as ( -- equipos del mapa que no reportan, o cuyo GPS SONAR ya no conoce
    select btrim(coalesce(u.movil, '')) as movil, u.placa, u.mid, u.gps_gmt,
           not exists (select 1 from public.vehiculosgps g where g.tracker_id = u.mid) as fantasma
      from public.ubicaciones u
     where u.gps_gmt <= now() - interval '2 hours'
        or not exists (select 1 from public.vehiculosgps g where g.tracker_id = u.mid)
  ),
  sin_fila as ( -- salio hoy y no tiene ni posicion: invisible en el mapa
    select s.movil, s.placa, null::text as mid, null::timestamptz as gps_gmt,
           false as fantasma, s.viajes
      from sal s
     where not exists (select 1 from public.ubicaciones u
                        where btrim(coalesce(u.movil, '')) = s.movil)
  ),
  fila as (
    select t.movil, t.placa, t.mid, t.gps_gmt, t.fantasma, t.viajes, t.operando,
           -- En pantalla la fecha va corta (al lado ya esta el "hace"); en el Excel que se le
           -- manda al proveedor va completa, que ahi no puede quedar ambigua. Formato
           -- colombiano dd/mm en ambos.
           case when t.gps_gmt is null then 'nunca'
                when extract(year from t.gps_gmt at time zone 'America/Bogota')
                     = extract(year from v_f)
                  then to_char(t.gps_gmt at time zone 'America/Bogota', 'DD/MM HH24:MI')
                else to_char(t.gps_gmt at time zone 'America/Bogota', 'DD/MM/YY')
           end as ultimo,
           coalesce(to_char(t.gps_gmt at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI'),
                    'nunca') as ultimo_largo,
           -- Se trunca, no se redondea: "23 horas" nunca debe leerse "24 horas", porque un dia
           -- entero sin reportar es otra conversacion con el proveedor.
           case when t.gps_gmt is null then 'nunca'
                when now() - t.gps_gmt >= interval '2 days'
                  then extract(day from now() - t.gps_gmt)::int || ' días'
                when now() - t.gps_gmt >= interval '1 day' then '1 día'
                else greatest(2, floor(extract(epoch from now() - t.gps_gmt) / 3600)::int) || ' horas'
           end as hace,
           case when t.gps_gmt is null then 'No tiene posición en el mapa'
                when t.fantasma       then 'GPS que SONAR ya no reconoce'
                else 'Sin reportar'
           end as problema
      from (
        select m.movil, m.placa, m.mid, m.gps_gmt, m.fantasma,
               coalesce(s.viajes, 0) as viajes, (s.movil is not null) as operando
          from malos m
          left join sal s on s.movil = m.movil
        union all
        select f.movil, f.placa, f.mid, f.gps_gmt, f.fantasma, f.viajes, true
          from sin_fila f
      ) t
  )
  select jsonb_build_object(
    'ok', true,
    'fecha', v_f,
    'total',          (select count(*) from public.ubicaciones),
    'frescos_15min',  (select count(*) from public.ubicaciones
                        where gps_gmt > now() - interval '15 minutes'),
    'pegados_2h',     (select count(*) from public.ubicaciones
                        where gps_gmt <= now() - interval '2 hours'),
    'fantasmas',      (select count(*) from fila where fantasma),
    'duplicados',     (select count(*) from (select movil from public.ubicaciones
                         where coalesce(movil, '') <> '' group by movil having count(*) > 1) d),
    'salieron_hoy',   (select count(*) from sal),
    'operando_mudos', (select count(*) from fila where operando),

    -- LOS URGENTES: salieron hoy y no se ven
    'operando', (select coalesce(jsonb_agg(jsonb_build_object(
                   'movil', f.movil, 'placa', f.placa, 'mid', f.mid,
                   'ultimo', f.ultimo, 'ultimo_largo', f.ultimo_largo,
                   'hace', f.hace, 'viajes', f.viajes,
                   'problema', f.problema) order by f.gps_gmt nulls first), '[]'::jsonb)
                   from fila f where f.operando),

    -- El resto: carros que hoy no salieron
    'resto', (select coalesce(jsonb_agg(jsonb_build_object(
                'movil', f.movil, 'placa', f.placa, 'mid', f.mid,
                'ultimo', f.ultimo, 'hace', f.hace,
                'problema', f.problema) order by f.gps_gmt nulls first), '[]'::jsonb)
                from fila f where not f.operando),

    -- Compatibilidad con la pantalla de sql/135 que puede estar en cache
    'detalle', (select coalesce(jsonb_agg(jsonb_build_object(
                  'movil', f.movil, 'placa', f.placa, 'mid', f.mid,
                  'ultimo', f.ultimo,
                  'problema', case when f.operando then 'SALIO HOY - ' || f.problema
                                   else f.problema end)
                  order by f.operando desc, f.gps_gmt nulls first), '[]'::jsonb)
                  from fila f)
  ) into v_out;

  return v_out;
end $function$;

revoke all on function public.gps_salud() from public, anon;
grant execute on function public.gps_salud() to authenticated;

-- Comprobacion (solo lectura)
with sal as (
  select btrim(v.numero) as movil
    from public.despachos d
    join public.vehiculos v on v.id = d.vehiculo_id
   where d.fecha = (now() at time zone 'America/Bogota')::date
     and btrim(coalesce(v.numero, '')) <> ''
   group by btrim(v.numero))
select 'buses que salieron hoy' as dato, count(*)::text as valor from sal
union all
select 'de esos, mudos (van en la lista urgente)',
       (select count(*)::text from sal s join public.ubicaciones u
          on btrim(coalesce(u.movil, '')) = s.movil
        where u.gps_gmt <= now() - interval '2 hours')
union all
select 'mudos que hoy no salieron (van abajo)',
       (select count(*)::text from public.ubicaciones u
         where u.gps_gmt <= now() - interval '2 hours'
           and not exists (select 1 from sal s where s.movil = btrim(coalesce(u.movil, ''))))
union all
select 'la funcion separa operando del resto',
       case when position('operando_mudos' in
                 pg_get_functiondef('public.gps_salud()'::regprocedure)) > 0
            then 'si' else 'NO' end;
