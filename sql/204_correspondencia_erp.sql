-- 204_correspondencia_erp.sql — 📬 Correspondencia dentro del ERP (solo administración) — 24/11/2026
--
-- La app de correspondencia (PWA aparte) usa ESTA misma base: profiles, areas, radicados, radicado_adjuntos,
-- radicado_movimientos y el bucket privado 'adjuntos'. El ERP ahora la muestra al administrador (menú 📬).
--
-- 1) Perfil de correspondencia para el administrador del ERP, con rol 'admin'. Sin él, la RLS de radicados no le
--    deja ver nada y crear un radicado falla (creado_por, subido_por y usuario_id exigen un perfil).
--    Solo AGREGA el perfil a los administradores del ERP que no tienen uno; no cambia ningún perfil que ya exista.
-- 2) generar_numero_radicado (la que consume el consecutivo) la podía llamar cualquiera desde internet (anon) y
--    cualquier usuario con sesión, y así quemar números de radicado. Solo la usa el trigger de radicados (dueño
--    postgres), que la sigue pudiendo usar. reasignar_radicado y decidir_comunicado se cierran a anon (siguen para
--    los usuarios con sesión, con las mismas reglas de siempre).
-- 3) Adjuntos (bucket 'adjuntos'): cualquier usuario con sesión —también los del ERP: afiliados, despachadores…— podía
--    listarlos, bajarlos y borrarlos. Ahora solo quien puede gestionar ESE radicado (su área, quien lo creó o un
--    administrador de la correspondencia): la misma regla que ya tenía la tabla radicado_adjuntos.
--    La ruta de cada archivo es «<id del radicado>/<archivo>» (así la arman la app y el ERP).
--
-- Idempotente. No toca radicados, áreas, movimientos ni el contador.
set lock_timeout = '5s';

-- 1) ------------------------------------------------------------------------------------------------------------
insert into public.profiles (id, nombre_completo, area_id, rol)
select p.id, coalesce(nullif(btrim(p.nombre), ''), 'Administración'), null, 'admin'
  from public.perfiles p
 where p.rol = 'admin' and coalesce(p.activo, true)
   and exists (select 1 from auth.users u where u.id = p.id)
   and not exists (select 1 from public.profiles x where x.id = p.id);

-- 2) ------------------------------------------------------------------------------------------------------------
revoke execute on function public.generar_numero_radicado(text, int) from public, anon, authenticated;
revoke execute on function public.reasignar_radicado(uuid, uuid, text, text) from public, anon;
revoke execute on function public.decidir_comunicado(uuid, text, text) from public, anon;
grant execute on function public.reasignar_radicado(uuid, uuid, text, text) to authenticated;
grant execute on function public.decidir_comunicado(uuid, text, text) to authenticated;

-- 3) ------------------------------------------------------------------------------------------------------------
create or replace function public.corr_puede_objeto(p_name text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  begin
    v_id := split_part(coalesce(p_name, ''), '/', 1)::uuid;
  exception when others then
    return false;                       -- una ruta que no empieza por el id de un radicado: nadie
  end;
  return public.puede_gestionar_radicado(v_id);
end;
$$;
revoke all on function public.corr_puede_objeto(text) from public, anon;
grant execute on function public.corr_puede_objeto(text) to authenticated;

drop policy if exists adjuntos_storage_select on storage.objects;
drop policy if exists adjuntos_storage_insert on storage.objects;
drop policy if exists adjuntos_storage_delete on storage.objects;
create policy adjuntos_storage_select on storage.objects for select to authenticated
  using (bucket_id = 'adjuntos' and public.corr_puede_objeto(name));
create policy adjuntos_storage_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'adjuntos' and public.corr_puede_objeto(name));
create policy adjuntos_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'adjuntos' and public.corr_puede_objeto(name));

-- DESHACER (si hiciera falta):
--   grant execute on function public.generar_numero_radicado(text, int) to anon, authenticated;
--   grant execute on function public.reasignar_radicado(uuid, uuid, text, text) to anon;
--   grant execute on function public.decidir_comunicado(uuid, text, text) to anon;
--   drop policy adjuntos_storage_select on storage.objects; (y _insert, _delete) y volver a crearlas con
--     using / with check (bucket_id = 'adjuntos');  drop function public.corr_puede_objeto(text);
--   El perfil del administrador se puede dejar: solo le da acceso a la correspondencia.
