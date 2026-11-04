-- =====================================================================================
-- 160 · Reclamaciones por daños a vehículos de terceros
-- =====================================================================================
-- Quien tuvo un accidente con un bus y reclama la indemnización hoy manda 11 documentos sueltos
-- al correo de contacto (el instructivo "REQUISITOS PARA RECLAMACIÓN" de seguridad vial). Aquí
-- lo radica por un link público (reclamacion.html) con una lista de chequeo: cada requisito
-- tiene su casilla, y lo que no tenga a la mano lo sube después con su radicado.
--
-- Cómo está armado:
--   * reclamacion_requisitos: los 11 requisitos del instructivo, partidos donde piden cosas
--     distintas (el 5 es licencia Y cédula de quien manejaba; el 6 son tres documentos; el 11
--     es el certificado y, a veces, un poder). `num` conserva la numeración del instructivo.
--   * _rcl_reglas(): UN solo lugar decide qué requisito aplica a cada caso (IPAT solo antes del
--     14/07/2022, fallo solo si hubo audiencia, poder solo si no reclama el propietario…). La
--     página pública repite estas reglas para pintar el formulario, pero la verdad es esta.
--   * Los archivos van en la base como los de permisos y PQRSF (base64, comprimidos en el
--     navegador). Se suben UNO POR UNO con un token que da el radicado (o la consulta): un
--     solo envío con 15 PDF no pasa.
--   * Todo lo escribe una RPC; las tablas son de solo lectura para seguridad vial y admin.
--
-- Recibir los documentos NO es aceptar responsabilidad: lo dice el instructivo y lo acepta el
-- reclamante en una casilla antes de enviar.
-- =====================================================================================

-- ---------- 1) Los requisitos ----------
create table if not exists public.reclamacion_requisitos (
  codigo        text primary key,
  num           int  not null,              -- numeración del instructivo (1 a 11)
  orden         int  not null,
  titulo        text not null,
  ayuda         text not null default '',
  max_archivos  int  not null default 3
);
alter table public.reclamacion_requisitos enable row level security;

insert into public.reclamacion_requisitos (codigo, num, orden, titulo, ayuda, max_archivos) values
  ('CARTA',          1, 10, 'Carta de reclamación',
     'Dirigida a Autobuses El Poblado Laureles S.A.: qué pides y tus datos de contacto (dirección, teléfonos y correo). Puedes usar el modelo que armamos con lo que escribiste.', 2),
  ('IPAT',           2, 20, 'IPAT o croquis del accidente',
     'Informe policial de accidente de tránsito, completo y legible. Es obligatorio si el accidente fue antes del 14 de julio de 2022 (Ley 2251 de 2022, art. 16, que modificó el art. 143 del CNT).', 3),
  ('FALLO',          3, 30, 'Fallo de la Secretaría de Movilidad',
     'Copia del fallo. Aplica si el caso tuvo audiencia contravencional.', 3),
  ('CC_PROPIETARIO', 4, 40, 'Cédula del propietario del vehículo',
     'Fotocopia legible, por las dos caras.', 3),
  ('LICENCIA',       5, 50, 'Licencia de conducción de quien manejaba',
     'De la persona que iba manejando tu vehículo el día y la hora del accidente.', 3),
  ('CC_CONDUCTOR',   5, 55, 'Cédula de quien manejaba',
     'Como quien manejaba no es el propietario, también va su documento de identidad, por las dos caras.', 3),
  ('TARJETA',        6, 60, 'Tarjeta de propiedad del vehículo',
     'Fotocopia legible, por las dos caras.', 3),
  ('SOAT',           6, 62, 'SOAT vigente el día del accidente',
     'El que estaba vigente en la fecha del accidente.', 2),
  ('RTM',            6, 64, 'Revisión técnico-mecánica',
     'Si aplica: la que estaba vigente en la fecha del accidente.', 2),
  ('PODER',          7, 70, 'Poder autenticado del propietario',
     'Como quien reclama no es el propietario, el propietario autoriza en notaría a esa persona para adelantar la reclamación.', 3),
  ('PRUEBAS',        8, 80, 'Fotos o videos de los daños',
     'Lo que muestre los daños de tu vehículo y ayude a aclarar cómo pasó (art. 143, Ley 2251 de 2022).', 10),
  ('NO_RECLAMACION', 9, 90, 'Certificación de no reclamación',
     'La aseguradora de tu vehículo certifica que no reclamaste ante ella por este accidente.', 3),
  ('FACTURA',       10, 100, 'Factura o cotización de la reparación',
     'Factura de un taller legal si ya lo reparaste; si no, cotización detallada de mano de obra y repuestos.', 4),
  ('CERT_BANCARIO', 11, 110, 'Certificado bancario',
     'De la cuenta donde se haría el pago: del propietario o de la persona autorizada para recibirlo.', 2),
  ('PODER_BENEF',   11, 115, 'Poder autenticado para quien recibe el pago',
     'Como la cuenta es de otra persona, va el poder autenticado que la autoriza a recibir la indemnización.', 3)
on conflict (codigo) do update
  set num = excluded.num, orden = excluded.orden, titulo = excluded.titulo,
      ayuda = excluded.ayuda, max_archivos = excluded.max_archivos;

-- ---------- 2) La reclamación ----------
create sequence if not exists public.reclamacion_seq as bigint start 1;

create table if not exists public.reclamaciones (
  id                  bigint generated always as identity primary key,
  radicado            text not null unique,
  estado              text not null default 'RECIBIDA'
                      check (estado in ('RECIBIDA', 'INCOMPLETA', 'EN ESTUDIO', 'APROBADA', 'NEGADA', 'PAGADA', 'ANULADA')),
  observacion_publica text,                 -- lo que ve el reclamante al consultar
  -- El accidente
  fecha_siniestro     date not null,
  hora_siniestro      time,
  lugar               text,
  bus                 text,                 -- número interno, si lo sabe
  bus_placa           text,                 -- placa del bus (la escrita o la del parque)
  placa_afectada      text not null,        -- la de SU vehículo, sin espacios ni guiones
  relato              text not null,
  audiencia           text not null check (audiencia in ('SI', 'NO', 'NO_SE')),
  -- Quién reclama
  es_propietario      boolean not null,
  reclamante_nombre   text not null,
  reclamante_doc      text not null,
  reclamante_direccion text not null,
  reclamante_telefono text not null,
  reclamante_correo   text,
  propietario_nombre  text,
  propietario_doc     text,
  conductor_es_propietario boolean not null,
  conductor_nombre    text,
  -- Qué pide
  pretensiones        text not null,
  valor_estimado      numeric,
  reparado            boolean not null,
  tiene_seguro        boolean not null,
  aseguradora         text,
  cuenta_de           text not null check (cuenta_de in ('PROPIETARIO', 'RECLAMANTE', 'OTRA')),
  acepta_terminos     boolean not null,
  acepta_datos        boolean not null,
  -- Control
  siniestro_key       text,                 -- el siniestro de la app que seguridad vial le asocia
  token_subida        uuid,
  token_vence         timestamptz,
  ip_origen           text,
  agente              text,
  creado_en           timestamptz not null default now(),
  actualizado_en      timestamptz not null default now()
);
create index if not exists reclamaciones_estado_idx on public.reclamaciones (estado, creado_en desc);
create index if not exists reclamaciones_token_idx on public.reclamaciones (token_subida);
alter table public.reclamaciones enable row level security;

create table if not exists public.reclamacion_docs (
  id              bigint generated always as identity primary key,
  reclamacion_id  bigint not null references public.reclamaciones(id) on delete cascade,
  requisito       text   not null references public.reclamacion_requisitos(codigo),
  nombre          text,
  tipo_mime       text,
  archivo         text   not null,          -- data:...;base64,...
  bytes           int,
  estado          text   not null default 'RECIBIDO' check (estado in ('RECIBIDO', 'ACEPTADO', 'RECHAZADO')),
  motivo_rechazo  text,
  subido_por      text   not null default 'RECLAMANTE',
  revisado_por    text,
  revisado_en     timestamptz,
  creado_en       timestamptz not null default now()
);
create index if not exists reclamacion_docs_rec_idx on public.reclamacion_docs (reclamacion_id, requisito);
alter table public.reclamacion_docs enable row level security;

create table if not exists public.reclamacion_gestion (
  id              bigint generated always as identity primary key,
  reclamacion_id  bigint not null references public.reclamaciones(id) on delete cascade,
  accion          text   not null,          -- RADICADA, DOCUMENTO, REVISION, ESTADO, NOTA, SINIESTRO
  estado          text,
  texto           text,
  publica         boolean not null default false,
  usuario         text,
  creado_en       timestamptz not null default now()
);
create index if not exists reclamacion_gestion_rec_idx on public.reclamacion_gestion (reclamacion_id, id desc);
alter table public.reclamacion_gestion enable row level security;

-- Solo lectura para seguridad vial (y admin, que ya está dentro de es_seguridad_vial()).
drop policy if exists rcl_req_sel on public.reclamacion_requisitos;
create policy rcl_req_sel on public.reclamacion_requisitos for select to authenticated
  using ((select public.es_seguridad_vial()));
drop policy if exists rcl_sel on public.reclamaciones;
create policy rcl_sel on public.reclamaciones for select to authenticated
  using ((select public.es_seguridad_vial()));
drop policy if exists rcl_docs_sel on public.reclamacion_docs;
create policy rcl_docs_sel on public.reclamacion_docs for select to authenticated
  using ((select public.es_seguridad_vial()));
drop policy if exists rcl_gest_sel on public.reclamacion_gestion;
create policy rcl_gest_sel on public.reclamacion_gestion for select to authenticated
  using ((select public.es_seguridad_vial()));
revoke all on public.reclamacion_requisitos, public.reclamaciones, public.reclamacion_docs,
              public.reclamacion_gestion from anon;

-- ---------- 3) Las reglas: qué aplica a cada caso ----------
create or replace function public._rcl_reglas(r public.reclamaciones)
returns table (codigo text, num int, orden int, titulo text, ayuda text, max_archivos int, aplica text)
language sql stable security definer set search_path = public as $fn$
  select q.codigo, q.num, q.orden,
         case q.codigo
           when 'NO_RECLAMACION' then case when r.tiene_seguro
             then 'Certificación de no reclamación de tu aseguradora'
             else 'Declaración extrajuicio (no tienes aseguradora)' end
           when 'FACTURA' then case when r.reparado
             then 'Factura del taller que hizo la reparación'
             else 'Cotización detallada de la reparación' end
           else q.titulo end,
         case q.codigo
           when 'NO_RECLAMACION' then case when r.tiene_seguro
             then q.ayuda
             else 'Como tu vehículo no tiene aseguradora, va una declaración extrajuicio (se hace en notaría).' end
           when 'FACTURA' then case when r.reparado
             then 'De un taller legal, con el detalle de lo que se reparó.'
             else 'De mano de obra y repuestos, con el detalle de cada cosa.' end
           else q.ayuda end,
         q.max_archivos,
         case q.codigo
           when 'IPAT'         then case when r.fecha_siniestro < date '2022-07-14' then 'OBLIGATORIO' else 'OPCIONAL' end
           when 'FALLO'        then case r.audiencia when 'SI' then 'OBLIGATORIO' when 'NO_SE' then 'OPCIONAL' else 'NO_APLICA' end
           when 'CC_CONDUCTOR' then case when r.conductor_es_propietario then 'NO_APLICA' else 'OBLIGATORIO' end
           when 'PODER'        then case when r.es_propietario then 'NO_APLICA' else 'OBLIGATORIO' end
           when 'PODER_BENEF'  then case when r.cuenta_de = 'OTRA' then 'OBLIGATORIO' else 'NO_APLICA' end
           when 'RTM'          then 'OPCIONAL'
           else 'OBLIGATORIO' end
    from public.reclamacion_requisitos q
   order by q.orden;
$fn$;
revoke all on function public._rcl_reglas(public.reclamaciones) from public, anon, authenticated;

-- La lista de chequeo de una reclamación: cada requisito con su estado y sus archivos.
-- p_interno = true trae el id de cada archivo (para abrirlo y revisarlo); el reclamante no.
create or replace function public._rcl_checklist(p_id bigint, p_interno boolean default false)
returns jsonb
language sql stable security definer set search_path = public as $fn$
  with q as (
    select g.* from public.reclamaciones rr cross join lateral public._rcl_reglas(rr) g where rr.id = p_id
  ), d as (
    select x.requisito,
           jsonb_agg(jsonb_build_object('id', x.id, 'nombre', x.nombre, 'tipo_mime', x.tipo_mime, 'bytes', x.bytes,
                                        'estado', x.estado, 'motivo', x.motivo_rechazo, 'subido_por', x.subido_por,
                                        'revisado_por', x.revisado_por, 'creado_en', x.creado_en) order by x.id) as docs_int,
           jsonb_agg(jsonb_build_object('nombre', x.nombre, 'estado', x.estado, 'motivo', x.motivo_rechazo) order by x.id) as docs_pub,
           count(*) filter (where x.estado <> 'RECHAZADO') as vivos,
           count(*) filter (where x.estado = 'ACEPTADO')   as ok,
           count(*) filter (where x.estado = 'RECHAZADO')  as mal
      from public.reclamacion_docs x where x.reclamacion_id = p_id group by x.requisito
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'codigo', q.codigo, 'num', q.num, 'titulo', q.titulo, 'ayuda', q.ayuda, 'max', q.max_archivos,
           'aplica', q.aplica,
           'estado', case
             when coalesce(d.vivos, 0) = 0 then case
               when coalesce(d.mal, 0) > 0       then 'RECHAZADO'
               when q.aplica = 'OBLIGATORIO'     then 'FALTA'
               when q.aplica = 'OPCIONAL'        then 'OPCIONAL'
               else 'NO_APLICA' end
             when d.ok = d.vivos then 'ACEPTADO'
             else 'RECIBIDO' end,
           'docs', coalesce(case when p_interno then d.docs_int else d.docs_pub end, '[]'::jsonb)
         ) order by q.orden), '[]'::jsonb)
    from q left join d on d.requisito = q.codigo;
$fn$;
revoke all on function public._rcl_checklist(bigint, boolean) from public, anon, authenticated;

-- Cuántos obligatorios hay, cuántos ya están y cuántos faltan (o se rechazaron).
create or replace function public._rcl_conteo(c jsonb)
returns jsonb language sql immutable as $fn$
  select jsonb_build_object(
    'obligatorios', count(*) filter (where e->>'aplica' = 'OBLIGATORIO'),
    'listos',       count(*) filter (where e->>'aplica' = 'OBLIGATORIO' and e->>'estado' in ('RECIBIDO', 'ACEPTADO')),
    'faltan',       count(*) filter (where e->>'aplica' = 'OBLIGATORIO' and e->>'estado' in ('FALTA', 'RECHAZADO')),
    'rechazados',   count(*) filter (where e->>'estado' = 'RECHAZADO'),
    'por_revisar',  count(*) filter (where e->>'estado' = 'RECIBIDO'))
  from jsonb_array_elements(coalesce(c, '[]'::jsonb)) e;
$fn$;
revoke all on function public._rcl_conteo(jsonb) from public, anon, authenticated;

-- ---------- 4) Lo que usa la página pública (sin sesión) ----------
-- La página trae su propia copia de los requisitos (para pintar el formulario sin pedir nada);
-- si se cambia un texto aquí, cambiarlo también en REQUISITOS de reclamacion.html.
create or replace function public.reclamacion_radicar(p_datos jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_hoy   date := (now() at time zone 'America/Bogota')::date;
  v_fs    date;
  v_hs    time;
  v_pla   text := regexp_replace(upper(coalesce(p_datos->>'placa_afectada', '')), '[^A-Z0-9]', '', 'g');
  v_bus   text := regexp_replace(coalesce(p_datos->>'bus', ''), '\D', '', 'g');
  v_bpla  text := regexp_replace(upper(coalesce(p_datos->>'bus_placa', '')), '[^A-Z0-9]', '', 'g');
  v_rel   text := btrim(coalesce(p_datos->>'relato', ''));
  v_aud   text := upper(btrim(coalesce(p_datos->>'audiencia', '')));
  v_prop  boolean := coalesce((p_datos->>'es_propietario')::boolean, true);
  v_nom   text := btrim(coalesce(p_datos->>'reclamante_nombre', ''));
  v_doc   text := regexp_replace(coalesce(p_datos->>'reclamante_doc', ''), '[^0-9A-Za-z]', '', 'g');
  v_dir   text := btrim(coalesce(p_datos->>'reclamante_direccion', ''));
  v_tel   text := regexp_replace(coalesce(p_datos->>'reclamante_telefono', ''), '\D', '', 'g');
  v_cor   text := lower(btrim(coalesce(p_datos->>'reclamante_correo', '')));
  v_pnom  text := btrim(coalesce(p_datos->>'propietario_nombre', ''));
  v_pdoc  text := regexp_replace(coalesce(p_datos->>'propietario_doc', ''), '[^0-9A-Za-z]', '', 'g');
  v_cprop boolean := coalesce((p_datos->>'conductor_es_propietario')::boolean, true);
  v_cnom  text := btrim(coalesce(p_datos->>'conductor_nombre', ''));
  v_pret  text := btrim(coalesce(p_datos->>'pretensiones', ''));
  v_val   numeric;
  v_rep   boolean := coalesce((p_datos->>'reparado')::boolean, false);
  v_seg   boolean := coalesce((p_datos->>'tiene_seguro')::boolean, false);
  v_aseg  text := btrim(coalesce(p_datos->>'aseguradora', ''));
  v_cta   text := upper(btrim(coalesce(p_datos->>'cuenta_de', 'PROPIETARIO')));
  v_ip    text;
  v_n     int;
  v_id    bigint;
  v_rad   text;
  v_tok   uuid := gen_random_uuid();
  v_chk   jsonb;
begin
  -- Trampa para robots: se contesta como si nada y no se guarda.
  if coalesce(btrim(p_datos->>'trampa'), '') <> '' then
    return jsonb_build_object('ok', true, 'radicado', 'RCL-0000-0000');
  end if;

  begin v_fs := nullif(p_datos->>'fecha_siniestro', '')::date; exception when others then v_fs := null; end;
  begin v_hs := nullif(p_datos->>'hora_siniestro', '')::time; exception when others then v_hs := null; end;
  begin v_val := nullif(regexp_replace(coalesce(p_datos->>'valor_estimado', ''), '[^0-9]', '', 'g'), '')::numeric;
  exception when others then v_val := null; end;

  if v_fs is null then return jsonb_build_object('ok', false, 'error', '¿Qué día fue el accidente?'); end if;
  if v_fs > v_hoy then return jsonb_build_object('ok', false, 'error', 'La fecha del accidente no puede ser futura.'); end if;
  if v_fs < date '2000-01-01' then return jsonb_build_object('ok', false, 'error', 'Revisa la fecha del accidente.'); end if;
  if length(v_pla) not between 4 and 8 then
    return jsonb_build_object('ok', false, 'error', 'Escribe la placa de tu vehículo (ej: ABC123).');
  end if;
  if length(v_bus) not between 3 and 5 and length(v_bpla) not between 5 and 7 then
    return jsonb_build_object('ok', false, 'error', 'Necesitamos el número del bus (4 dígitos grandes en el frente y los costados) o su placa.');
  end if;
  if length(v_rel) < 20 then
    return jsonb_build_object('ok', false, 'error', 'Cuéntanos cómo fue el accidente con un poco más de detalle: al menos 20 letras.');
  end if;
  if length(v_rel) > 4000 or length(v_pret) > 4000 then
    return jsonb_build_object('ok', false, 'error', 'El texto quedó muy largo. Resúmelo en menos de 4.000 letras.');
  end if;
  if v_aud not in ('SI', 'NO', 'NO_SE') then v_aud := 'NO_SE'; end if;
  if length(v_nom) < 5 then return jsonb_build_object('ok', false, 'error', 'Escribe tu nombre completo.'); end if;
  if length(v_doc) not between 5 and 15 then return jsonb_build_object('ok', false, 'error', 'Escribe tu número de cédula o NIT.'); end if;
  if length(v_dir) < 5 then return jsonb_build_object('ok', false, 'error', 'Escribe tu dirección.'); end if;
  if length(v_tel) not between 7 and 12 then return jsonb_build_object('ok', false, 'error', 'Escribe un teléfono o celular de contacto.'); end if;
  if v_cor <> '' and v_cor !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then
    return jsonb_build_object('ok', false, 'error', 'Revisa el correo: parece que está mal escrito.');
  end if;
  if not v_prop and length(v_pnom) < 5 then
    return jsonb_build_object('ok', false, 'error', 'Escribe el nombre del propietario del vehículo.');
  end if;
  if length(v_pret) < 10 then
    return jsonb_build_object('ok', false, 'error', 'Cuéntanos qué pides: por ejemplo, que se te pague la reparación del vehículo.');
  end if;
  if v_val is not null and (v_val < 0 or v_val > 10000000000) then v_val := null; end if;
  if v_cta not in ('PROPIETARIO', 'RECLAMANTE', 'OTRA') then v_cta := 'PROPIETARIO'; end if;
  if v_prop and v_cta = 'RECLAMANTE' then v_cta := 'PROPIETARIO'; end if;  -- son la misma persona
  if not coalesce((p_datos->>'acepta_terminos')::boolean, false) or not coalesce((p_datos->>'acepta_datos')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'Para enviarla tienes que marcar las dos casillas del final.');
  end if;

  -- Frenos de abuso: no son una muralla, evitan el goteo de un formulario abierto.
  begin
    v_ip := split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := null;
  end;
  select count(1) into v_n from public.reclamaciones
   where creado_en > now() - interval '1 day'
     and (reclamante_telefono = v_tel or (v_cor <> '' and reclamante_correo = v_cor));
  if v_n >= 3 then
    return jsonb_build_object('ok', false, 'error',
      'Ya radicaste varias reclamaciones hoy con esos datos. Si te falta un documento, entra a "Consultar o completar la mía".');
  end if;
  if coalesce(v_ip, '') <> '' then
    select count(1) into v_n from public.reclamaciones where ip_origen = v_ip and creado_en > now() - interval '1 hour';
    if v_n >= 5 then
      return jsonb_build_object('ok', false, 'error', 'Demasiadas solicitudes seguidas. Intenta de nuevo en un rato.');
    end if;
  end if;

  -- El bus se resuelve contra el parque: con el número, la placa sale sola.
  if length(v_bus) between 3 and 5 and length(v_bpla) not between 5 and 7 then
    select regexp_replace(upper(v.placa), '[^A-Z0-9]', '', 'g') into v_bpla
      from public.vehiculos v where btrim(v.numero) = v_bus limit 1;
  end if;

  v_rad := 'RCL-' || to_char(v_hoy, 'YYYY') || '-' || lpad(nextval('public.reclamacion_seq')::text, 4, '0');

  insert into public.reclamaciones (
    radicado, fecha_siniestro, hora_siniestro, lugar, bus, bus_placa, placa_afectada, relato, audiencia,
    es_propietario, reclamante_nombre, reclamante_doc, reclamante_direccion, reclamante_telefono, reclamante_correo,
    propietario_nombre, propietario_doc, conductor_es_propietario, conductor_nombre,
    pretensiones, valor_estimado, reparado, tiene_seguro, aseguradora, cuenta_de,
    acepta_terminos, acepta_datos, token_subida, token_vence, ip_origen, agente)
  values (
    v_rad, v_fs, v_hs, nullif(left(btrim(coalesce(p_datos->>'lugar', '')), 200), ''),
    nullif(v_bus, ''), nullif(v_bpla, ''), v_pla, v_rel, v_aud,
    v_prop, left(v_nom, 120), v_doc, left(v_dir, 200), v_tel, nullif(v_cor, ''),
    case when v_prop then null else left(v_pnom, 120) end, case when v_prop then null else nullif(v_pdoc, '') end,
    v_cprop, case when v_cprop then null else nullif(left(v_cnom, 120), '') end,
    v_pret, v_val, v_rep, v_seg, case when v_seg then nullif(left(v_aseg, 120), '') end, v_cta,
    true, true, v_tok, now() + interval '6 hours', nullif(v_ip, ''), left(coalesce(p_datos->>'agente', ''), 200))
  returning id into v_id;

  insert into public.reclamacion_gestion (reclamacion_id, accion, estado, texto, usuario)
  values (v_id, 'RADICADA', 'RECIBIDA', 'Radicada por el reclamante en el formulario público.', 'reclamante');

  v_chk := public._rcl_checklist(v_id, false);
  return jsonb_build_object('ok', true, 'radicado', v_rad, 'token', v_tok,
                            'checklist', v_chk, 'conteo', public._rcl_conteo(v_chk));
end $fn$;
revoke all on function public.reclamacion_radicar(jsonb) from public;
grant execute on function public.reclamacion_radicar(jsonb) to anon, authenticated;

-- Un archivo a la vez, con el token que entregó el radicado o la consulta.
create or replace function public.reclamacion_subir(p_token uuid, p_requisito text, p_doc jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  r       public.reclamaciones;
  q       record;
  v_arch  text := coalesce(p_doc->>'archivo', '');
  v_mime  text;
  v_n     int;
  v_tot   int;
  v_id    bigint;
begin
  if p_token is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el permiso para subir. Vuelve a entrar con tu radicado.', 'vencido', true);
  end if;
  select * into r from public.reclamaciones where token_subida = p_token and token_vence > now();
  if r.id is null then
    return jsonb_build_object('ok', false, 'vencido', true,
      'error', 'Pasó mucho tiempo y el permiso para subir venció. Entra a "Consultar o completar la mía" con tu radicado y sigue desde ahí.');
  end if;
  if r.estado in ('APROBADA', 'NEGADA', 'PAGADA', 'ANULADA') then
    return jsonb_build_object('ok', false, 'error', 'Esta reclamación ya fue resuelta y no recibe más documentos.');
  end if;
  select g.* into q from public._rcl_reglas(r) g where g.codigo = upper(btrim(coalesce(p_requisito, '')));
  if q.codigo is null then return jsonb_build_object('ok', false, 'error', 'No reconocemos ese documento.'); end if;
  if q.aplica = 'NO_APLICA' then return jsonb_build_object('ok', false, 'error', 'Ese documento no aplica para tu caso.'); end if;
  if length(v_arch) < 100 or length(v_arch) > 6000000 then
    return jsonb_build_object('ok', false, 'error', 'El archivo está vacío o pesa demasiado (máximo unos 4 MB). Si es un PDF escaneado, escanéalo con menos calidad.');
  end if;
  v_mime := lower(substring(v_arch from '^data:([a-zA-Z0-9.+/-]+);base64,'));
  if v_mime is null or not (v_mime ~ '^image/' or v_mime = 'application/pdf' or v_mime ~ '^video/') then
    return jsonb_build_object('ok', false, 'error', 'Solo se reciben fotos, PDF o videos cortos.');
  end if;
  if v_mime ~ '^video/' and q.codigo <> 'PRUEBAS' then
    return jsonb_build_object('ok', false, 'error', 'Los videos solo van en las pruebas de los daños.');
  end if;
  select count(*) filter (where requisito = q.codigo and estado <> 'RECHAZADO'), count(*)
    into v_n, v_tot from public.reclamacion_docs where reclamacion_id = r.id;
  if v_n >= q.max_archivos then
    return jsonb_build_object('ok', false, 'error', format('Para "%s" se reciben máximo %s archivos.', q.titulo, q.max_archivos));
  end if;
  if v_tot >= 60 then
    return jsonb_build_object('ok', false, 'error', 'Esta reclamación ya tiene demasiados archivos. Si falta algo, comunícate con nosotros.');
  end if;

  insert into public.reclamacion_docs (reclamacion_id, requisito, nombre, tipo_mime, archivo, bytes)
  values (r.id, q.codigo, left(coalesce(nullif(btrim(p_doc->>'nombre'), ''), 'documento'), 120), v_mime, v_arch, length(v_arch))
  returning id into v_id;
  update public.reclamaciones set actualizado_en = now() where id = r.id;
  -- Lo que llega con el radicado no se anota uno por uno; lo que completa después, sí.
  if now() - r.creado_en > interval '30 minutes' then
    insert into public.reclamacion_gestion (reclamacion_id, accion, texto, usuario)
    values (r.id, 'DOCUMENTO', 'El reclamante subió: ' || q.titulo, 'reclamante');
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $fn$;
revoke all on function public.reclamacion_subir(uuid, text, jsonb) from public;
grant execute on function public.reclamacion_subir(uuid, text, jsonb) to anon, authenticated;

-- Consultar y completar: con el radicado Y el correo o el teléfono que dejó.
create or replace function public.reclamacion_consultar(p_radicado text, p_contacto text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_rad text := upper(btrim(coalesce(p_radicado, '')));
  v_c   text := lower(btrim(coalesce(p_contacto, '')));
  v_tel text := regexp_replace(coalesce(p_contacto, ''), '\D', '', 'g');
  r     public.reclamaciones;
  v_tok uuid;
  v_chk jsonb;
  v_abierta boolean;
begin
  if v_rad = '' or v_c = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu número de radicado y el correo o teléfono que dejaste.');
  end if;
  select * into r from public.reclamaciones x
   where upper(x.radicado) = v_rad
     and ( (x.reclamante_correo is not null and x.reclamante_correo = v_c)
        or (length(v_tel) >= 7 and x.reclamante_telefono = v_tel) )
   limit 1;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error',
      'No encontramos esa reclamación con ese dato de contacto. Revisa el radicado tal como te lo dimos (RCL-…).');
  end if;
  v_abierta := r.estado in ('RECIBIDA', 'INCOMPLETA', 'EN ESTUDIO');
  -- Si todavía tiene un permiso vigente (p. ej. está subiendo en otra pestaña) se reutiliza.
  if v_abierta then
    if r.token_subida is not null and r.token_vence > now() + interval '30 minutes' then
      v_tok := r.token_subida;
    else
      v_tok := gen_random_uuid();
      update public.reclamaciones set token_subida = v_tok, token_vence = now() + interval '3 hours' where id = r.id;
    end if;
  end if;
  v_chk := public._rcl_checklist(r.id, false);
  return jsonb_build_object('ok', true,
    'radicado', r.radicado, 'estado', r.estado, 'radicada_el', (r.creado_en at time zone 'America/Bogota')::date,
    'observacion', r.observacion_publica, 'fecha_siniestro', r.fecha_siniestro, 'placa', r.placa_afectada,
    'abierta', v_abierta, 'token', v_tok, 'checklist', v_chk, 'conteo', public._rcl_conteo(v_chk));
end $fn$;
revoke all on function public.reclamacion_consultar(text, text) from public;
grant execute on function public.reclamacion_consultar(text, text) to anon, authenticated;

-- ---------- 5) La gestión (seguridad vial y admin) ----------
create or replace function public.reclamacion_lista()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso.');
  end if;
  return jsonb_build_object('ok', true, 'filas', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', x.id, 'radicado', x.radicado, 'estado', x.estado, 'creado_en', x.creado_en,
             'actualizado_en', x.actualizado_en, 'fecha_siniestro', x.fecha_siniestro,
             'placa_afectada', x.placa_afectada, 'bus', x.bus, 'bus_placa', x.bus_placa,
             'reclamante_nombre', x.reclamante_nombre, 'es_propietario', x.es_propietario,
             'valor_estimado', x.valor_estimado, 'siniestro_key', x.siniestro_key,
             'conteo', public._rcl_conteo(public._rcl_checklist(x.id, false)))
           order by x.creado_en desc)
      from public.reclamaciones x), '[]'::jsonb));
end $fn$;
revoke all on function public.reclamacion_lista() from public, anon;
grant execute on function public.reclamacion_lista() to authenticated;

-- Para el contador del menú: nuevas sin revisar, o con documentos que llegaron y nadie ha visto.
create or replace function public.reclamacion_pendientes_n()
returns int
language sql stable security definer set search_path = public as $fn$
  select case when not public.es_seguridad_vial() then 0 else (
    select count(*)::int from public.reclamaciones x
     where x.estado = 'RECIBIDA'
        or (x.estado in ('INCOMPLETA', 'EN ESTUDIO')
            and exists (select 1 from public.reclamacion_docs d where d.reclamacion_id = x.id and d.estado = 'RECIBIDO'))
  ) end;
$fn$;
revoke all on function public.reclamacion_pendientes_n() from public, anon;
grant execute on function public.reclamacion_pendientes_n() to authenticated;

create or replace function public.reclamacion_ficha(p_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  r     public.reclamaciones;
  v_chk jsonb;
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso.');
  end if;
  select * into r from public.reclamaciones where id = p_id;
  if r.id is null then return jsonb_build_object('ok', false, 'error', 'No existe esa reclamación.'); end if;
  v_chk := public._rcl_checklist(r.id, true);
  return jsonb_build_object('ok', true,
    'reclamacion', to_jsonb(r) - 'token_subida' - 'token_vence' - 'ip_origen' - 'agente',
    'checklist', v_chk, 'conteo', public._rcl_conteo(v_chk),
    'gestion', coalesce((select jsonb_agg(to_jsonb(g) - 'reclamacion_id' order by g.id desc)
                           from public.reclamacion_gestion g where g.reclamacion_id = r.id), '[]'::jsonb),
    -- Los siniestros que reportó la app y pueden ser este: por la placa del tercero, o por el
    -- bus con dos días de margen (la fecha que recuerda el reclamante no siempre es exacta).
    'siniestros', coalesce((
      select jsonb_agg(z order by z.por_placa desc, z.dias) from (
        select s.key, s.fecha, s.numero_interno, s.placa, s.tercero_placa, s.tercero_nombre, s.tercero_aseguradora,
               s.gravedad, s.responsabilidad, s.tipo_conciliacion, s.monto, s.estado, s.lugar,
               (regexp_replace(upper(coalesce(s.tercero_placa, '')), '[^A-Z0-9]', '', 'g') = r.placa_afectada) as por_placa,
               abs(s.fecha - r.fecha_siniestro) as dias,
               (s.key = r.siniestro_key) as vinculado
          from public.siniestros s
         where s.key = r.siniestro_key
            or regexp_replace(upper(coalesce(s.tercero_placa, '')), '[^A-Z0-9]', '', 'g') = r.placa_afectada
            or (s.fecha between r.fecha_siniestro - 2 and r.fecha_siniestro + 2
                and ( (r.bus is not null and btrim(coalesce(s.numero_interno, '')) = r.bus)
                   or (r.bus_placa is not null and regexp_replace(upper(coalesce(s.placa, '')), '[^A-Z0-9]', '', 'g') = r.bus_placa)))
         order by (s.key = r.siniestro_key) desc,
                  (regexp_replace(upper(coalesce(s.tercero_placa, '')), '[^A-Z0-9]', '', 'g') = r.placa_afectada) desc,
                  abs(s.fecha - r.fecha_siniestro)
         limit 10) z), '[]'::jsonb));
end $fn$;
revoke all on function public.reclamacion_ficha(bigint) from public, anon;
grant execute on function public.reclamacion_ficha(bigint) to authenticated;

-- Cambiar el estado y/o dejar una nota. Si es pública, es lo que lee el reclamante al consultar.
create or replace function public.reclamacion_gestionar(p_id bigint, p_estado text, p_texto text, p_publica boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_est text := nullif(upper(btrim(coalesce(p_estado, ''))), '');
  v_txt text := nullif(btrim(coalesce(p_texto, '')), '');
  v_ant text;
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial gestiona las reclamaciones.');
  end if;
  select estado into v_ant from public.reclamaciones where id = p_id;
  if v_ant is null then return jsonb_build_object('ok', false, 'error', 'No existe esa reclamación.'); end if;
  if v_est is not null and v_est not in ('RECIBIDA', 'INCOMPLETA', 'EN ESTUDIO', 'APROBADA', 'NEGADA', 'PAGADA', 'ANULADA') then
    return jsonb_build_object('ok', false, 'error', 'Estado no válido.');
  end if;
  if v_est is null and v_txt is null then
    return jsonb_build_object('ok', false, 'error', 'No hay nada que guardar.');
  end if;
  if v_est in ('INCOMPLETA', 'NEGADA') and v_txt is null then
    return jsonb_build_object('ok', false, 'error', 'Para ese estado escribe qué le dices al reclamante: qué falta o por qué no procede.');
  end if;
  update public.reclamaciones
     set estado = coalesce(v_est, estado),
         observacion_publica = case when coalesce(p_publica, false) and v_txt is not null then v_txt else observacion_publica end,
         actualizado_en = now()
   where id = p_id;
  insert into public.reclamacion_gestion (reclamacion_id, accion, estado, texto, publica, usuario)
  values (p_id, case when v_est is not null and v_est <> v_ant then 'ESTADO' else 'NOTA' end,
          coalesce(v_est, v_ant), v_txt, coalesce(p_publica, false) and v_txt is not null, auth.email());
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.reclamacion_gestionar(bigint, text, text, boolean) from public, anon;
grant execute on function public.reclamacion_gestionar(bigint, text, text, boolean) to authenticated;

-- Revisar un archivo: aceptarlo, rechazarlo (con el motivo, que el reclamante ve) o devolverlo a revisión.
create or replace function public.reclamacion_doc_revisar(p_doc_id bigint, p_estado text, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_est text := upper(btrim(coalesce(p_estado, '')));
  v_mot text := nullif(btrim(coalesce(p_motivo, '')), '');
  d     record;
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Solo seguridad vial revisa los documentos.');
  end if;
  if v_est not in ('RECIBIDO', 'ACEPTADO', 'RECHAZADO') then
    return jsonb_build_object('ok', false, 'error', 'Estado no válido.');
  end if;
  if v_est = 'RECHAZADO' and length(coalesce(v_mot, '')) < 5 then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se rechaza: el reclamante lo va a leer para corregirlo.');
  end if;
  select x.id, x.reclamacion_id, q.titulo into d
    from public.reclamacion_docs x join public.reclamacion_requisitos q on q.codigo = x.requisito
   where x.id = p_doc_id;
  if d.id is null then return jsonb_build_object('ok', false, 'error', 'No existe ese documento.'); end if;
  update public.reclamacion_docs
     set estado = v_est, motivo_rechazo = case when v_est = 'RECHAZADO' then v_mot end,
         revisado_por = case when v_est = 'RECIBIDO' then null else auth.email() end,
         revisado_en  = case when v_est = 'RECIBIDO' then null else now() end
   where id = p_doc_id;
  update public.reclamaciones set actualizado_en = now() where id = d.reclamacion_id;
  insert into public.reclamacion_gestion (reclamacion_id, accion, texto, usuario)
  values (d.reclamacion_id, 'REVISION',
          d.titulo || ': ' || lower(v_est) || coalesce(' — ' || v_mot, ''), auth.email());
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.reclamacion_doc_revisar(bigint, text, text) from public, anon;
grant execute on function public.reclamacion_doc_revisar(bigint, text, text) to authenticated;

-- Asociar (o soltar, con null) el siniestro de la app que corresponde a esta reclamación.
create or replace function public.reclamacion_vincular(p_id bigint, p_siniestro_key text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_key text := nullif(btrim(coalesce(p_siniestro_key, '')), '');
begin
  if not public.es_seguridad_vial() then
    return jsonb_build_object('ok', false, 'error', 'Sin permiso.');
  end if;
  if v_key is not null and not exists (select 1 from public.siniestros where key = v_key) then
    return jsonb_build_object('ok', false, 'error', 'Ese siniestro no existe.');
  end if;
  update public.reclamaciones set siniestro_key = v_key, actualizado_en = now() where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'No existe esa reclamación.'); end if;
  insert into public.reclamacion_gestion (reclamacion_id, accion, texto, usuario)
  values (p_id, 'SINIESTRO', case when v_key is null then 'Se soltó el siniestro asociado.'
                                  else 'Se asoció al siniestro reportado en la app.' end, auth.email());
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.reclamacion_vincular(bigint, text) from public, anon;
grant execute on function public.reclamacion_vincular(bigint, text) to authenticated;
