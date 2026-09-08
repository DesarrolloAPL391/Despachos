-- 62: Suspensión de despacho por preventiva RECHAZADA.
-- Regla: un vehículo queda SUSPENDIDO para despacho si el ÚLTIMO resultado de
-- preventiva (por resultado_en) es RECHAZADO. Se levanta cuando operaciones
-- APRUEBA la revisión (la reprogramada), porque ese pasa a ser el último resultado.

create or replace function public.preventiva_suspendido(p_interno text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select coalesce((
    select resultado = 'RECHAZADO'
    from public.preventivas
    where interno = p_interno and resultado in ('APROBADO','RECHAZADO')
    order by resultado_en desc nulls last, id desc
    limit 1
  ), false);
$$;
revoke all on function public.preventiva_suspendido(text) from public;
grant execute on function public.preventiva_suspendido(text) to authenticated;

-- Detalle del bloqueo para mostrar al despachador (fecha del rechazo, motivo, nueva cita)
create or replace function public.preventiva_bloqueo(p_interno text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare u public.preventivas; v_nueva date;
begin
  select * into u from public.preventivas
   where interno = p_interno and resultado in ('APROBADO','RECHAZADO')
   order by resultado_en desc nulls last, id desc limit 1;
  if u.id is null or u.resultado <> 'RECHAZADO' then
    return jsonb_build_object('bloqueado', false);
  end if;
  if u.reprogramada_a is not null then
    select fecha into v_nueva from public.preventivas where id = u.reprogramada_a;
  end if;
  return jsonb_build_object('bloqueado', true, 'interno', u.interno,
    'fecha_rechazo', u.fecha, 'motivo', u.motivo_rechazo,
    'resultado_en', u.resultado_en, 'nueva_fecha', v_nueva);
end $$;
revoke all on function public.preventiva_bloqueo(text) from public;
grant execute on function public.preventiva_bloqueo(text) to authenticated;
