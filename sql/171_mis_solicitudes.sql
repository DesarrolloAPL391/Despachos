-- ===================================================================================
-- 171: CONSULTA DEL ESTADO DE PERMISOS Y VACACIONES (link público mis-solicitudes.html)
-- ===================================================================================
-- Pedido del 05/11/2026: "también un lugar donde se pueda consultar el estado del permiso o las
-- vacaciones". Hasta ahora el estado solo salía dentro de cada formulario, y decía "En trámite" sin
-- decir en quién iba.
--
-- mis_solicitudes(cédula, fecha de nacimiento) devuelve las solicitudes de la persona, cada una con
-- sus pasos: permisos = Gestión Humana y Gerencia (a la vez); vacaciones = el área (afiliado, jefe
-- inmediato o coordinador de ruta) → Gestión Humana → Gerencia (si aplica) → Nómina (sql/169).
-- Mismo freno de intentos que los links (_vac_identificar). De cada paso va el estado y la fecha,
-- nunca quién firmó (correos). El motivo solo cuando se negó, y solo el de quien negó.
-- Una persona inactiva también puede consultar cómo quedaron sus solicitudes.
-- ===================================================================================

create or replace function public.mis_solicitudes(p_cedula text, p_fecha_nacimiento date)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id jsonb := public._vac_identificar(p_cedula, p_fecha_nacimiento); v_p record;
begin
  if not (v_id->>'ok')::boolean then return v_id; end if;
  select nombre, cargo into v_p from public.perfilsociodemografico where cedula = v_id->>'cedula' limit 1;
  return jsonb_build_object('ok', true,
    -- Nombre de pila: en Colombia van primero los dos apellidos.
    'nombre', initcap(lower(coalesce(nullif(array_to_string(
                (regexp_split_to_array(trim(v_p.nombre), '\s+'))[3:], ' '), ''), v_p.nombre))),
    'cargo', v_p.cargo,
    'permisos', (select coalesce(jsonb_agg(jsonb_build_object(
        'radicado', x.radicado, 'fecha_solicitud', x.fecha_solicitud, 'tipo', x.tipo, 'caso', x.caso,
        'parentesco', x.parentesco, 'desde', x.desde, 'hasta', x.hasta, 'estado', x.estado,
        'gh', x.gh_estado, 'gh_en', (x.gh_en at time zone 'America/Bogota')::date,
        'ger', x.ger_estado, 'ger_en', (x.ger_en at time zone 'America/Bogota')::date,
        'anulado_en', (x.anulado_en at time zone 'America/Bogota')::date,
        'nota', case when x.estado = 'NEGADO' then
                  case when x.gh_estado = 'NEGADO' then x.gh_nota else x.ger_nota end end,
        'entregados', (select coalesce(jsonb_agg(distinct s.requisito), '[]'::jsonb)
                         from public.permiso_soportes s where s.permiso_id = x.id and s.requisito is not null))
        order by x.creado_en desc), '[]'::jsonb)
      from (select * from public.permisos
             where cedula = v_id->>'cedula' and creado_en > now() - interval '365 days'
             order by creado_en desc limit 20) x),
    'vacaciones', (select coalesce(jsonb_agg(jsonb_build_object(
        'radicado', v.radicado, 'fecha_solicitud', v.fecha_solicitud, 'periodo', v.periodo,
        'inicio', v.fecha_inicio, 'fin', v.fecha_fin, 'regreso', v.fecha_regreso,
        'disfrute', v.dias_disfrute, 'dinero', v.dias_dinero, 'estado', v.estado,
        'area_tipo', v.area_tipo, 'area', v.area_estado,
        'area_en', coalesce(v.area_fecha, (v.area_en at time zone 'America/Bogota')::date),
        'gh', v.gh_estado, 'gh_en', (v.gh_en at time zone 'America/Bogota')::date,
        'req_gerencia', v.req_gerencia,
        'ger', v.ger_estado, 'ger_en', (v.ger_en at time zone 'America/Bogota')::date,
        'nomina_en', (v.nom_en at time zone 'America/Bogota')::date,
        'anulado_en', (v.anulado_en at time zone 'America/Bogota')::date,
        'nota', case when v.estado = 'NEGADO' then
                  case when v.area_estado = 'NEGADO' then v.area_nota
                       when v.gh_estado = 'NEGADO' then v.gh_nota else v.ger_nota end end)
        order by v.creado_en desc), '[]'::jsonb)
      from (select * from public.vacaciones
             where cedula = v_id->>'cedula' order by creado_en desc limit 10) v));
end $$;
revoke all on function public.mis_solicitudes(text, date) from public;
grant execute on function public.mis_solicitudes(text, date) to anon, authenticated;
