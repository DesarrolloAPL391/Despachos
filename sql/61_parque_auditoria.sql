-- 61: Respaldo de CUALQUIER edición del parque automotor (no solo documentos).
-- Un trigger registra quién cambió qué y cuándo (antes → después) en cada fila.
-- Los cambios de documentos ya tienen su propio historial (vehiculo_documentos);
-- esto cubre el resto de la ficha (estado, ruta, propietario, marca, modelo, etc.).

create table if not exists public.parque_auditoria (
  id             bigint generated always as identity primary key,
  vehiculo_id    bigint,
  numero_interno text,
  placa          text,
  accion         text,        -- insert | update | delete
  cambios        jsonb,       -- update: {campo: {antes, despues}}; insert/delete: fila completa
  por            text,        -- correo del usuario (auth.email) o 'sistema'
  en             timestamptz not null default now()
);
create index if not exists parque_auditoria_veh_idx on public.parque_auditoria (vehiculo_id, en desc);

create or replace function public.parque_audit_trg()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
declare v_cambios jsonb := '{}'::jsonb; k text; v_old jsonb; v_new jsonb; v_por text := coalesce(auth.email(),'sistema');
begin
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old); v_new := to_jsonb(new);
    for k in select jsonb_object_keys(v_new) loop
      if k in ('id','created_at') then continue; end if;
      if (v_old->k) is distinct from (v_new->k) then
        v_cambios := v_cambios || jsonb_build_object(k, jsonb_build_object('antes', v_old->k, 'despues', v_new->k));
      end if;
    end loop;
    if v_cambios = '{}'::jsonb then return new; end if;  -- no cambió nada relevante
    insert into public.parque_auditoria(vehiculo_id,numero_interno,placa,accion,cambios,por)
      values (new.id, new.numero_interno, new.placa, 'update', v_cambios, v_por);
    return new;
  elsif tg_op = 'INSERT' then
    insert into public.parque_auditoria(vehiculo_id,numero_interno,placa,accion,cambios,por)
      values (new.id, new.numero_interno, new.placa, 'insert', to_jsonb(new), v_por);
    return new;
  else -- DELETE
    insert into public.parque_auditoria(vehiculo_id,numero_interno,placa,accion,cambios,por)
      values (old.id, old.numero_interno, old.placa, 'delete', to_jsonb(old), v_por);
    return old;
  end if;
end $$;

drop trigger if exists parque_audit_aiud on public.parque_automotor;
create trigger parque_audit_aiud
  after insert or update or delete on public.parque_automotor
  for each row execute function public.parque_audit_trg();

-- RLS: solo admin y operaciones consultan la auditoría (es lectura de control)
alter table public.parque_auditoria enable row level security;
drop policy if exists parque_auditoria_sel on public.parque_auditoria;
create policy parque_auditoria_sel on public.parque_auditoria
  for select to authenticated
  using ( (select public.es_admin()) or (select public.es_operaciones()) );

-- RPC de lectura del historial de un vehículo (evita depender de la RLS por fila)
create or replace function public.parque_auditoria_veh(p_vehiculo_id bigint)
returns setof public.parque_auditoria
language sql stable security definer set search_path to 'public'
as $$
  select * from public.parque_auditoria
  where vehiculo_id = p_vehiculo_id
    and ( public.es_admin() or public.es_operaciones() )
  order by en desc limit 100;
$$;
revoke all on function public.parque_auditoria_veh(bigint) from public;
grant execute on function public.parque_auditoria_veh(bigint) to authenticated;
