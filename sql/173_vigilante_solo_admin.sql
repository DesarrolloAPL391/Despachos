-- 173: por ahora los resultados del 🚨 Vigilante de ruta los ve SOLO administración.
-- sql/172 dejaba ver y auditar a los auditores (sus rutas). Se cierra en la base, no solo en la pantalla:
-- vigilancia_listar, vigilancia_caso y vigilancia_auditar pasan todas por _vig_puede.
-- El vigilante (cron) sigue igual juntando casos de todas las rutas.
-- Para abrirlo a los auditores más adelante: volver a correr el _vig_puede y el vigilancia_listar de sql/172
-- y cambiar openVigilante y el menú a isAdmin() || isAuditor().

create or replace function public._vig_puede(p_ruta text, p_ruta_mapa text)
returns boolean
language sql stable security definer set search_path to 'public'
as $$
  select (select public.es_admin());
$$;
revoke all on function public._vig_puede(text, text) from public, anon, authenticated;

create or replace function public.vigilancia_listar(p_desde date, p_hasta date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 62 then
    return jsonb_build_object('ok', false, 'error', 'Elige un rango de máximo dos meses.');
  end if;
  return jsonb_build_object('ok', true, 'casos', (
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'fecha', c.fecha, 'tipo', c.tipo, 'estado', c.estado, 'ruta', c.ruta, 'kmz', c.kmz,
        'movil', c.movil, 'movil_rel', c.movil_rel, 'causa', c.causa, 'causas', c.causas,
        'desde', to_char(c.desde at time zone 'America/Bogota', 'HH24:MI'),
        'hasta', to_char(coalesce(c.hasta, c.visto_en) at time zone 'America/Bogota', 'HH24:MI'),
        'minutos', round(extract(epoch from coalesce(c.hasta, c.visto_en) - c.desde) / 60),
        'sale', to_char(c.inicio_viaje at time zone 'America/Bogota', 'HH24:MI'),
        'sale_rel', to_char(c.inicio_rel at time zone 'America/Bogota', 'HH24:MI'),
        'par_total', c.par_total, 'punto_desde', c.punto_desde, 'punto_hasta', c.punto_hasta,
        'max_dist', c.max_dist, 'decision', c.decision, 'responsable', c.responsable, 'medida', c.medida,
        'auditado_por', c.auditado_por, 'marcado', jsonb_array_length(c.marcado))
        order by c.desde desc), '[]'::jsonb)
      from public.vigilancia_casos c
     where c.fecha between p_desde and p_hasta and c.estado in ('ABIERTO', 'CERRADO')
       and public._vig_puede(c.ruta, c.ruta_mapa)));
end $$;
revoke all on function public.vigilancia_listar(date, date) from public, anon;
grant execute on function public.vigilancia_listar(date, date) to authenticated;
