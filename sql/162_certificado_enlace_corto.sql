-- ============================================================================================
-- 162 · CERTIFICADO LABORAL — enlace corto para WhatsApp
--
-- El enlace firmado de Supabase mide más de 400 caracteres, muestra un dominio que nadie
-- reconoce y lleva la cédula en la ruta: en WhatsApp parece un virus. Ahora el mensaje lleva
-- un enlace corto a una página nuestra (certificado.html#CODIGO) con el logo de la empresa y el
-- botón para ver o descargar el PDF.
--
--   · El código son 10 caracteres al azar (≈58 bits): no se adivina ni se recorre.
--   · Vence cuando vence el enlace firmado (wa_dias). Vencido, la página dice a quién pedirlo.
--   · La página es pública (anon), pero solo entrega el PDF de ESE código; no lista nada.
--   · Queda registrado cuántas veces se abrió y cuándo fue la primera, para saber si llegó.
--
-- El enlace firmado se sigue creando en la app (la base no puede firmarlo) y se guarda aquí;
-- solo se entrega a quien tenga el código. Se aplica sobre sql/145.
-- ============================================================================================

alter table public.certificados_expedidos
  add column if not exists codigo         text,
  add column if not exists codigo_vence   timestamptz,
  add column if not exists enlace_firmado text,
  add column if not exists abierto_veces  int not null default 0,
  add column if not exists abierto_primero timestamptz,
  add column if not exists abierto_ultimo  timestamptz;

create unique index if not exists certificados_expedidos_codigo_uq
  on public.certificados_expedidos (codigo) where codigo is not null;

-- 1) Talento Humano: registra el envío y saca el código --------------------------------------
-- Si el mismo certificado se vuelve a mandar, conserva el código (el que ya lo recibió sigue
-- entrando) y le renueva el enlace y el vencimiento.
create or replace function public.certificado_enlace_crear(
  p_consecutivo text, p_archivo text, p_telefono text, p_url text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_yo   text := lower(coalesce(auth.email(), ''));
  v_dias int  := coalesce((select wa_dias from public.certificado_config where id = 1), 7);
  v_abc  text := 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- sin 0/O, 1/l/I
  v_cod  text;
  v_b    bytea;
  v_n    int;
begin
  if not public.es_talento_humano() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para enviar certificados.');
  end if;
  if coalesce(p_url, '') !~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/sign/certificados/' then
    return jsonb_build_object('ok', false, 'error', 'Enlace del documento no válido.');
  end if;

  select codigo into v_cod from public.certificados_expedidos where consecutivo = p_consecutivo;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'No existe ese certificado: ' || coalesce(p_consecutivo, ''));
  end if;

  -- Código nuevo solo si no tenía. gen_random_uuid trae 122 bits al azar sin extensiones.
  while v_cod is null loop
    v_b := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_cod := '';
    for i in 0..9 loop
      v_cod := v_cod || substr(v_abc, 1 + get_byte(v_b, i) % length(v_abc), 1);
    end loop;
    if exists (select 1 from public.certificados_expedidos where codigo = v_cod) then v_cod := null; end if;
  end loop;

  update public.certificados_expedidos
     set codigo         = v_cod,
         codigo_vence   = now() + make_interval(days => v_dias),
         enlace_firmado = p_url,
         archivo        = coalesce(nullif(trim(p_archivo), ''), archivo),
         enviado_wa     = true,
         enviado_a      = coalesce(nullif(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), ''), enviado_a),
         enviado_en     = now()
   where consecutivo = p_consecutivo;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n = 1, 'codigo', v_cod, 'dias', v_dias, 'por', v_yo);
end $$;
revoke all on function public.certificado_enlace_crear(text, text, text, text) from public, anon;
grant execute on function public.certificado_enlace_crear(text, text, text, text) to authenticated;

-- 2) La página pública: entrega el PDF de ese código ------------------------------------------
-- Devuelve solo lo que la página muestra: el nombre de pila (no la cédula), el consecutivo,
-- hasta cuándo sirve y a quién llamar. Con el código vencido no entrega el enlace.
create or replace function public.certificado_enlace_abrir(p_codigo text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  r   public.certificados_expedidos%rowtype;
  c   public.certificado_config%rowtype;
  v_nombre text;
  v_contacto jsonb;
begin
  select * into c from public.certificado_config where id = 1;
  v_contacto := jsonb_build_object(
    'telefono', trim(concat_ws(' Ext. ', nullif(c.telefono, ''), nullif(c.telefono_ext, ''))),
    'correo', c.correo_contacto, 'empresa', c.empresa_nombre);

  if coalesce(p_codigo, '') !~ '^[A-Za-z0-9]{10}$' then
    return jsonb_build_object('ok', false, 'motivo', 'NO_EXISTE', 'contacto', v_contacto);
  end if;
  select * into r from public.certificados_expedidos where codigo = p_codigo;
  if not found or r.enlace_firmado is null then
    return jsonb_build_object('ok', false, 'motivo', 'NO_EXISTE', 'contacto', v_contacto);
  end if;
  if r.codigo_vence < now() then
    return jsonb_build_object('ok', false, 'motivo', 'VENCIDO', 'vencio', r.codigo_vence, 'contacto', v_contacto);
  end if;

  update public.certificados_expedidos
     set abierto_veces = abierto_veces + 1,
         abierto_primero = coalesce(abierto_primero, now()),
         abierto_ultimo = now()
   where id = r.id;

  -- Nombre de pila: en Colombia van primero los dos apellidos ("PEREZ GOMEZ JUAN CARLOS").
  v_nombre := initcap(lower(coalesce(
    nullif(array_to_string((regexp_split_to_array(trim(r.nombre), '\s+'))[3:], ' '), ''), r.nombre)));

  return jsonb_build_object('ok', true,
    'url', r.enlace_firmado, 'consecutivo', r.consecutivo, 'nombre', v_nombre,
    'expedido', r.expedido_en, 'vence', r.codigo_vence, 'contacto', v_contacto);
end $$;
revoke all on function public.certificado_enlace_abrir(text) from public;
grant execute on function public.certificado_enlace_abrir(text) to anon, authenticated;
