-- ============================================================================================
-- 146 · CERTIFICADO LABORAL — el historial completo de vinculaciones
--
-- 306 de las 1.914 personas han entrado más de una vez a la compañía (hasta 8 veces). El
-- certificado mostraba solo el periodo vigente, así que a esas personas les certificaba una
-- fracción de lo que trabajaron. Ahora salen todos los periodos, del más viejo al más nuevo.
--
-- No se inventa nada: los periodos son los de `perfil_vinculaciones` (sql/75 + sql/143), que
-- es de donde cuelgan la antigüedad y el reingreso. Lo que esté mal en los datos se AVISA
-- antes de expedir, no se corrige a escondidas: un certificado es un documento firmado.
--
-- Se aplica sobre sql/75 (perfil), sql/93-94 (certificado), sql/143 (reingreso).
-- ============================================================================================

create or replace function public.certificado_historial(p_cedula text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  -- Dos filas con exactamente las mismas fechas son el MISMO periodo, no dos entradas: se
  -- agrupan. (Hay quien quedó con la misma vinculación cargada 8 veces; sin esto, el
  -- certificado le imprimiría 8 renglones idénticos.) Agrupar iguales no inventa nada;
  -- cualquier otra rareza se avisa y la corrige una persona.
  with v as (
    select fecha_ingreso, fecha_retiro, max(id) as id,
           max(cargo) as cargo, count(*) as veces
      from public.perfil_vinculaciones
     where cedula = p_cedula
     group by fecha_ingreso, fecha_retiro),
  per as (
    select row_number() over (order by fecha_ingreso nulls last, fecha_retiro nulls last) as nro,
           fecha_ingreso as desde, fecha_retiro as hasta,
           (fecha_retiro is null) as vigente, cargo,
           (fecha_retiro is not null and fecha_ingreso is not null
              and fecha_retiro < fecha_ingreso) as fechas_al_reves,
           (fecha_ingreso is null) as sin_ingreso
      from v),
  av as (
    select 'El periodo ' || nro || ' tiene la fecha de retiro ANTES de la de ingreso.' as a
      from per where fechas_al_reves
    union all
    select 'El periodo ' || nro || ' no tiene fecha de ingreso.' from per where sin_ingreso
    union all
    select 'Hay ' || count(*) || ' periodos sin fecha de retiro: solo uno puede estar vigente.'
      from per where vigente having count(*) > 1
    union all
    -- Entrar otra vez antes de haber salido: o sobra una fila, o una fecha está mal.
    select 'Los periodos ' || a.nro || ' y ' || b.nro || ' se montan uno con otro.'
      from per a join per b on a.nro < b.nro
     where a.hasta is not null and b.desde is not null and a.hasta >= b.desde)
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'n', (select count(*) from per),
      'periodos', (select coalesce(jsonb_agg(jsonb_build_object(
                      'nro', nro, 'desde', desde, 'hasta', hasta,
                      'vigente', vigente, 'cargo', cargo) order by nro), '[]'::jsonb) from per),
      'avisos', (select coalesce(jsonb_agg(a), '[]'::jsonb) from av))
  end;
$$;
revoke all on function public.certificado_historial(text) from public, anon;
grant execute on function public.certificado_historial(text) to authenticated;

comment on function public.certificado_historial(text) is
  'Periodos trabajados de una persona para el certificado laboral, del mas viejo al mas nuevo, con los avisos de lo que este mal en las fechas.';

-- ---------------------------------------------------------------------------------------------
-- Para revisar qué hay que corregir (no cambia nada):
--   select cedula, count(*) from public.perfil_vinculaciones
--    where fecha_retiro is not null and fecha_ingreso is not null and fecha_retiro < fecha_ingreso
--    group by cedula;
--   select cedula from public.perfil_vinculaciones where fecha_retiro is null
--    group by cedula having count(*) > 1;
-- ---------------------------------------------------------------------------------------------
