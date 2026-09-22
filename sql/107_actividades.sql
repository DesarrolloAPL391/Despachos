-- ===================================================================================
-- 107: ACTIVIDADES Y ENTREGAS — a quién se le dio qué, y con qué respaldo.
-- ===================================================================================
-- QUÉ RESUELVE: Gestión Humana entrega cosas todo el año —entradas de Comfama, bonos,
-- dotación, regalos de fin de año, refrigerios— y el registro de a quién se le dio
-- vive en una hoja suelta, en un cuaderno o en el recuerdo de quien entregó. Cuando
-- alguien reclama que no le dieron, o cuando la caja de compensación pide el soporte
-- de a quién se le entregaron las entradas, no hay con qué responder.
--
-- CÓMO QUEDA: se crea la ACTIVIDAD ("Entrega de entradas Comfama, 12 de octubre") y a
-- medida que la gente llega se registra la ENTREGA: cédula, nombre, foto y firma. De
-- ahí sale la planilla firmada, que es lo que se archiva.
--
-- LAS TRES DECISIONES:
--   1. Solo se le entrega a PERSONAL DE LA EMPRESA. La cédula se busca en el perfil
--      sociodemográfico y de ahí salen nombre y cargo: nadie los escribe a mano, así
--      que no hay entregas a nombre de gente que no existe ni nombres mal escritos.
--   2. UNA ENTREGA POR PERSONA POR ACTIVIDAD. Es la regla que de verdad sirve: si
--      alguien vuelve a la fila, el sistema dice cuándo se le dio y quién se la dio.
--      Si fue un error, se anula con nota y puede volver a registrarse.
--   3. La FOTO y la FIRMA se piden o no según la actividad. Para unas entradas se
--      justifican las dos; para un refrigerio, ninguna.
--
-- QUIÉN ENTRA: Gestión Humana y administración (es_talento_humano), igual que el
-- perfil, los certificados y los disciplinarios.
-- ===================================================================================

-- ---------- 1) La actividad ----------
create table if not exists public.actividades (
  id            bigserial primary key,
  nombre        text not null,              -- "Entrega de entradas Comfama"
  descripcion   text,
  tipo          text not null default 'OTRO',
  fecha         date not null,              -- el día de la entrega
  lugar         text,
  pide_foto     boolean not null default true,
  pide_firma    boolean not null default true,
  cerrada_en    timestamptz,                -- cerrada = ya no se registran más entregas
  cerrada_por   text,
  creado_en     timestamptz not null default now(),
  creado_por    text,                       -- el correo de quien la creó
  creado_nombre text,
  actualizado_en timestamptz not null default now(),
  constraint actividades_tipo_check check (tipo in
    ('ENTRADA', 'REGALO', 'BONO', 'DOTACION', 'REFRIGERIO', 'CAPACITACION', 'OTRO'))
);
create index if not exists actividades_fecha_idx on public.actividades (fecha desc);

comment on table public.actividades is
  'Actividades de Gestion Humana en las que se entrega algo al personal. Las entregas van en actividad_entregas.';

-- ---------- 2) La entrega ----------
create table if not exists public.actividad_entregas (
  id            bigserial primary key,
  actividad_id  bigint not null references public.actividades(id) on delete cascade,
  cedula        text not null,
  nombre        text not null,              -- copiado del perfil al momento de entregar
  cargo         text,
  entregado_en  timestamptz not null default now(),
  foto_path     text,                       -- archivo en el bucket 'actividades'
  firma         text,                       -- firma en pantalla (PNG data URI)
  observacion   text,
  registrado_por text,                      -- el correo de quien la registró
  anulado_en    timestamptz,
  anulado_por   text,
  nota_anulacion text
);
create index if not exists act_entregas_act_idx on public.actividad_entregas (actividad_id, entregado_en desc);
create index if not exists act_entregas_ced_idx on public.actividad_entregas (cedula);

-- Una sola entrega por persona por actividad. El índice es PARCIAL: una entrega
-- anulada no bloquea, así que un registro equivocado se puede corregir.
create unique index if not exists act_entregas_una_por_persona
  on public.actividad_entregas (actividad_id, cedula) where anulado_en is null;

comment on table public.actividad_entregas is
  'A quien se le entrego, con foto y firma. Una por persona y actividad (indice parcial: las anuladas no cuentan).';

-- ---------- 3) Quién entra ----------
create or replace function public.es_actividades()
returns boolean language sql stable security definer set search_path to 'public'
as $$ select public.es_talento_humano(); $$;
revoke all on function public.es_actividades() from public, anon;
grant execute on function public.es_actividades() to authenticated;

alter table public.actividades enable row level security;
alter table public.actividad_entregas enable row level security;

drop policy if exists act_sel on public.actividades;
create policy act_sel on public.actividades for select to authenticated
  using ( (select public.es_actividades()) );

drop policy if exists act_ent_sel on public.actividad_entregas;
create policy act_ent_sel on public.actividad_entregas for select to authenticated
  using ( (select public.es_actividades()) );

-- Se escribe solo por las funciones de abajo.
revoke insert, update, delete on public.actividades from authenticated;
revoke insert, update, delete on public.actividad_entregas from authenticated;

-- ---------- 4) El bucket de las fotos ----------
-- Privado: las fotos son de personas identificadas. Se ven con URL firmada, nunca por link público.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('actividades', 'actividades', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists act_fotos_sel on storage.objects;
create policy act_fotos_sel on storage.objects for select to authenticated
  using (bucket_id = 'actividades' and public.es_actividades());
drop policy if exists act_fotos_ins on storage.objects;
create policy act_fotos_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'actividades' and public.es_actividades());
drop policy if exists act_fotos_del on storage.objects;
create policy act_fotos_del on storage.objects for delete to authenticated
  using (bucket_id = 'actividades' and public.es_actividades());

-- ---------- 5) El encabezado de la papelería ----------
-- Sale de lo que ya configuró el certificado laboral (sql/93 + sql/94): los datos de
-- la empresa en dos partes terminan contradiciéndose.
create or replace function public.actividades_papeleria()
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v jsonb; f jsonb;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  select jsonb_build_object('empresa', empresa_nombre, 'nit', empresa_nit,
                            'ciudad', ciudad, 'telefono', telefono)
    into v from public.certificado_config where id = 1;
  select jsonb_build_object('nombre', nombre, 'cargo', cargo, 'firma', firma, 'alto', firma_alto)
    into f from public.certificado_firmantes
   where rol = 'GESTION_HUMANA' and vigente_hasta is null
   order by vigente_desde desc limit 1;
  return jsonb_build_object('ok', true, 'empresa', coalesce(v, '{}'::jsonb),
                            'firmante', coalesce(f, '{}'::jsonb));
end $fn$;
revoke all on function public.actividades_papeleria() from public, anon;
grant execute on function public.actividades_papeleria() to authenticated;

-- ---------- 6) Crear o corregir la actividad ----------
create or replace function public.actividad_guardar(
  p_id bigint default null, p_nombre text default null, p_tipo text default null,
  p_fecha date default null, p_lugar text default null, p_descripcion text default null,
  p_pide_foto boolean default true, p_pide_firma boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text; v_nombre text; v_id bigint;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana crean actividades.');
  end if;
  if nullif(trim(coalesce(p_nombre, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el nombre de la actividad.');
  end if;
  if p_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'Falta la fecha de la actividad.');
  end if;

  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  select nombre into v_nombre from public.perfilsociodemografico
   where lower(coalesce(correo, '')) = lower(v_correo) limit 1;

  if p_id is null then
    insert into public.actividades (nombre, descripcion, tipo, fecha, lugar,
                                    pide_foto, pide_firma, creado_por, creado_nombre)
    values (trim(p_nombre), nullif(trim(coalesce(p_descripcion, '')), ''),
            coalesce(nullif(upper(trim(coalesce(p_tipo, ''))), ''), 'OTRO'),
            p_fecha, nullif(trim(coalesce(p_lugar, '')), ''),
            coalesce(p_pide_foto, true), coalesce(p_pide_firma, true), v_correo, v_nombre)
    returning id into v_id;
  else
    update public.actividades set
      nombre = trim(p_nombre),
      descripcion = nullif(trim(coalesce(p_descripcion, '')), ''),
      tipo = coalesce(nullif(upper(trim(coalesce(p_tipo, ''))), ''), tipo),
      fecha = p_fecha,
      lugar = nullif(trim(coalesce(p_lugar, '')), ''),
      pide_foto = coalesce(p_pide_foto, pide_foto),
      pide_firma = coalesce(p_pide_firma, pide_firma),
      actualizado_en = now()
    where id = p_id and cerrada_en is null
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error',
        'No se encontró esa actividad, o ya está cerrada.');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end $fn$;
revoke all on function public.actividad_guardar(bigint, text, text, date, text, text, boolean, boolean) from public, anon;
grant execute on function public.actividad_guardar(bigint, text, text, date, text, text, boolean, boolean) to authenticated;

create or replace function public.actividad_cerrar(p_id bigint, p_reabrir boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana cierran actividades.');
  end if;
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  if coalesce(p_reabrir, false) then
    update public.actividades set cerrada_en = null, cerrada_por = null, actualizado_en = now()
     where id = p_id and cerrada_en is not null;
    if not found then return jsonb_build_object('ok', false, 'error', 'Esa actividad no está cerrada.'); end if;
  else
    update public.actividades set cerrada_en = now(), cerrada_por = v_correo, actualizado_en = now()
     where id = p_id and cerrada_en is null;
    if not found then return jsonb_build_object('ok', false, 'error', 'Esa actividad ya estaba cerrada.'); end if;
  end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.actividad_cerrar(bigint, boolean) from public, anon;
grant execute on function public.actividad_cerrar(bigint, boolean) to authenticated;

-- ---------- 7) Buscar a quién se le va a entregar ----------
-- Se llama mientras se escribe la cédula: dice quién es y si ya recibió.
create or replace function public.actividad_buscar_persona(p_actividad bigint, p_cedula text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_ced text; p record; e record;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  v_ced := regexp_replace(coalesce(p_cedula, ''), '[^0-9]', '', 'g');
  if v_ced = '' then return jsonb_build_object('ok', false, 'error', 'Falta la cédula.'); end if;

  select cedula, nombre, cargo, estado into p
    from public.perfilsociodemografico where cedula = v_ced limit 1;
  if p.cedula is null then
    return jsonb_build_object('ok', false, 'error',
      'Esa cédula no está en el personal de la empresa.', 'cedula', v_ced);
  end if;

  -- ¿Ya recibió en esta actividad?
  select entregado_en, registrado_por into e
    from public.actividad_entregas
   where actividad_id = p_actividad and cedula = v_ced and anulado_en is null limit 1;

  return jsonb_build_object('ok', true, 'cedula', p.cedula, 'nombre', p.nombre,
    'cargo', p.cargo, 'estado', p.estado,
    'ya_recibio', (e.entregado_en is not null),
    'recibio_en', e.entregado_en, 'recibio_por', e.registrado_por);
end $fn$;
revoke all on function public.actividad_buscar_persona(bigint, text) from public, anon;
grant execute on function public.actividad_buscar_persona(bigint, text) to authenticated;

-- ---------- 8) Registrar la entrega ----------
create or replace function public.actividad_entregar(
  p_actividad bigint, p_cedula text, p_foto_path text default null,
  p_firma text default null, p_observacion text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare a public.actividades%rowtype; p record; e record; v_correo text; v_id bigint;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana registran entregas.');
  end if;
  select * into a from public.actividades where id = p_actividad;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe esa actividad.'); end if;
  if a.cerrada_en is not null then
    return jsonb_build_object('ok', false, 'error',
      'Esta actividad está cerrada: no se registran más entregas. Reábrela si falta alguien.');
  end if;

  select cedula, nombre, cargo into p
    from public.perfilsociodemografico
   where cedula = regexp_replace(coalesce(p_cedula, ''), '[^0-9]', '', 'g') limit 1;
  if p.cedula is null then
    return jsonb_build_object('ok', false, 'error', 'Esa cédula no está en el personal de la empresa.');
  end if;

  -- El control que hace útil todo esto: nadie reclama dos veces.
  select entregado_en, registrado_por into e
    from public.actividad_entregas
   where actividad_id = p_actividad and cedula = p.cedula and anulado_en is null limit 1;
  if e.entregado_en is not null then
    return jsonb_build_object('ok', false, 'error',
      'A ' || p.nombre || ' ya se le entregó el '
      || to_char(e.entregado_en at time zone 'America/Bogota', 'DD/MM/YYYY a las HH24:MI')
      || coalesce(' (lo registró ' || e.registrado_por || ')', '') || '.');
  end if;

  if a.pide_firma and nullif(p_firma, '') is null then
    return jsonb_build_object('ok', false, 'error', 'Esta actividad pide la firma de quien recibe.');
  end if;
  if a.pide_foto and nullif(trim(coalesce(p_foto_path, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Esta actividad pide la foto de quien recibe.');
  end if;

  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  insert into public.actividad_entregas
    (actividad_id, cedula, nombre, cargo, foto_path, firma, observacion, registrado_por)
  values (p_actividad, p.cedula, p.nombre, p.cargo,
          nullif(trim(coalesce(p_foto_path, '')), ''), nullif(p_firma, ''),
          nullif(trim(coalesce(p_observacion, '')), ''), v_correo)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'nombre', p.nombre, 'cargo', p.cargo);
end $fn$;
revoke all on function public.actividad_entregar(bigint, text, text, text, text) from public, anon;
grant execute on function public.actividad_entregar(bigint, text, text, text, text) to authenticated;

-- ---------- 9) Anular una entrega mal registrada ----------
-- No se borra: queda el rastro, y la persona puede volver a registrarse.
create or replace function public.actividad_entrega_anular(p_id bigint, p_nota text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana anulan una entrega.');
  end if;
  if nullif(trim(coalesce(p_nota, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se anula: queda en el registro.');
  end if;
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  update public.actividad_entregas
     set anulado_en = now(), anulado_por = v_correo, nota_anulacion = trim(p_nota)
   where id = p_id and anulado_en is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'Esa entrega no existe o ya estaba anulada.'); end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.actividad_entrega_anular(bigint, text) from public, anon;
grant execute on function public.actividad_entrega_anular(bigint, text) to authenticated;

-- ---------- 10) La lista de actividades, con cuántos han recibido ----------
create or replace function public.actividades_listar(p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v jsonb;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  select jsonb_agg(x order by (x->>'fecha') desc, (x->>'id')::bigint desc) into v from (
    select jsonb_build_object(
             'id', a.id, 'nombre', a.nombre, 'tipo', a.tipo, 'fecha', a.fecha,
             'lugar', a.lugar, 'descripcion', a.descripcion,
             'pide_foto', a.pide_foto, 'pide_firma', a.pide_firma,
             'cerrada_en', a.cerrada_en, 'creado_por', a.creado_por,
             'creado_nombre', a.creado_nombre, 'creado_en', a.creado_en,
             'entregas', (select count(*) from public.actividad_entregas e
                           where e.actividad_id = a.id and e.anulado_en is null)) as x
      from public.actividades a
     where (p_desde is null or a.fecha >= p_desde)
       and (p_hasta is null or a.fecha <= p_hasta)) t;
  return jsonb_build_object('ok', true, 'filas', coalesce(v, '[]'::jsonb),
                            'puede_editar', public.es_actividades());
end $fn$;
revoke all on function public.actividades_listar(date, date) from public, anon;
grant execute on function public.actividades_listar(date, date) to authenticated;

-- ---------- 11) Una actividad con todas sus entregas ----------
create or replace function public.actividad_detalle(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare a public.actividades%rowtype; v_ent jsonb; v_n int; v_anu int;
begin
  if not public.es_actividades() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  select * into a from public.actividades where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe esa actividad.'); end if;

  select jsonb_agg(to_jsonb(e) order by e.entregado_en desc) into v_ent
    from public.actividad_entregas e where e.actividad_id = p_id;

  select count(*) filter (where anulado_en is null),
         count(*) filter (where anulado_en is not null)
    into v_n, v_anu
    from public.actividad_entregas where actividad_id = p_id;

  return jsonb_build_object('ok', true,
    'actividad', to_jsonb(a),
    'entregas', coalesce(v_ent, '[]'::jsonb),
    'total', coalesce(v_n, 0), 'anuladas', coalesce(v_anu, 0),
    'puede_editar', public.es_actividades());
end $fn$;
revoke all on function public.actividad_detalle(bigint) from public, anon;
grant execute on function public.actividad_detalle(bigint) to authenticated;

-- ---------- 12) Estado del módulo (menú y novedades) ----------
create or replace function public.actividades_estado()
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_tot int; v_abiertas int; v_ent int; v_conf boolean;
begin
  if not public.es_actividades() then return jsonb_build_object('ok', false); end if;
  select count(*), count(*) filter (where cerrada_en is null) into v_tot, v_abiertas
    from public.actividades;
  select count(*) into v_ent from public.actividad_entregas where anulado_en is null;
  select exists (select 1 from public.certificado_config where id = 1) into v_conf;
  return jsonb_build_object('ok', true, 'total', coalesce(v_tot, 0),
    'abiertas', coalesce(v_abiertas, 0), 'entregas', coalesce(v_ent, 0),
    'papeleria', coalesce(v_conf, false));
end $fn$;
revoke all on function public.actividades_estado() from public, anon;
grant execute on function public.actividades_estado() to authenticated;
