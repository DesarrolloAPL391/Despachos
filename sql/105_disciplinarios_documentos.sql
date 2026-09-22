-- ===================================================================================
-- 105: DISCIPLINARIOS — la diligencia de descargos y sus documentos (va con sql/102).
-- ===================================================================================
-- Hasta hoy el proceso guardaba CUÁNDO fue la diligencia (fecha y horas) pero no QUÉ
-- pasó en ella. Y eso es justamente lo que sostiene una sanción: el artículo 115 del
-- Código Sustantivo del Trabajo exige oír al trabajador antes de sancionarlo, y la
-- persona tiene derecho a hacerse acompañar. Un acta que solo dice "se hizo el 15 de
-- mayo de 9:00 a 9:40" no defiende nada si el caso llega a un juzgado.
--
-- Aquí se guarda la diligencia completa: los hechos que se le imputaron, las preguntas
-- y sus respuestas, la versión del trabajador, quién lo acompañó y las firmas.
--
-- El acta se escribe EN VIVO durante la diligencia, así que se guarda a pedazos
-- (disc_acta_guardar se puede llamar muchas veces) y al final se SELLA (disc_acta_cerrar).
-- Una vez sellada no se edita: un acta que se puede cambiar después no prueba nada.

-- ---------- La diligencia ----------
create table if not exists public.disciplinarios_acta (
  proceso_id        bigint primary key references public.disciplinarios(id) on delete cascade,
  lugar             text,
  -- Quién dirige la diligencia y quién toma nota
  dirige_nombre     text,
  dirige_cargo      text,
  dirige_cedula     text,
  secretario_nombre text,
  -- Los dos compañeros que puede llevar el trabajador (CST art. 115). Se guarda
  -- también cuando NO llevó a nadie: que conste que se le ofreció y no quiso.
  acompanantes      jsonb not null default '[]'::jsonb,   -- [{nombre, cedula, cargo}]
  acompanar_ofrecido boolean not null default true,
  -- El contenido
  hechos            text,          -- lo que se le imputa, leído al inicio
  preguntas         jsonb not null default '[]'::jsonb,   -- [{p, r}]
  version_trabajador text,         -- el descargo propiamente dicho
  pruebas           text,          -- lo que aporta o pide que se practique
  observaciones     text,
  -- Si no se presentó, el acta se vuelve constancia de no comparecencia
  comparecio        boolean not null default true,
  no_comparecio_nota text,
  -- Firmas hechas en pantalla: PNG en data URI
  firma_trabajador  text,
  firma_trabajador_negada boolean not null default false,
  firma_negada_nota text,
  firma_dirige      text,
  -- Sellado
  cerrada_en        timestamptz,
  cerrada_por       text,
  creado_en         timestamptz not null default now(),
  creado_por        text,
  actualizado_en    timestamptz not null default now()
);
create index if not exists disc_acta_cerrada_idx on public.disciplinarios_acta (cerrada_en);

-- ---------- Los documentos que se imprimen ----------
-- Cada impresión queda registrada con su consecutivo y con una copia de lo que decía.
-- Si mañana el proceso cambia, el documento que se entregó sigue siendo demostrable.
create table if not exists public.disciplinarios_docs (
  id            bigint generated always as identity primary key,
  proceso_id    bigint not null references public.disciplinarios(id) on delete cascade,
  tipo          text not null check (tipo in ('CITACION', 'ACTA', 'SANCION', 'NO_COMPARECENCIA')),
  consecutivo   text not null unique,
  datos         jsonb,                  -- lo que decía el documento al imprimirlo
  generado_en   timestamptz not null default now(),
  generado_por  text
);
create index if not exists disc_docs_proceso_idx on public.disciplinarios_docs (proceso_id, tipo);

alter table public.disciplinarios_acta enable row level security;
alter table public.disciplinarios_docs enable row level security;

drop policy if exists disc_acta_sel on public.disciplinarios_acta;
create policy disc_acta_sel on public.disciplinarios_acta for select to authenticated
  using ( (select public.es_disc_ver()) );

drop policy if exists disc_docs_sel on public.disciplinarios_docs;
create policy disc_docs_sel on public.disciplinarios_docs for select to authenticated
  using ( (select public.es_disc_ver()) );

-- Se escribe solo por las funciones de abajo.
revoke insert, update, delete on public.disciplinarios_acta from authenticated;
revoke insert, update, delete on public.disciplinarios_docs from authenticated;

-- ---------- La papelería: encabezado de la empresa y firma de Gestión Humana ----------
-- Se toma de lo que ya configuró el certificado laboral (sql/93 + sql/94), para no tener
-- los datos de la empresa escritos en dos partes que después se contradicen.
create or replace function public.disc_papeleria()
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v jsonb; f jsonb;
begin
  if not public.es_disc_ver() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  select jsonb_build_object(
           'empresa', empresa_nombre, 'nit', empresa_nit,
           'ciudad', ciudad, 'telefono', telefono)
    into v from public.certificado_config where id = 1;

  select jsonb_build_object('nombre', nombre, 'cargo', cargo, 'firma', firma, 'alto', firma_alto)
    into f from public.certificado_firmantes
   where rol = 'GESTION_HUMANA' and vigente_hasta is null
   order by vigente_desde desc limit 1;

  return jsonb_build_object('ok', true,
    'empresa', coalesce(v, '{}'::jsonb),
    'firmante', coalesce(f, '{}'::jsonb));
end $fn$;
revoke all on function public.disc_papeleria() from public, anon;
grant execute on function public.disc_papeleria() to authenticated;

-- ---------- Leer el acta ----------
create or replace function public.disc_acta_leer(p_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v jsonb; d jsonb;
begin
  if not public.es_disc_ver() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado.');
  end if;
  select to_jsonb(a) into v from public.disciplinarios_acta a where a.proceso_id = p_id;
  select jsonb_agg(jsonb_build_object('tipo', tipo, 'consecutivo', consecutivo,
                                      'generado_en', generado_en, 'generado_por', generado_por)
                   order by generado_en desc)
    into d from public.disciplinarios_docs where proceso_id = p_id;
  return jsonb_build_object('ok', true, 'acta', v, 'docs', coalesce(d, '[]'::jsonb),
                            'puede_editar', public.es_disc_gestion());
end $fn$;
revoke all on function public.disc_acta_leer(bigint) from public, anon;
grant execute on function public.disc_acta_leer(bigint) to authenticated;

-- ---------- Guardar (se llama muchas veces: se escribe en vivo) ----------
-- Recibe un jsonb con solo lo que cambió. Lo que no venga, se deja como estaba: así el
-- autoguardado de un campo no borra lo que otro ya había escrito.
create or replace function public.disc_acta_guardar(p_id bigint, p_datos jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text; v_cerrada timestamptz;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana registran la diligencia.');
  end if;
  if not exists (select 1 from public.disciplinarios where id = p_id and anulado_en is null) then
    return jsonb_build_object('ok', false, 'error', 'No existe ese proceso, o está anulado.');
  end if;
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');

  select cerrada_en into v_cerrada from public.disciplinarios_acta where proceso_id = p_id;
  if v_cerrada is not null then
    return jsonb_build_object('ok', false, 'error',
      'El acta ya fue cerrada el ' || to_char(v_cerrada at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI')
      || '. Un acta cerrada no se modifica.');
  end if;

  insert into public.disciplinarios_acta as a (proceso_id, creado_por)
  values (p_id, v_correo)
  on conflict (proceso_id) do nothing;

  update public.disciplinarios_acta a set
    lugar              = coalesce(p_datos->>'lugar', a.lugar),
    dirige_nombre      = coalesce(p_datos->>'dirige_nombre', a.dirige_nombre),
    dirige_cargo       = coalesce(p_datos->>'dirige_cargo', a.dirige_cargo),
    dirige_cedula      = coalesce(p_datos->>'dirige_cedula', a.dirige_cedula),
    secretario_nombre  = coalesce(p_datos->>'secretario_nombre', a.secretario_nombre),
    acompanantes       = coalesce(p_datos->'acompanantes', a.acompanantes),
    acompanar_ofrecido = coalesce((p_datos->>'acompanar_ofrecido')::boolean, a.acompanar_ofrecido),
    hechos             = coalesce(p_datos->>'hechos', a.hechos),
    preguntas          = coalesce(p_datos->'preguntas', a.preguntas),
    version_trabajador = coalesce(p_datos->>'version_trabajador', a.version_trabajador),
    pruebas            = coalesce(p_datos->>'pruebas', a.pruebas),
    observaciones      = coalesce(p_datos->>'observaciones', a.observaciones),
    comparecio         = coalesce((p_datos->>'comparecio')::boolean, a.comparecio),
    no_comparecio_nota = coalesce(p_datos->>'no_comparecio_nota', a.no_comparecio_nota),
    firma_trabajador   = coalesce(p_datos->>'firma_trabajador', a.firma_trabajador),
    firma_trabajador_negada = coalesce((p_datos->>'firma_trabajador_negada')::boolean, a.firma_trabajador_negada),
    firma_negada_nota  = coalesce(p_datos->>'firma_negada_nota', a.firma_negada_nota),
    firma_dirige       = coalesce(p_datos->>'firma_dirige', a.firma_dirige),
    actualizado_en     = now()
  where a.proceso_id = p_id;

  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_acta_guardar(bigint, jsonb) from public, anon;
grant execute on function public.disc_acta_guardar(bigint, jsonb) to authenticated;

-- ---------- Cerrar: a partir de aquí el acta no se toca ----------
-- Al cerrar se registra también la fecha de la diligencia en el proceso, que es lo que
-- hace avanzar la etapa de CITADO a POR DECIDIR (la etapa se calcula, no se escribe).
create or replace function public.disc_acta_cerrar(p_id bigint, p_fecha date default null,
                                                   p_hora_ini time default null, p_hora_fin time default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare a public.disciplinarios_acta%rowtype; v_correo text; v_fecha date;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana cierran el acta.');
  end if;
  select * into a from public.disciplinarios_acta where proceso_id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Todavía no hay nada escrito en esta diligencia.');
  end if;
  if a.cerrada_en is not null then
    return jsonb_build_object('ok', false, 'error', 'El acta ya estaba cerrada.');
  end if;

  -- Lo mínimo que tiene que tener un acta para servir de algo
  if a.comparecio then
    if nullif(trim(coalesce(a.hechos, '')), '') is null then
      return jsonb_build_object('ok', false, 'error',
        'Falta escribir los hechos que se le imputan. Sin eso el acta no prueba que se le dijo de qué se le acusa.');
    end if;
    if nullif(trim(coalesce(a.version_trabajador, '')), '') is null then
      return jsonb_build_object('ok', false, 'error',
        'Falta la versión del trabajador. Es el descargo: es lo que se le estaba pidiendo.');
    end if;
    if a.firma_trabajador is null and not a.firma_trabajador_negada then
      return jsonb_build_object('ok', false, 'error',
        'Falta la firma del trabajador. Si se negó a firmar, márcalo: negarse es válido, pero tiene que constar.');
    end if;
  else
    if nullif(trim(coalesce(a.no_comparecio_nota, '')), '') is null then
      return jsonb_build_object('ok', false, 'error',
        'Escribe la constancia de por qué no se realizó la diligencia.');
    end if;
  end if;
  if nullif(trim(coalesce(a.dirige_nombre, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Falta quién dirigió la diligencia.');
  end if;

  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  update public.disciplinarios_acta
     set cerrada_en = now(), cerrada_por = v_correo, actualizado_en = now()
   where proceso_id = p_id;

  -- Si compareció, la diligencia ya ocurrió: eso mueve la etapa del proceso.
  if a.comparecio then
    v_fecha := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
    update public.disciplinarios
       set descargo_fecha     = coalesce(descargo_fecha, v_fecha),
           descargo_hora_ini  = coalesce(p_hora_ini, descargo_hora_ini),
           descargo_hora_fin  = coalesce(p_hora_fin, descargo_hora_fin),
           actualizado_en     = now()
     where id = p_id;
  end if;

  return jsonb_build_object('ok', true, 'comparecio', a.comparecio);
end $fn$;
revoke all on function public.disc_acta_cerrar(bigint, date, time, time) from public, anon;
grant execute on function public.disc_acta_cerrar(bigint, date, time, time) to authenticated;

-- ---------- Reabrir un acta cerrada (solo admin, y queda dicho) ----------
create or replace function public.disc_acta_reabrir(p_id bigint, p_nota text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_correo text;
begin
  if not (select public.es_admin()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración reabre un acta cerrada.');
  end if;
  if nullif(trim(coalesce(p_nota, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Escribe por qué se reabre: queda en el acta.');
  end if;
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');
  update public.disciplinarios_acta
     set cerrada_en = null, cerrada_por = null, actualizado_en = now(),
         observaciones = coalesce(observaciones || E'\n', '')
           || '[Reabierta el ' || to_char(now() at time zone 'America/Bogota', 'DD/MM/YYYY HH24:MI')
           || ' por ' || v_correo || ': ' || trim(p_nota) || ']'
   where proceso_id = p_id and cerrada_en is not null;
  if not found then return jsonb_build_object('ok', false, 'error', 'Esa acta no está cerrada.'); end if;
  return jsonb_build_object('ok', true);
end $fn$;
revoke all on function public.disc_acta_reabrir(bigint, text) from public, anon;
grant execute on function public.disc_acta_reabrir(bigint, text) to authenticated;

-- ---------- Registrar una impresión y entregar el consecutivo ----------
-- El consecutivo es por tipo y por año: CIT-2026-0001, ACT-2026-0001, …
create or replace function public.disc_doc_registrar(p_id bigint, p_tipo text, p_datos jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_pref text; v_anio int; v_n int; v_cons text; v_correo text;
begin
  if not public.es_disc_gestion() then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y Gestión Humana generan estos documentos.');
  end if;
  v_pref := case upper(coalesce(p_tipo, ''))
              when 'CITACION' then 'CIT' when 'ACTA' then 'ACT'
              when 'SANCION' then 'SAN' when 'NO_COMPARECENCIA' then 'NCP' end;
  if v_pref is null then
    return jsonb_build_object('ok', false, 'error', 'Tipo de documento desconocido.');
  end if;

  v_anio := extract(year from (now() at time zone 'America/Bogota'))::int;
  -- El consecutivo se toma del máximo ya usado ese año, no de un contador aparte:
  -- así no se desincroniza si alguna vez se borra una fila.
  select coalesce(max((regexp_replace(consecutivo, '^[A-Z]+-\d{4}-', ''))::int), 0) + 1
    into v_n
    from public.disciplinarios_docs
   where consecutivo like v_pref || '-' || v_anio || '-%';

  v_cons := v_pref || '-' || v_anio || '-' || lpad(v_n::text, 4, '0');
  v_correo := coalesce(auth.jwt() ->> 'email', 'sistema');

  insert into public.disciplinarios_docs (proceso_id, tipo, consecutivo, datos, generado_por)
  values (p_id, upper(p_tipo), v_cons, p_datos, v_correo);

  return jsonb_build_object('ok', true, 'consecutivo', v_cons, 'generado_por', v_correo);
end $fn$;
revoke all on function public.disc_doc_registrar(bigint, text, jsonb) from public, anon;
grant execute on function public.disc_doc_registrar(bigint, text, jsonb) to authenticated;

comment on table public.disciplinarios_acta is
  'La diligencia de descargos completa: hechos, preguntas, versión del trabajador, acompañantes y firmas. Se sella al cerrar.';
comment on table public.disciplinarios_docs is
  'Registro de cada documento impreso del proceso, con su consecutivo y una copia de lo que decía.';
