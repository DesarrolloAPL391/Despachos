-- =====================================================================================
-- 161 · Reclamaciones: la lista trae todo para el tablero y el Excel
-- =====================================================================================
-- Seguridad vial necesita ver de un vistazo cuáles llegaron nuevas, cuáles están en trámite,
-- cuáles ya tienen todos los documentos y cuáles se resolvieron, y bajarlo todo a Excel.
-- reclamacion_lista() (sql/160) solo traía el conteo; ahora trae además:
--   * la reclamación completa (sin el token, la IP ni el navegador),
--   * `requisitos`: el estado de CADA documento (codigo → FALTA / RECIBIDO / ACEPTADO / RECHAZADO /
--     OPCIONAL / NO_APLICA), para el mapa de documentos de la lista y las columnas del Excel,
--   * `n_docs` y `docs_despues`: cuántos archivos tiene y cuántos subió el reclamante después
--     de radicar (lo que completó por "Consultar o completar"),
--   * `gestionada`: si alguien de la empresa ya la tocó (revisó un documento, escribió, cambió
--     el estado). Una RECIBIDA sin gestionar es una reclamación nueva.
-- La lista de chequeo se calcula UNA vez por reclamación (antes, dos).
-- =====================================================================================
create or replace function public.reclamacion_lista()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso.');
  end if;
  return jsonb_build_object('ok', true, 'filas', coalesce((
    select jsonb_agg((to_jsonb(x) - 'token_subida' - 'token_vence' - 'ip_origen' - 'agente') || jsonb_build_object(
             'conteo', public._rcl_conteo(c.chk),
             'requisitos', (select jsonb_object_agg(e->>'codigo', e->>'estado') from jsonb_array_elements(c.chk) e),
             'n_docs', d.n, 'docs_despues', d.despues, 'ultimo_doc', d.ultimo,
             'ultima_gestion', g.ultima, 'gestionada', g.ultima is not null)
           order by x.creado_en desc)
      from public.reclamaciones x
      cross join lateral (select public._rcl_checklist(x.id, false) as chk) c
      cross join lateral (
        select count(*) as n,
               count(*) filter (where y.creado_en > x.creado_en + interval '30 minutes') as despues,
               max(y.creado_en) as ultimo
          from public.reclamacion_docs y where y.reclamacion_id = x.id) d
      cross join lateral (
        select max(z.creado_en) as ultima
          from public.reclamacion_gestion z
         where z.reclamacion_id = x.id and coalesce(z.usuario, '') <> 'reclamante') g
  ), '[]'::jsonb));
end $fn$;
revoke all on function public.reclamacion_lista() from public, anon;
grant execute on function public.reclamacion_lista() to authenticated;
