-- ============================================================================================
-- 80) SINIESTROS: que también los vea GESTIÓN HUMANA
-- En sql/79 los siniestros quedaron SOLO para el administrador. Se amplía a `es_talento_humano()`
-- (administrador + Gestión Humana), igual que el perfil sociodemográfico: Gestión Humana puede
-- consultar los reportes, descargarlos y traer la hoja con el botón "🔄 Traer siniestros".
-- Nadie más los ve (despachadores, auditores y afiliados siguen sin acceso).
-- Se puede aplicar tal cual sobre la base donde ya se aplicó sql/79: solo reemplaza las dos
-- políticas y vuelve a crear las dos funciones con el permiso ampliado (los datos no se tocan).
-- ============================================================================================

-- 1) Permisos de las tablas --------------------------
alter table public.siniestros        enable row level security;
alter table public.siniestros_fuente enable row level security;

drop policy if exists siniestros_admin on public.siniestros;
drop policy if exists siniestros_th on public.siniestros;
create policy siniestros_th on public.siniestros
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));

drop policy if exists siniestros_fuente_admin on public.siniestros_fuente;
drop policy if exists siniestros_fuente_th on public.siniestros_fuente;
create policy siniestros_fuente_th on public.siniestros_fuente
  for all to authenticated
  using ((select public.es_talento_humano())) with check ((select public.es_talento_humano()));

revoke all on public.siniestros        from public, anon;
revoke all on public.siniestros_fuente from public, anon;
grant select, insert, update, delete on public.siniestros to authenticated;
grant select, insert, update on public.siniestros_fuente to authenticated;

-- 2) Carga desde la app: recibe las filas ya interpretadas y las inserta o actualiza ----------
-- Se llama por lotes (p_filas = arreglo de objetos con las llaves de la tabla). Devuelve
-- cuántas quedaron nuevas y cuántas se actualizaron.
create or replace function public.siniestros_cargar(p_filas jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_nuevos int := 0; v_upd int := 0; v_key text; v_existe boolean;
begin
  if not public.es_talento_humano() then
    raise exception 'Solo un administrador o Gestion Humana puede cargar los siniestros.';
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'Se esperaba una lista de filas');
  end if;

  for v_key in select f ->> 'key' from jsonb_array_elements(p_filas) f loop
    if coalesce(trim(v_key), '') = '' then continue; end if;
    select exists(select 1 from public.siniestros where key = v_key) into v_existe;
    if v_existe then v_upd := v_upd + 1; else v_nuevos := v_nuevos + 1; end if;
  end loop;

  insert into public.siniestros as s (
    key, mes_reporte, placa, numero_interno, fecha, ruta, afiliado,
    conductor_cedula, conductor_codigo, conductor_nombre, conductor_celular, conductor_fecha_ingreso,
    gravedad, responsabilidad, tipo_conciliacion, tipo_lesion, monto, monto_texto, usuario_app,
    fotos, video, observaciones, coordenadas, reportado_en,
    tercero_placa, tercero_nombre, tercero_tipo_id, tercero_ciudad_cedula, tercero_cedula,
    tercero_telefono, tercero_telefono2, tercero_correo, tercero_aseguradora, tercero_danos, tercero_firma,
    lesiones, danos_empresa, firma_conductor, estado_inicio, usuario_logistica, categorizacion,
    autorizacion_datos, doc_cara1, doc_cara2, audio_conductor, audio_tercero, audio_asistente,
    lugar, observaciones_asistencia, estado, causa, norma, hipotesis, factor,
    correo_asistente, correo_afiliado, telefono_afiliado, datos_origen)
  select
    f ->> 'key', f ->> 'mes_reporte', f ->> 'placa', f ->> 'numero_interno',
    nullif(f ->> 'fecha', '')::date, f ->> 'ruta', f ->> 'afiliado',
    f ->> 'conductor_cedula', f ->> 'conductor_codigo', f ->> 'conductor_nombre', f ->> 'conductor_celular',
    nullif(f ->> 'conductor_fecha_ingreso', '')::date,
    f ->> 'gravedad', f ->> 'responsabilidad', f ->> 'tipo_conciliacion', f ->> 'tipo_lesion',
    nullif(f ->> 'monto', '')::numeric, f ->> 'monto_texto', f ->> 'usuario_app',
    coalesce(f -> 'fotos', '[]'::jsonb), f ->> 'video', f ->> 'observaciones', f ->> 'coordenadas',
    nullif(f ->> 'reportado_en', '')::timestamptz,
    f ->> 'tercero_placa', f ->> 'tercero_nombre', f ->> 'tercero_tipo_id', f ->> 'tercero_ciudad_cedula',
    f ->> 'tercero_cedula', f ->> 'tercero_telefono', f ->> 'tercero_telefono2', f ->> 'tercero_correo',
    f ->> 'tercero_aseguradora', f ->> 'tercero_danos', f ->> 'tercero_firma',
    f ->> 'lesiones', f ->> 'danos_empresa', f ->> 'firma_conductor', f ->> 'estado_inicio',
    f ->> 'usuario_logistica', f ->> 'categorizacion', f ->> 'autorizacion_datos',
    f ->> 'doc_cara1', f ->> 'doc_cara2', f ->> 'audio_conductor', f ->> 'audio_tercero', f ->> 'audio_asistente',
    f ->> 'lugar', f ->> 'observaciones_asistencia', f ->> 'estado', f ->> 'causa', f ->> 'norma',
    f ->> 'hipotesis', f ->> 'factor', f ->> 'correo_asistente', f ->> 'correo_afiliado', f ->> 'telefono_afiliado',
    f -> 'datos_origen'
  from jsonb_array_elements(p_filas) f
  where coalesce(trim(f ->> 'key'), '') <> ''
  on conflict (key) do update set
    mes_reporte = excluded.mes_reporte, placa = excluded.placa, numero_interno = excluded.numero_interno,
    fecha = excluded.fecha, ruta = excluded.ruta, afiliado = excluded.afiliado,
    conductor_cedula = excluded.conductor_cedula, conductor_codigo = excluded.conductor_codigo,
    conductor_nombre = excluded.conductor_nombre, conductor_celular = excluded.conductor_celular,
    conductor_fecha_ingreso = excluded.conductor_fecha_ingreso,
    gravedad = excluded.gravedad, responsabilidad = excluded.responsabilidad,
    tipo_conciliacion = excluded.tipo_conciliacion, tipo_lesion = excluded.tipo_lesion,
    monto = excluded.monto, monto_texto = excluded.monto_texto, usuario_app = excluded.usuario_app,
    fotos = excluded.fotos, video = excluded.video, observaciones = excluded.observaciones,
    coordenadas = excluded.coordenadas, reportado_en = excluded.reportado_en,
    tercero_placa = excluded.tercero_placa, tercero_nombre = excluded.tercero_nombre,
    tercero_tipo_id = excluded.tercero_tipo_id, tercero_ciudad_cedula = excluded.tercero_ciudad_cedula,
    tercero_cedula = excluded.tercero_cedula, tercero_telefono = excluded.tercero_telefono,
    tercero_telefono2 = excluded.tercero_telefono2, tercero_correo = excluded.tercero_correo,
    tercero_aseguradora = excluded.tercero_aseguradora, tercero_danos = excluded.tercero_danos,
    tercero_firma = excluded.tercero_firma, lesiones = excluded.lesiones,
    danos_empresa = excluded.danos_empresa, firma_conductor = excluded.firma_conductor,
    estado_inicio = excluded.estado_inicio, usuario_logistica = excluded.usuario_logistica,
    categorizacion = excluded.categorizacion, autorizacion_datos = excluded.autorizacion_datos,
    doc_cara1 = excluded.doc_cara1, doc_cara2 = excluded.doc_cara2,
    audio_conductor = excluded.audio_conductor, audio_tercero = excluded.audio_tercero,
    audio_asistente = excluded.audio_asistente, lugar = excluded.lugar,
    observaciones_asistencia = excluded.observaciones_asistencia, estado = excluded.estado,
    causa = excluded.causa, norma = excluded.norma, hipotesis = excluded.hipotesis, factor = excluded.factor,
    correo_asistente = excluded.correo_asistente, correo_afiliado = excluded.correo_afiliado,
    telefono_afiliado = excluded.telefono_afiliado, datos_origen = excluded.datos_origen,
    actualizado_en = now();

  update public.siniestros_fuente
     set ultima_carga = now(),
         ultimo_total = (select count(1) from public.siniestros),
         actualizado_en = now()
   where id = 1;

  return jsonb_build_object('ok', true, 'nuevos', v_nuevos, 'actualizados', v_upd,
                            'total', (select count(1) from public.siniestros));
end $$;
revoke all on function public.siniestros_cargar(jsonb) from public, anon;
grant execute on function public.siniestros_cargar(jsonb) to authenticated;

-- 3) Resumen rápido (para la pantalla y para saber cuándo se cargó por última vez) ------------
create or replace function public.siniestros_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'total', (select count(1) from public.siniestros),
      'desde', (select min(fecha) from public.siniestros),
      'hasta', (select max(fecha) from public.siniestros),
      'ultima_carga', (select ultima_carga from public.siniestros_fuente where id = 1),
      'url', (select url from public.siniestros_fuente where id = 1))
  end;
$$;
revoke all on function public.siniestros_estado() from public, anon;
grant execute on function public.siniestros_estado() to authenticated;
