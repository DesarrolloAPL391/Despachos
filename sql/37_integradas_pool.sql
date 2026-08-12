-- 37: Pool "Integradas" ampliable por el admin.
-- Además del grupo fijo (parque_automotor.ruta = 'Integradas'), el admin puede HABILITAR
-- carros EXTRA que aparecerán como integrados en TODA ruta con número + I/II.
-- El carro CONSERVA su grupo original (NO se toca parque_automotor.ruta): solo se SUMA
-- al pool. Es permanente hasta que el admin lo quite. Sin flujo de aprobación: el admin
-- es quien da el aval al habilitarlo.

create table if not exists public.integradas_pool (
  numero_interno text primary key,
  nota           text,
  habilitado_por text,
  creado         timestamptz not null default now()
);

alter table public.integradas_pool enable row level security;

-- Lectura: cualquier usuario autenticado (el despachador necesita el set para el selector de móvil)
drop policy if exists integradas_pool_leer on public.integradas_pool;
create policy integradas_pool_leer on public.integradas_pool
  for select to authenticated using (true);

-- Escritura directa: solo admin (la vía normal son las RPC; esto es cinturón y tirantes)
drop policy if exists integradas_pool_admin on public.integradas_pool;
create policy integradas_pool_admin on public.integradas_pool
  for all to authenticated using (public.es_admin()) with check (public.es_admin());

-- ---- RPCs del panel (SECURITY DEFINER con guarda es_admin) ----

-- Listar: los EXTRA habilitados + datos del parque (móvil, placa, grupo original, estado)
create or replace function public.integradas_pool_listar()
returns table (
  numero_interno text, placa text, grupo text, estado text,
  marca text, modelo text, nota text, habilitado_por text, creado timestamptz
)
language sql security definer set search_path = public as $$
  select ip.numero_interno, pa.placa, pa.ruta as grupo, pa.estado,
         pa.marca, pa.modelo::text, ip.nota, ip.habilitado_por, ip.creado
  from public.integradas_pool ip
  left join public.parque_automotor pa on pa.numero_interno = ip.numero_interno
  order by ip.numero_interno;
$$;

-- Agregar un carro al pool (solo admin). Valida que el móvil exista en el parque.
create or replace function public.integradas_pool_agregar(p_numero text, p_nota text default null)
returns json
language plpgsql security definer set search_path = public as $$
declare v_num text; v_quien text;
begin
  if not public.es_admin() then raise exception 'Solo un administrador puede habilitar integradas.'; end if;
  v_num := trim(p_numero);
  if v_num is null or v_num = '' then raise exception 'Móvil vacío.'; end if;
  if not exists (select 1 from public.parque_automotor where numero_interno = v_num) then
    raise exception 'El móvil % no existe en el parque automotor.', v_num;
  end if;
  v_quien := coalesce(auth.jwt()->>'email', auth.uid()::text, 'admin');
  insert into public.integradas_pool (numero_interno, nota, habilitado_por)
  values (v_num, nullif(trim(coalesce(p_nota, '')), ''), v_quien)
  on conflict (numero_interno) do update
    set nota = excluded.nota, habilitado_por = excluded.habilitado_por, creado = now();
  return json_build_object('ok', true, 'numero', v_num);
end; $$;

-- Quitar del pool (solo admin)
create or replace function public.integradas_pool_quitar(p_numero text)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public.es_admin() then raise exception 'Solo un administrador puede quitar integradas.'; end if;
  delete from public.integradas_pool where numero_interno = trim(p_numero);
  return json_build_object('ok', true);
end; $$;

grant execute on function public.integradas_pool_listar() to authenticated;
grant execute on function public.integradas_pool_agregar(text, text) to authenticated;
grant execute on function public.integradas_pool_quitar(text) to authenticated;
