-- 208: ✅ Revisión de viajes en las FILAS de Despachos y de las tablas de puesto (pedido del 25/11/2026: "meterlo entre las
-- tablas y despachos para que el monitor lo vea más visual y sea más práctico").
--   * revision_por_viajes(regids): la revisión de los viajes de una tabla, por su regId (= despachos_sonar.itl_id), con la
--     MISMA ficha de revision_viajes_dia (sql/206): el armador (scratchpad/audauto/armar_208.py) la copia del texto de 206.
--     Va en línea y no como función por viaje: así la pantalla tardaba 4 veces más (medido: 0,45 s -> 2,1 s el día entero).
-- Solo una función nueva: no toca datos. DESHACER: drop function public.revision_por_viajes(text[]);

-- La revisión de los viajes de una tabla (Despachos o de puesto), por su regId de SONAR (= itl_id). Misma regla de
-- permisos que la pantalla: admin todo; el monitor, los viajes de sus rutas.
create or replace function public.revision_por_viajes(p_regids text[])
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_ids bigint[];
  v_admin boolean := (select public.es_admin());
  v_rutas text[];
begin
  if not (v_admin or (select public.es_auditor())) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y monitores.');
  end if;
  select array_agg(distinct x::bigint) into v_ids from unnest(coalesce(p_regids, '{}')) x where x ~ '^[0-9]{1,18}$';
  if v_ids is null then return jsonb_build_object('ok', true, 'viajes', '[]'::jsonb); end if;
  if cardinality(v_ids) > 2000 then return jsonb_build_object('ok', false, 'error', 'Demasiados viajes.'); end if;
  if not v_admin then
    select coalesce(array_agg(lower(btrim(r.nombre))), '{}') into v_rutas from public.rutas r where r.id = any (public.rutas_auditor());
  end if;
  return jsonb_build_object('ok', true, 'viajes', (
    select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.itl_id::text, 'fecha', d.fecha, 'hora', left(d.hora_inicio::text, 5), 'ruta', d.ruta, 'movil', d.movil,
           'placa', d.placa, 'conductor', d.conductor, 'mid', d.mid, 'estado', d.estado,
           'revision', d.revision, 'por', coalesce(to_jsonb(d.revision_por), '[]'::jsonb), 'auto', d.revision_auto,
           'motivo', d.motivo, 'decision', d.decision, 'nota', d.observacion,
           'quien', case when d.revision = 'REVISADO' then d.auditor_email end,
           'cuando', case when d.revision = 'REVISADO' then to_char(d.auditado_en at time zone 'America/Bogota', 'DD/MM HH24:MI') end,
           'det', case when w.regid is not null then jsonb_build_object(
               'estado', w.estado,
               'inicio', to_char(w.inicio at time zone 'America/Bogota', 'HH24:MI'),
               'fin', to_char(w.fin at time zone 'America/Bogota', 'HH24:MI'),
               'seg', round(extract(epoch from w.fin - w.inicio)),
               'total', w.puntos_total, 'marcados', cardinality(coalesce(w.marcados, '{}')),
               'faltan', (select coalesce(jsonb_agg(jsonb_build_object('i', ip.point_index, 'n', ip.geofence_name) order by ip.point_index), '[]'::jsonb)
                            from public.itinerario_puntos ip
                           where ip.it_id = w.it_id and not (ip.point_index = any (coalesce(w.marcados, '{}')))),
               'ultimo', (select jsonb_build_object('i', ip.point_index, 'n', ip.geofence_name)
                            from public.itinerario_puntos ip
                           where ip.it_id = w.it_id and ip.point_index = (select max(m) from unnest(w.marcados) m)),
               'tarde', cardinality(coalesce(w.tarde, '{}')), 'antes', cardinality(coalesce(w.antes, '{}')),
               'atraso_fin', w.atraso_fin, 'atraso_max', w.atraso_max,
               'salio_ruta', w.salio_ruta, 'cancelo_usuario', w.cancelo_usuario,
               'revisado', to_char(w.revisado at time zone 'America/Bogota', 'HH24:MI')) end,
           'casos', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', c.id, 'fecha', c.fecha, 'tipo', c.tipo, 'estado', c.estado, 'ruta', c.ruta,
                 'movil', c.movil, 'movil_rel', c.movil_rel, 'regid', c.regid::text, 'regid_rel', c.regid_rel::text,
                 'rol', case when c.regid = d.itl_id then 'PROPIO' else 'ADELANTE' end,
                 'causa', c.causa,
                 'desde', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'),
                 'hasta', to_char(coalesce(c.hasta, c.visto_en) at time zone 'America/Bogota', 'HH24:MI'),
                 'minutos', round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60),
                 'sale', to_char(c.inicio_viaje at time zone 'America/Bogota', 'HH24:MI'),
                 'sale_rel', to_char(c.inicio_rel at time zone 'America/Bogota', 'HH24:MI'),
                 'par_total', c.par_total, 'punto_desde', c.punto_desde, 'punto_hasta', c.punto_hasta, 'max_dist', c.max_dist,
                 'decision', c.decision, 'responsable', c.responsable, 'nota', c.nota, 'auditado_por', c.auditado_por,
                 'ruido', public._vig_ruido(c)) order by c.desde), '[]'::jsonb)
               from public._rev_casos(d.itl_id) c)
         ) order by d.hora_inicio, d.ruta, d.movil), '[]'::jsonb)
      from public.despachos_sonar d
      left join public.viajes_sonar_detalle w on w.regid = d.itl_id
     where d.itl_id = any (v_ids) and (v_admin or lower(btrim(coalesce(d.ruta, ''))) = any (v_rutas))));
end $fn$;
revoke all on function public.revision_por_viajes(text[]) from public, anon;
grant execute on function public.revision_por_viajes(text[]) to authenticated;

notify pgrst, 'reload schema';
