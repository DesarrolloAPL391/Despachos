-- 64: El subadmin (operaciones) puede LISTAR usuarios y gestionar los vehículos de
-- afiliados (crear/gestionar accesos). ELIMINAR usuarios sigue siendo solo admin
-- (acción destructiva; el botón se oculta en la UI para el subadmin).

create or replace function public.usuarios_listar()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'email', p.email, 'nombre', p.nombre, 'rol', p.rol, 'activo', p.activo,
      'vehiculos', case when p.rol='afiliado'
                        then (select count(*) from public.afiliado_vehiculos av where lower(trim(av.afiliado_email))=lower(trim(p.email)))
                        else null end
    ) order by (case p.rol when 'admin' then 0 when 'auditor' then 1 when 'afiliado' then 2 else 3 end), p.nombre), '[]'::jsonb)
  from public.perfiles p
  where public.es_subadmin();
$function$;

create or replace function public.afiliado_vehiculos_de(p_email text)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('id',v.id,'numero',v.numero,'placa',v.placa) order by v.numero), '[]'::jsonb)
  from public.afiliado_vehiculos av
  join public.vehiculos v on v.id = av.vehiculo_id
  where lower(trim(av.afiliado_email)) = lower(trim(p_email))
    and public.es_subadmin();
$function$;

create or replace function public.afiliado_asignar_vehiculos(p_email text, p_vehiculo_ids bigint[])
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_n int;
begin
  if not public.es_subadmin() then raise exception 'No autorizado.'; end if;
  if nullif(trim(p_email),'') is null then return jsonb_build_object('ok',false,'error','Correo vacío'); end if;
  delete from public.afiliado_vehiculos where lower(trim(afiliado_email)) = lower(trim(p_email));
  insert into public.afiliado_vehiculos (afiliado_email, vehiculo_id)
    select lower(trim(p_email)), x from unnest(coalesce(p_vehiculo_ids,'{}')) x
    on conflict do nothing;
  select count(*) into v_n from public.afiliado_vehiculos where lower(trim(afiliado_email))=lower(trim(p_email));
  return jsonb_build_object('ok',true,'email',lower(trim(p_email)),'vehiculos',v_n);
end $function$;
