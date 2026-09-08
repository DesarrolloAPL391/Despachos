-- 60: Resultado de la preventiva (operaciones marca APROBADO / RECHAZADO).
-- Si RECHAZADO: se pide una nueva fecha y se crea una NUEVA cita pendiente
-- (la rechazada queda como histórico). Sirve de "notificación general" a
-- afiliados y despachadores (banner en el módulo + campana del despachador).

-- ---- 1) Columnas de resultado / reprogramación ----
alter table public.preventivas
  add column if not exists resultado_por    text,
  add column if not exists resultado_en     timestamptz,
  add column if not exists motivo_rechazo   text,
  add column if not exists reprogramada_de  bigint,   -- en la cita NUEVA: id de la cita rechazada
  add column if not exists reprogramada_a   bigint;   -- en la cita RECHAZADA: id de la cita nueva
create index if not exists preventivas_reprog_idx on public.preventivas (reprogramada_de);

-- ---- 2) ¿Es del área de OPERACIONES? (marca resultados) ----
-- Operaciones son cuentas de rol 'despachador' cuyo correo contiene 'operaciones'.
-- Marcar el resultado es exclusivo de operaciones/admin (NO de los despachadores de puesto).
create or replace function public.es_operaciones()
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select public.es_admin()
      or ( public.es_despachador()
           and lower(coalesce(auth.email(),'')) like '%operaciones%' );
$$;
revoke all on function public.es_operaciones() from public;
grant execute on function public.es_operaciones() to authenticated;

-- ---- 3) RPC: marcar resultado (y reprogramar si es RECHAZADO) ----
create or replace function public.preventiva_resultado(
  p_id bigint, p_resultado text, p_motivo text default null, p_nueva_fecha date default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v public.preventivas; v_new_id bigint; v_hoy date := (now() at time zone 'America/Bogota')::date;
begin
  if not public.es_operaciones() then raise exception 'Solo operaciones puede marcar el resultado'; end if;
  p_resultado := upper(trim(p_resultado));
  if p_resultado not in ('APROBADO','RECHAZADO') then raise exception 'Resultado inválido: %', p_resultado; end if;

  select * into v from public.preventivas where id = p_id for update;
  if v.id is null then raise exception 'La preventiva % no existe', p_id; end if;

  if p_resultado = 'RECHAZADO' then
    if p_nueva_fecha is null then raise exception 'Un rechazo requiere la nueva fecha de la cita'; end if;
    if p_nueva_fecha < v_hoy then raise exception 'La nueva fecha debe ser de hoy en adelante'; end if;
    -- Nueva cita pendiente (copia los datos del carro), enlazada a la rechazada
    insert into public.preventivas
      (bimestre, interno, placa, centro_costos, ruta, propietario, fecha, lugar, correo_afiliado,
       resultado, reprogramada_de)
    values
      (v.bimestre, v.interno, v.placa, v.centro_costos, v.ruta, v.propietario, p_nueva_fecha, v.lugar, v.correo_afiliado,
       'PENDIENTE POR REVISION', v.id)
    returning id into v_new_id;
  end if;

  update public.preventivas
     set resultado      = p_resultado,
         resultado_por  = coalesce(auth.email(), resultado_por),
         resultado_en   = now(),
         motivo_rechazo = case when p_resultado='RECHAZADO' then nullif(trim(p_motivo),'') else null end,
         reprogramada_a = case when p_resultado='RECHAZADO' then v_new_id else reprogramada_a end
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id, 'resultado', p_resultado,
                            'nueva_id', v_new_id, 'nueva_fecha', p_nueva_fecha);
end $$;
revoke all on function public.preventiva_resultado(bigint,text,text,date) from public;
grant execute on function public.preventiva_resultado(bigint,text,text,date) to authenticated;
