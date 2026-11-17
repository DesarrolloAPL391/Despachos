-- 191: cancelar un viaje en SONAR pasa del despachador al MONITOR (auditor) de la ruta (pedido del usuario, 16/11/2026).
-- Nueva RPC cancelar_despacho(tabla, id, comentario), que valida y hace todo en el servidor:
--   * solo admin o auditor; el auditor solo en viajes de SUS rutas (las mismas que puede editar: rutas_auditor()).
--   * sesion vigente (sesion unica), viaje de HOY, con regId, despachado hace 50 min o menos (la regla de siempre).
--   * el movil y el regId salen de la fila, no del formulario.
--   * cancela en SONAR (cancelar_sonar = SET_ItCancel) y, si SONAR acepta, marca la fila CANCELADO, limpia el regId y
--     deja el sello del monitor (auditor_id + fecha_hora_auditoria).
-- Va con sql/192, que quita la llamada directa a cancelar_sonar al rol authenticated (se aplica al publicar la app).
set lock_timeout = '5s';

create or replace function public.cancelar_despacho(p_tabla text, p_id text, p_comments text default '')
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_admin boolean := public.es_admin();
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_rel regclass;
  v_id text; v_fecha date; v_ruta bigint; v_veh bigint; v_reg text; v_desp timestamptz;
  v_mid text; v_movil text; v_aud bigint; v_min int; v_res jsonb; v_n int;
begin
  if not (v_admin or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'Solo los monitores (auditores) pueden cancelar viajes.');
  end if;
  if not public.es_sesion_vigente() then
    return jsonb_build_object('ok', false, 'error', 'Tu sesion ya no esta vigente. Vuelve a entrar.');
  end if;

  -- solo tablas de despacho: tablas de public que tienen TODAS estas columnas (Despachos y las tablas de puesto)
  if coalesce(trim(p_tabla), '') = '' or coalesce(trim(p_id), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el viaje.');
  end if;
  v_rel := to_regclass('public.' || quote_ident(p_tabla));
  if v_rel is null
     or (select c.relkind from pg_class c where c.oid = v_rel) <> 'r'
     or (select count(*) from pg_attribute a where a.attrelid = v_rel and a.attnum > 0 and not a.attisdropped
          and a.attname in ('id', 'fecha', 'ruta_id', 'vehiculo_id', 'sonar_regid', 'estado_despacho', 'despachado_en',
                            'auditor_id', 'fecha_hora_auditoria')) <> 9 then
    return jsonb_build_object('ok', false, 'error', 'Esa tabla no es de despachos.');
  end if;

  execute format('select id::text, fecha, ruta_id, vehiculo_id, sonar_regid, despachado_en from %s where id::text = $1', v_rel)
    into v_id, v_fecha, v_ruta, v_veh, v_reg, v_desp using p_id;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'No se encontro el viaje.');
  end if;
  if not v_admin and not coalesce(v_ruta = any(public.rutas_auditor()), false) then
    return jsonb_build_object('ok', false, 'error', 'Ese viaje es de una ruta que no tienes asignada: no lo puedes cancelar.');
  end if;
  if coalesce(trim(v_reg), '') !~ '^[0-9]+$' then
    return jsonb_build_object('ok', false, 'error', 'Ese viaje no tiene regId de SONAR: no hay nada que cancelar.');
  end if;
  if v_fecha is distinct from v_hoy then
    return jsonb_build_object('ok', false, 'error', 'Solo se cancelan viajes de hoy.');
  end if;
  v_min := floor(extract(epoch from (now() - v_desp)) / 60);
  if v_min > 50 then
    return jsonb_build_object('ok', false, 'error', format('No se puede cancelar: el viaje ya supera los 50 min (lleva %s min).', v_min));
  end if;

  select v.numero, g.tracker_id into v_movil, v_mid
    from public.vehiculos v left join public.vehiculosgps g on g.movil = v.numero
   where v.id = v_veh limit 1;
  if coalesce(trim(v_mid), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'El movil ' || coalesce(v_movil, '?') || ' no tiene Id GPS en SONAR.');
  end if;

  -- SONAR: misma llamada de siempre (SET_ItCancel); 6,5 s de espera, por debajo del tope de 8 s de la app
  perform set_config('http.timeout_msec', '6500', true);
  v_res := public.cancelar_sonar(v_mid, trim(v_reg), coalesce(p_comments, ''));
  if not coalesce((v_res->>'ok')::boolean, false) then
    return v_res || jsonb_build_object('ok', false);
  end if;

  -- SONAR acepto: la fila queda CANCELADO, sin regId (se puede volver a despachar) y con el sello del monitor
  if not v_admin then
    select a.id into v_aud from public.auditores a where lower(trim(a.email)) = lower(trim(auth.email())) limit 1;
  end if;
  begin
    execute format('update %s set estado_despacho = ''CANCELADO'', sonar_regid = null, '
                || 'auditor_id = coalesce($2, auditor_id), '
                || 'fecha_hora_auditoria = case when $2 is null then fecha_hora_auditoria else now() end '
                || 'where id::text = $1', v_rel)
      using v_id, v_aud;
    get diagnostics v_n = row_count;
  exception when others then
    return v_res || jsonb_build_object('ok', true, 'aviso', 'Se cancelo en SONAR, pero no se pudo marcar la fila: ' || sqlerrm);
  end;
  return v_res || jsonb_build_object('ok', true, 'regid', trim(v_reg), 'movil', v_movil, 'filas', v_n);
end $$;

revoke all on function public.cancelar_despacho(text, text, text) from public, anon;
grant execute on function public.cancelar_despacho(text, text, text) to authenticated;
