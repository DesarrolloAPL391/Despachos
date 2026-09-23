-- ===================================================================================
-- 118: LA PQRSF LA RADICA EL USUARIO Y EL SISTEMA LA REDIRIGE SOLO.
-- ===================================================================================
-- Hasta hoy el usuario del servicio llena un formulario de AppSheet, la fila cae en una hoja
-- de Google, alguien la mira, decide a quién se la manda y la escribe en la columna
-- "RESPONSABLE AREA DE DESTINO". Eso es el trabajo que se automatiza aquí: el usuario cuenta
-- qué le pasó, y la PQRSF entra a la base ya clasificada, ya asignada y con su fecha límite
-- calculada. Nadie tiene que repartirla.
--
-- LO QUE SE APRENDIÓ DE LAS 2.589 PQRSF VIEJAS, Y QUE ESTE ARCHIVO RESPETA:
--
--   1) EL CATÁLOGO ESTÁ SUCIO. 46 motivos donde hay "RECLAMACION DE DINERO" y "RECLAMACION
--      DINERO", "AGRESION FISICA/VERBAL" y "AGRESION FISICA Y VERBAL", "CONTAMINACION
--      AMBIENTAL" y "COMTAMINACION AMBIENTAL", "COMPORTAMIENTO OBSCENO" y "OBSENO". Son la
--      misma cosa escrita distinto, y partían los informes en pedazos. Aquí queda un catálogo
--      cerrado de 30 motivos, cada uno con la lista de las formas viejas que significan lo
--      mismo (`equivale_a`), para que las estadísticas sumen lo que hay que sumar.
--
--   2) EL USUARIO NO SABE —NI TIENE POR QUÉ SABER— SI LO SUYO ES QUEJA, RECLAMO O PETICIÓN.
--      Esa pregunta es la que más ensucia el dato: hay FELICITACIONES radicadas como QUEJA.
--      Así que el formulario NO la hace: el usuario elige qué le pasó y el tipo lo pone el
--      sistema, porque el tipo es consecuencia del motivo, no una opinión.
--
--   3) EL "ÁREA DE DESTINO" NO SON ÁREAS, SON PERSONAS: doce nombres, y 1.815 de 2.589 (70%)
--      a uno solo. No se inventa una taxonomía nueva: el destino de cada motivo se SIEMBRA
--      APRENDIÉNDOLO del histórico —quién atendió ese motivo la mayoría de las veces— y queda
--      editable en pantalla. Así el ruteo automático encaja con los permisos que ya existen
--      (`pqrsf_acceso.area`) sin romperle el acceso a nadie.
--
--   4) EL PLAZO SON 3 DÍAS HÁBILES CONTADOS DE UNA FORMA PARTICULAR. Descifrada la fórmula de
--      la hoja: suma 3 días y, si cae sábado o domingo, suma otros 3. Por eso una PQRSF del
--      viernes vence el lunes (1 día hábil) y una del miércoles vence el martes (4 días
--      hábiles). Es desigual, pero es la promesa contra la que se han medido cuatro años, y
--      se replica IGUAL a propósito: cambiarla ahora haría incomparable el histórico.
--      (Se decidió así el 23/09/2026. Si algún día se corrige, es un solo lugar: pqrsf_plazo.)
--
-- LO QUE NO HACE: no toca AppSheet. Las que llegan por teléfono, WhatsApp o correo se siguen
-- radicando allá y trayendo con `pqrsf_cargar`. Las de este formulario tienen `key` propia
-- ('WEB-<uuid>') que nunca viene en la hoja, así que volver a traer el CSV no las pisa.
-- ===================================================================================

-- ---------- 1) Lo que hay que agregarle a la tabla ----------
alter table public.pqrsf add column if not exists origen      text not null default 'APPSHEET';
alter table public.pqrsf add column if not exists anonima     boolean not null default false;
alter table public.pqrsf add column if not exists recibido_en  timestamptz;
alter table public.pqrsf add column if not exists ip_origen    text;

comment on column public.pqrsf.origen is 'APPSHEET (la hoja) o WEB (formulario propio, sql/118).';
comment on column public.pqrsf.anonima is 'El usuario pidio no dejar datos: se radica, pero no hay a quien responderle.';
comment on column public.pqrsf.recibido_en is 'Momento exacto en que entro por el formulario (la hoja solo trae fecha y hora sueltas).';

create index if not exists pqrsf_origen_idx on public.pqrsf (origen, fecha_radicado desc);

-- ---------- 2) El catálogo: qué puede pasar, y a quién le toca ----------
create table if not exists public.pqrsf_motivos (
  motivo      text primary key,                    -- el nombre canónico (el que se guarda)
  titulo      text not null,                       -- como se le muestra al usuario del servicio
  ayuda       text,                                -- una línea para que elija bien
  grupo       text not null default 'OTROS',        -- para agrupar la lista en el formulario
  tipo        text not null,                       -- QUEJA / PETICION / RECLAMO / SUGERENCIA / FELICITACIONES
  destino     text,                                -- a quién se le asigna (igual que RESPONSABLE AREA DE DESTINO)
  pide_movil  boolean not null default true,       -- si sin el número del bus no se puede investigar
  urgente     boolean not null default false,      -- marca URGENTE al radicarla
  equivale_a  text[] not null default '{}',         -- las formas viejas de escribir lo mismo
  orden       int not null default 100,
  activo      boolean not null default true,
  nota        text,
  actualizado_en timestamptz not null default now(),
  actualizado_por text
);
comment on table public.pqrsf_motivos is
  'Catalogo cerrado de motivos del formulario publico. El tipo y el destino salen de aqui: el usuario no los elige.';

alter table public.pqrsf_motivos enable row level security;
drop policy if exists pqm_lee_todo on public.pqrsf_motivos;
create policy pqm_lee_todo on public.pqrsf_motivos for select to authenticated using (true);

-- Devuelve el nombre canónico de un motivo escrito de cualquier forma. Lo usan las
-- estadísticas para que "RECLAMACION DINERO" y "RECLAMACION DE DINERO" sumen juntas.
create or replace function public.pqrsf_motivo_norm(p_motivo text)
returns text language sql stable security definer set search_path = public as $fn$
  select coalesce(
    (select m.motivo from public.pqrsf_motivos m
      where upper(btrim(coalesce(p_motivo, ''))) = m.motivo
         or upper(btrim(coalesce(p_motivo, ''))) = any (m.equivale_a)
      limit 1),
    nullif(upper(btrim(coalesce(p_motivo, ''))), ''),
    '(sin motivo)');
$fn$;
grant execute on function public.pqrsf_motivo_norm(text) to authenticated;

-- ---------- 3) El plazo, tal como lo calcula la hoja desde 2022 ----------
-- +3 días; si cae sábado o domingo, +3 otra vez. Verificado contra 2.516 PQRSF: radicada el
-- lunes vence el jueves, el miércoles vence el martes, el viernes vence el lunes.
create or replace function public.pqrsf_plazo(p_radicado date)
returns date language sql immutable as $fn$
  select case when extract(isodow from p_radicado + 3) in (6, 7)
              then p_radicado + 6 else p_radicado + 3 end;
$fn$;
comment on function public.pqrsf_plazo(date) is
  'La formula de AppSheet, replicada igual a proposito: +3 dias y, si cae fin de semana, +3 mas.';

-- ---------- 4) Las pruebas que adjunta el usuario ----------
-- Van en la base como las de permisos (sql/97): son pocas (13% de las PQRSF traen algo) y
-- llegan comprimidas desde el navegador.
create table if not exists public.pqrsf_adjuntos (
  id         bigint generated always as identity primary key,
  pqrsf_key  text not null references public.pqrsf(key) on delete cascade,
  nombre     text,
  tipo_mime  text,
  archivo    text not null,                      -- data:...;base64,...
  bytes      int,
  creado_en  timestamptz not null default now()
);
create index if not exists pqrsf_adj_key_idx on public.pqrsf_adjuntos (pqrsf_key);

alter table public.pqrsf_adjuntos enable row level security;
drop policy if exists pqa_lee on public.pqrsf_adjuntos;
create policy pqa_lee on public.pqrsf_adjuntos for select to authenticated
  using ((select public.es_pqrsf()));

-- ---------- 5) El consecutivo ----------
-- Formato propio (PQR-2026-0001) para no chocar con el "RADICADO # N" de AppSheet, que sigue
-- numerando por su lado mientras el canal telefónico viva allá.
create sequence if not exists public.pqrsf_web_seq as bigint start 1;

-- ---------- 6) Lo que ve la página pública (sin sesión) ----------
-- Devuelve SOLO el catálogo y la lista de rutas. Nada de placas, propietarios, ni el parque:
-- el número del bus lo escribe el usuario y lo resuelve el servidor por dentro.
create or replace function public.pqrsf_catalogo()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'ok', true,
    'motivos', (select coalesce(jsonb_agg(jsonb_build_object(
                    'motivo', m.motivo, 'titulo', m.titulo, 'ayuda', m.ayuda, 'grupo', m.grupo,
                    'tipo', m.tipo, 'pide_movil', m.pide_movil)
                  order by m.orden, m.titulo), '[]'::jsonb)
                 from public.pqrsf_motivos m where m.activo),
    'rutas', (select coalesce(jsonb_agg(r.nombre order by r.nombre), '[]'::jsonb)
                from public.rutas r));
$fn$;
revoke all on function public.pqrsf_catalogo() from public;
grant execute on function public.pqrsf_catalogo() to anon, authenticated;

-- ---------- 7) Radicar (el usuario del servicio, sin cuenta) ----------
create or replace function public.pqrsf_radicar(p_datos jsonb, p_adjuntos jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $fn$
declare
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_ahora timestamptz := now();
  v_m record;
  v_desc text := btrim(coalesce(p_datos->>'descripcion', ''));
  v_nom  text := btrim(coalesce(p_datos->>'nombre', ''));
  v_cor  text := lower(btrim(coalesce(p_datos->>'correo', '')));
  v_tel  text := regexp_replace(coalesce(p_datos->>'telefono', ''), '\D', '', 'g');
  v_mov  text := regexp_replace(coalesce(p_datos->>'movil', ''), '\D', '', 'g');
  v_ruta text := btrim(coalesce(p_datos->>'ruta', ''));
  v_dir  text := btrim(coalesce(p_datos->>'direccion', ''));
  v_anon boolean := coalesce((p_datos->>'anonima')::boolean, false);
  v_fs   date := nullif(p_datos->>'fecha_suceso', '')::date;
  v_hs   time := nullif(p_datos->>'hora_suceso', '')::time;
  v_ip   text;
  v_placa text;
  v_key  text;
  v_rad  text;
  v_n    int;
  s      jsonb;
begin
  -- Trampa para los robots: el formulario trae un campo que una persona nunca ve ni llena.
  -- Si viene con algo, se contesta como si todo hubiera salido bien y no se guarda nada.
  if coalesce(btrim(p_datos->>'trampa'), '') <> '' then
    return jsonb_build_object('ok', true, 'radicado', 'PQR-0000-0000');
  end if;

  select m.* into v_m from public.pqrsf_motivos m
   where m.motivo = upper(btrim(coalesce(p_datos->>'motivo', ''))) and m.activo;
  if v_m.motivo is null then
    return jsonb_build_object('ok', false, 'error', 'Elige de la lista qué fue lo que pasó.');
  end if;

  if length(v_desc) < 20 then
    return jsonb_build_object('ok', false, 'error',
      'Cuéntanos qué pasó con un poco más de detalle: al menos 20 letras. Eso es lo que permite investigar.');
  end if;
  if length(v_desc) > 4000 then
    return jsonb_build_object('ok', false, 'error', 'El relato quedó muy largo. Resúmelo en menos de 4.000 letras.');
  end if;

  -- Contacto: sin él no hay a quién responderle. Se permite anónima, pero diciéndolo.
  if not v_anon then
    if v_cor !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' and length(v_tel) not between 7 and 12 then
      return jsonb_build_object('ok', false, 'error',
        'Déjanos un correo o un celular para poder responderte. Si prefieres no dejar datos, marca la casilla de PQRSF anónima.');
    end if;
    if length(v_nom) < 3 then
      return jsonb_build_object('ok', false, 'error', 'Escribe tu nombre.');
    end if;
  end if;

  if v_fs is null then
    return jsonb_build_object('ok', false, 'error', '¿Qué día pasó?');
  end if;
  if v_fs > v_hoy then
    return jsonb_build_object('ok', false, 'error', 'La fecha del suceso no puede ser futura.');
  end if;
  if v_fs < v_hoy - 90 then
    return jsonb_build_object('ok', false, 'error',
      'Ese hecho tiene más de tres meses. Escríbenos al correo de servicio al cliente para revisarlo.');
  end if;
  if v_m.pide_movil and length(v_mov) not between 3 and 5 then
    return jsonb_build_object('ok', false, 'error',
      'Para esto necesitamos el número del bus: son 4 dígitos grandes, en la parte de adelante y en los costados.');
  end if;

  -- Frenos de abuso. No pretenden ser una muralla: evitan el goteo de un formulario abierto.
  begin
    v_ip := split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1);
  exception when others then v_ip := null;
  end;
  if coalesce(v_cor, '') <> '' then
    select count(1) into v_n from public.pqrsf
     where origen = 'WEB' and lower(coalesce(usuario_correo, '')) = v_cor and creado_en > now() - interval '1 day';
    if v_n >= 5 then
      return jsonb_build_object('ok', false, 'error',
        'Ya radicaste varias PQRSF hoy con ese correo. Si falta algo, respóndenos sobre el radicado que ya tienes.');
    end if;
  end if;
  if coalesce(v_ip, '') <> '' then
    select count(1) into v_n from public.pqrsf
     where origen = 'WEB' and ip_origen = v_ip and creado_en > now() - interval '1 hour';
    if v_n >= 10 then
      return jsonb_build_object('ok', false, 'error', 'Demasiadas solicitudes seguidas. Intenta de nuevo en un rato.');
    end if;
  end if;

  -- El móvil se resuelve contra el parque: si el número existe, la PQRSF queda con su placa.
  if length(v_mov) between 3 and 5 then
    select v.placa into v_placa from public.vehiculos v where btrim(v.numero) = v_mov limit 1;
  end if;

  v_key := 'WEB-' || gen_random_uuid()::text;
  v_rad := 'PQR-' || to_char(v_hoy, 'YYYY') || '-' || lpad(nextval('public.pqrsf_web_seq')::text, 4, '0');

  insert into public.pqrsf (
    key, radicado, fecha_radicado, hora_recibido, recibido_en,
    placa, numero_interno, ruta,
    fecha_suceso, hora_suceso, direccion_suceso, descripcion,
    usuario_nombre, usuario_correo, usuario_telefono, anonima,
    medio_recibido, tipo, motivo, urgencia,
    responsable_destino, area_app, estado, estado_app, fecha_limite,
    origen, ip_origen, datos_origen)
  values (
    v_key, v_rad, v_hoy, (v_ahora at time zone 'America/Bogota')::time, v_ahora,
    v_placa, nullif(v_mov, ''), nullif(v_ruta, ''),
    v_fs, v_hs, nullif(v_dir, ''), v_desc,
    case when v_anon then null else nullif(v_nom, '') end,
    case when v_anon then null else nullif(v_cor, '') end,
    case when v_anon then null else nullif(v_tel, '') end,
    v_anon,
    'FORMULARIO WEB', v_m.tipo, v_m.motivo,
    case when v_m.urgente then 'URGENTE' end,
    v_m.destino, v_m.destino, 'ABIERTA', 'EN PROCESO', public.pqrsf_plazo(v_hoy),
    'WEB', nullif(v_ip, ''),
    jsonb_build_object('origen', 'formulario web', 'recibido', v_ahora,
                       'motivo_elegido', v_m.titulo, 'agente', left(coalesce(p_datos->>'agente', ''), 200)));

  -- Pruebas: hasta 3, y cada una hasta ~1,5 MB ya codificada (el navegador las comprime).
  for s in select * from jsonb_array_elements(coalesce(p_adjuntos, '[]'::jsonb)) limit 3 loop
    if length(coalesce(s->>'archivo', '')) between 100 and 2000000 then
      insert into public.pqrsf_adjuntos (pqrsf_key, nombre, tipo_mime, archivo, bytes)
      values (v_key, left(coalesce(s->>'nombre', 'prueba'), 120), s->>'tipo_mime',
              s->>'archivo', length(s->>'archivo'));
    end if;
  end loop;

  -- Queda registrado que entró sola, sin que nadie la reparta.
  insert into public.pqrsf_gestion (pqrsf_key, accion, area, texto, usuario)
  values (v_key, 'ASIGNACION', v_m.destino,
          'Radicada por el usuario en el formulario público y asignada automáticamente por motivo.',
          'formulario');

  return jsonb_build_object('ok', true, 'radicado', v_rad, 'tipo', v_m.tipo,
    'fecha_limite', public.pqrsf_plazo(v_hoy), 'anonima', v_anon);
end $fn$;
revoke all on function public.pqrsf_radicar(jsonb, jsonb) from public;
grant execute on function public.pqrsf_radicar(jsonb, jsonb) to anon, authenticated;

-- ---------- 8) Que el usuario pueda ver en qué quedó lo suyo ----------
-- Con el radicado Y su correo (o su celular): las dos cosas, para que nadie pesque quejas
-- ajenas probando números. Solo las del formulario: las de la hoja no se exponen.
create or replace function public.pqrsf_consultar(p_radicado text, p_contacto text)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_rad text := upper(btrim(coalesce(p_radicado, '')));
  v_c   text := lower(btrim(coalesce(p_contacto, '')));
  v_tel text := regexp_replace(coalesce(p_contacto, ''), '\D', '', 'g');
  r     record;
begin
  if v_rad = '' or v_c = '' then
    return jsonb_build_object('ok', false, 'error', 'Escribe tu número de radicado y el correo o celular que dejaste.');
  end if;
  select p.radicado, p.fecha_radicado, p.fecha_limite, p.tipo, p.motivo, p.estado, p.estado_app,
         coalesce(p.respuesta_app, p.respuesta) as respuesta,
         coalesce(p.fecha_respuesta, p.respondido_el) as respondida_el
    into r
    from public.pqrsf p
   where p.origen = 'WEB' and upper(p.radicado) = v_rad
     and ( lower(coalesce(p.usuario_correo, '')) = v_c
        or (length(v_tel) >= 7 and regexp_replace(coalesce(p.usuario_telefono, ''), '\D', '', 'g') = v_tel) )
   limit 1;
  if r.radicado is null then
    return jsonb_build_object('ok', false, 'error',
      'No encontramos esa PQRSF con ese dato de contacto. Revisa el número de radicado tal como te lo dimos.');
  end if;
  return jsonb_build_object('ok', true,
    'radicado', r.radicado, 'radicada_el', r.fecha_radicado, 'fecha_limite', r.fecha_limite,
    'tipo', r.tipo, 'motivo', r.motivo,
    'respondida', (r.respuesta is not null and btrim(r.respuesta) <> ''),
    'respondida_el', r.respondida_el,
    'respuesta', nullif(btrim(coalesce(r.respuesta, '')), ''),
    'cerrada', (coalesce(r.estado_app, r.estado) in ('CERRADA')));
end $fn$;
revoke all on function public.pqrsf_consultar(text, text) from public;
grant execute on function public.pqrsf_consultar(text, text) to anon, authenticated;

-- ---------- 9) La pantalla del ruteo (administración) ----------
create or replace function public.pqrsf_ruteo_ver()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare v_puede boolean;
begin
  v_puede := ( (select public.es_pqrsf()) or (select public.es_consola()) );
  if not v_puede then return jsonb_build_object('ok', false, 'error', 'Sin permiso.'); end if;
  return jsonb_build_object('ok', true,
    'admin', ((select public.es_admin()) or (select public.es_talento_humano()) or (select public.es_consola())),
    'motivos', (select coalesce(jsonb_agg(jsonb_build_object(
                    'motivo', m.motivo, 'titulo', m.titulo, 'ayuda', m.ayuda, 'tipo', m.tipo, 'grupo', m.grupo,
                    'destino', m.destino, 'pide_movil', m.pide_movil, 'urgente', m.urgente,
                    'equivale_a', m.equivale_a, 'orden', m.orden, 'activo', m.activo,
                    'usadas', (select count(1) from public.pqrsf p
                                where public.pqrsf_motivo_norm(p.motivo) = m.motivo),
                    'por_web', (select count(1) from public.pqrsf p
                                 where p.origen = 'WEB' and p.motivo = m.motivo))
                  order by m.orden, m.titulo), '[]'::jsonb) from public.pqrsf_motivos m),
    -- Los destinos que ya existen en la operación: la lista sale de los datos, no de un código.
    'destinos', (select coalesce(jsonb_agg(d order by d), '[]'::jsonb) from (
                   select distinct upper(btrim(coalesce(area_app, responsable_destino))) as d
                     from public.pqrsf
                    where coalesce(area_app, responsable_destino) is not null
                      and btrim(coalesce(area_app, responsable_destino)) <> '') s),
    'web', (select jsonb_build_object(
              'total', count(1),
              'hoy', count(1) filter (where fecha_radicado = (now() at time zone 'America/Bogota')::date),
              'semana', count(1) filter (where fecha_radicado > (now() at time zone 'America/Bogota')::date - 7),
              'anonimas', count(1) filter (where anonima),
              'ultima', max(recibido_en))
              from public.pqrsf where origen = 'WEB'));
end $fn$;
revoke all on function public.pqrsf_ruteo_ver() from public, anon;
grant execute on function public.pqrsf_ruteo_ver() to authenticated;

create or replace function public.pqrsf_ruteo_guardar(p_motivos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_yo text := coalesce(auth.jwt() ->> 'email', 'consola'); m jsonb; v_n int := 0;
begin
  if not ( (select public.es_admin()) or (select public.es_talento_humano()) or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración cambia el ruteo de las PQRSF.');
  end if;
  for m in select * from jsonb_array_elements(coalesce(p_motivos, '[]'::jsonb)) loop
    update public.pqrsf_motivos
       set destino    = nullif(upper(btrim(coalesce(m->>'destino', ''))), ''),
           pide_movil = coalesce((m->>'pide_movil')::boolean, pide_movil),
           urgente    = coalesce((m->>'urgente')::boolean, urgente),
           activo     = coalesce((m->>'activo')::boolean, activo),
           titulo     = coalesce(nullif(btrim(coalesce(m->>'titulo', '')), ''), titulo),
           ayuda      = coalesce(nullif(btrim(coalesce(m->>'ayuda', '')), ''), ayuda),
           actualizado_en = now(), actualizado_por = v_yo
     where motivo = upper(btrim(coalesce(m->>'motivo', '')));
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'guardados', v_n);
end $fn$;
revoke all on function public.pqrsf_ruteo_guardar(jsonb) from public, anon;
grant execute on function public.pqrsf_ruteo_guardar(jsonb) to authenticated;

-- ===================================================================================
-- 10) LA SIEMBRA DEL CATÁLOGO
-- ===================================================================================
-- Los 30 motivos limpios, con las formas viejas que cada uno absorbe. El `destino` NO se
-- escribe aquí: se aprende más abajo del propio histórico, que es quien sabe a quién le toca.
insert into public.pqrsf_motivos (motivo, titulo, ayuda, grupo, tipo, pide_movil, urgente, equivale_a, orden)
values
  ('MAL SERVICIO', 'Me trataron mal o me prestaron mal el servicio',
   'El conductor fue grosero, no me dejó subir, me dejó en otra parte.', 'EL SERVICIO', 'QUEJA', true, false,
   array['MAL SERVICIO EN LA RUTA','MAL SERVIO EN LA RUTA','MAL SERVICIO E INFRACCION A LA NORMA'], 10),
  ('MAL COMPORTAMIENTO DEL CONDUCTOR', 'El conductor se comportó mal',
   'Habló mal, discutió con pasajeros, hizo algo indebido durante el recorrido.', 'EL SERVICIO', 'QUEJA', true, false,
   array['MAL COMPORTAMIENTO'], 20),
  ('EL BUS NO PARÓ', 'El bus no paró donde debía',
   'Le hice la señal en el paradero y siguió, o no me dejó bajar donde pedí.', 'EL SERVICIO', 'QUEJA', true, false,
   array['EL VEHICULO NO PARA EN EL PARADERO','NO PARAN EN EL RECORRIDO PARA QUE LA GENTE SE MONTE',
         'NO PARA EN EL RECORRIDO PARA QUE LA GENTE SE MONTE'], 30),
  ('DEMORA EN LA RUTA', 'Esperé demasiado el bus',
   'Pasó mucho tiempo sin que llegara ninguno, o el viaje se demoró más de lo normal.', 'EL SERVICIO', 'QUEJA', false, false,
   array['DEMORA EN LA RUTA Y MAL SERVICIO'], 40),
  ('NO RECORRE LA RUTA COMPLETA', 'El bus no hizo toda la ruta',
   'Se devolvió antes de terminar el recorrido o se saltó un tramo.', 'EL SERVICIO', 'QUEJA', true, false, '{}', 50),
  ('EXCESO DE VELOCIDAD', 'Iba muy rápido',
   'Corría más de lo permitido o de lo que se siente seguro.', 'COMO MANEJA', 'QUEJA', true, true, '{}', 60),
  ('CONDUCE BRUSCO', 'Maneja brusco',
   'Frenadas y arrancones fuertes, curvas rápidas; la gente se golpea.', 'COMO MANEJA', 'QUEJA', true, true, '{}', 70),
  ('GUERREO', 'Va compitiendo con otro bus',
   'Carreras con otro vehículo para recoger pasajeros.', 'COMO MANEJA', 'QUEJA', true, true, '{}', 80),
  ('USO DEL CELULAR', 'Maneja hablando por celular',
   'Usa el teléfono mientras conduce.', 'COMO MANEJA', 'QUEJA', true, true, '{}', 90),
  ('INFRACCION A LA NORMA', 'Cometió una infracción de tránsito',
   'Se pasó un semáforo, iba en contravía, no respetó una señal.', 'COMO MANEJA', 'QUEJA', true, true, '{}', 100),
  ('MANIPULACION DE SENSORES', 'Manipulan los equipos del bus',
   'Tapan o alteran los sensores, las cámaras o el conteo de pasajeros.', 'COMO MANEJA', 'QUEJA', true, false,
   array['SENSORES'], 110),
  ('INGRESO POR LA PARTE DE ATRAS', 'Dejan subir por la puerta de atrás',
   'Permiten el ingreso por donde no se debe.', 'COMO MANEJA', 'QUEJA', true, false, '{}', 120),
  ('INCIDENTE DE TRANSITO', 'Hubo un choque o un accidente',
   'El bus se vio involucrado en un incidente de tránsito.', 'ALGO GRAVE', 'QUEJA', true, true, '{}', 130),
  ('INCIDENTE DENTRO DEL BUS', 'Me pasó algo dentro del bus',
   'Una caída, un golpe, una lesión durante el viaje.', 'ALGO GRAVE', 'QUEJA', true, true, '{}', 140),
  ('AGRESION FISICA O VERBAL', 'Me agredieron',
   'Hubo agresión física o verbal, del conductor o entre pasajeros.', 'ALGO GRAVE', 'QUEJA', true, true,
   array['AGRESION FISICA/VERBAL','AGRESION FISICA Y VERBAL','AGRESION VERBAL','AGRESION FISICA'], 150),
  ('COMPORTAMIENTO OBSCENO', 'Conducta obscena o acoso',
   'Alguien se comportó de forma obscena o me acosó.', 'ALGO GRAVE', 'QUEJA', true, true,
   array['COMPORTAMIENTO OBSENO'], 160),
  ('HURTO', 'Me robaron en el bus',
   'Un hurto dentro del vehículo o en el paradero.', 'ALGO GRAVE', 'QUEJA', true, true, '{}', 170),
  ('CONSUMO DE SUSTANCIAS PSICOACTIVAS', 'Consumo de alcohol o drogas',
   'Sospecha de consumo por parte del conductor, o consumo a bordo.', 'ALGO GRAVE', 'QUEJA', true, true, '{}', 180),
  ('ORDEN Y ASEO', 'El bus estaba sucio o en mal estado',
   'Basura, sillas dañadas, mal olor, vidrios sucios.', 'EL BUS', 'QUEJA', true, false,
   array['ASEO'], 190),
  ('CONTAMINACION AMBIENTAL', 'El bus echa mucho humo',
   'Humo negro o exceso de gases.', 'EL BUS', 'QUEJA', true, false,
   array['COMTAMINACION AMBIENTAL'], 200),
  ('CONTAMINACION AUDITIVA', 'Música o ruido muy alto',
   'El equipo de sonido a todo volumen, pitos innecesarios.', 'EL BUS', 'QUEJA', true, false, '{}', 210),
  ('NO APLICA PROTOCOLOS DE BIOSEGURIDAD', 'No cumple los protocolos de bioseguridad',
   'Falta de aseo o de las medidas exigidas.', 'EL BUS', 'QUEJA', true, false, '{}', 220),
  ('VENDEDORES AMBULANTES', 'Suben vendedores al bus',
   'Permiten el ingreso de vendedores durante el recorrido.', 'EL BUS', 'QUEJA', true, false, '{}', 230),
  ('MAL SERVICIO DEL DESPACHADOR', 'El despachador me atendió mal',
   'La persona que despacha en el punto, no el conductor.', 'EL SERVICIO', 'QUEJA', false, false,
   array['MAL SERVICIO DESPACHADOR','NO SIGUE LAS INDICACIONES DEL DESPACHADOR'], 240),
  ('OBJETOS PERDIDOS', 'Dejé algo olvidado en el bus',
   'Un objeto que se quedó a bordo y quiero recuperar.', 'TRAMITES', 'PETICION', true, false, '{}', 250),
  ('RECLAMACION DE DINERO', 'Reclamo de dinero',
   'Cobro de más, no me dieron el cambio, pagué dos veces.', 'TRAMITES', 'RECLAMO', true, false,
   array['RECLAMACION DINERO'], 260),
  ('CAMBIO DE TRAZADO', 'Pido un cambio de recorrido o de horario',
   'Que la ruta llegue a otro punto, o que haya buses a otra hora.', 'TRAMITES', 'PETICION', false, false, '{}', 270),
  ('PETICION O SOLICITUD', 'Quiero pedir o preguntar algo',
   'Información, un certificado, una solicitud que no está en la lista.', 'TRAMITES', 'PETICION', false, false,
   array['PETICION'], 280),
  ('OTRO RECLAMO', 'Tengo otro reclamo',
   'Algo que no encaja en las opciones de arriba.', 'TRAMITES', 'RECLAMO', false, false,
   array['RECLAMO'], 290),
  ('SUGERENCIA', 'Tengo una sugerencia',
   'Una idea para mejorar el servicio.', 'TRAMITES', 'SUGERENCIA', false, false,
   array['SUGERENCIA/SOLICITUD'], 300),
  ('FELICITACIONES', 'Quiero felicitar a alguien',
   'Un conductor, un despachador o el servicio en general.', 'TRAMITES', 'FELICITACIONES', false, false,
   array['FELICITACION'], 310)
on conflict (motivo) do update set
  titulo = excluded.titulo, ayuda = excluded.ayuda, tipo = excluded.tipo,
  grupo = excluded.grupo, pide_movil = excluded.pide_movil, urgente = excluded.urgente,
  equivale_a = excluded.equivale_a, orden = excluded.orden;

-- El destino se APRENDE: para cada motivo, quién atendió la mayoría de las veces ese motivo
-- (contando también las formas viejas de escribirlo). Si un motivo no tiene histórico, queda
-- con el destino que más PQRSF ha atendido en general, para que nunca entre una sin dueño.
with hist as (
  select public.pqrsf_motivo_norm(p.motivo) as motivo,
         upper(btrim(coalesce(p.area_app, p.responsable_destino))) as destino,
         count(1) as n
    from public.pqrsf p
   where coalesce(p.area_app, p.responsable_destino) is not null
     and btrim(coalesce(p.area_app, p.responsable_destino)) <> ''
   group by 1, 2),
mejor as (
  select distinct on (motivo) motivo, destino from hist order by motivo, n desc
),
global as (
  select destino from hist group by destino order by sum(n) desc limit 1
)
update public.pqrsf_motivos m
   set destino = coalesce((select b.destino from mejor b where b.motivo = m.motivo),
                          (select g.destino from global g)),
       nota = coalesce(m.nota, 'Destino sembrado del historico el 23/09/2026.')
 where m.destino is null;

-- ===================================================================================
-- PARA VERIFICAR DESPUÉS DE EJECUTAR:
--   select motivo, titulo, tipo, destino, pide_movil, urgente from public.pqrsf_motivos order by orden;
--   select public.pqrsf_catalogo() -> 'motivos' -> 0;          -- lo que verá el formulario
--   select public.pqrsf_plazo(current_date);                    -- la fecha límite de hoy
--   select public.pqrsf_ruteo_ver() -> 'destinos';              -- a quién se puede asignar
-- Las que entren por el link aparecen solas en 📥 Falta por responder, ya asignadas.
-- ===================================================================================
