-- ============================================================================================
-- 96) Proponer quién firma, buscándolo en el perfil
--
-- POR QUÉ: al abrir la pantalla de firmas sale vacía y hay que escribir los nombres a mano. Pero
-- el gerente y quien lleva Gestión Humana ya están en el Perfil sociodemográfico, con su cargo y
-- activos. Pedirle a alguien que vuelva a teclear un dato que el sistema ya tiene es la forma más
-- fácil de que quede mal escrito y de que el certificado salga con un nombre que no coincide.
--
-- Esta función NO decide: propone. Quien configura elige de la lista (o escribe otro nombre, si
-- quien firma no está en el perfil).
--
-- Se aplica sobre sql/94 y 95.
-- ============================================================================================

create or replace function public.certificado_firmantes_sugerir()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with base as (
    select p.nombre, p.cargo,
           translate(upper(coalesce(p.cargo, '')), 'ÁÉÍÓÚÑ', 'AEIOUN') as cargo_n,
           translate(upper(coalesce(p.area,  '')), 'ÁÉÍÓÚÑ', 'AEIOUN') as area_n
      from public.perfilsociodemografico p
     where p.estado = 'ACTIVO' and coalesce(p.nombre, '') <> ''
  )
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      -- Gerencia: primero el gerente general, después el resto de la gerencia.
      'GERENTE', (select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'cargo', cargo)
                          order by orden, nombre), '[]'::jsonb)
                    from (select nombre, cargo,
                                 case when cargo_n like '%GERENTE GENERAL%' then 1
                                      when cargo_n like '%GERENTE%' then 2
                                      else 3 end as orden
                            from base
                           where cargo_n like '%GERENTE%' or area_n = 'GERENCIA'
                           limit 10) g),
      -- Gestión Humana: el coordinador primero; también valen talento/recurso humano y vinculaciones.
      'GESTION_HUMANA', (select coalesce(jsonb_agg(jsonb_build_object('nombre', nombre, 'cargo', cargo)
                                  order by orden, nombre), '[]'::jsonb)
                    from (select nombre, cargo,
                                 case when cargo_n like '%COORDINADOR%HUMANA%'
                                        or cargo_n like '%COORDINADOR%HUMANO%' then 1
                                      when cargo_n like '%GESTION HUMANA%'
                                        or cargo_n like '%TALENTO HUMANO%'
                                        or cargo_n like '%RECURSO%HUMANO%' then 2
                                      when cargo_n like '%VINCULACION%' then 3
                                      else 4 end as orden
                            from base
                           where cargo_n like '%GESTION HUMANA%' or cargo_n like '%TALENTO HUMANO%'
                              or cargo_n like '%RECURSO%HUMANO%' or cargo_n like '%VINCULACION%'
                              or area_n = 'RECURSO HUMANO'
                           limit 10) h))
  end;
$$;
revoke all on function public.certificado_firmantes_sugerir() from public, anon;
grant execute on function public.certificado_firmantes_sugerir() to authenticated;
