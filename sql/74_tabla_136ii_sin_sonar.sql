-- 74: Tabla de puesto 136II con los MISMOS atributos que las demás (clon de despachos),
--     pero marcada como SIN SONAR: se registra el despacho (móvil, conductor, hora, despachador,
--     GPS) pero NO se envía a SONAR. Se crea INACTIVA (activo=false) para no exponerla en
--     producción hasta que el front con la lógica sin-SONAR esté publicado.

-- 1) Bandera para tablas que NO despachan a SONAR (se registra local, sin enviar).
alter table public.tablas_despacho add column if not exists sin_sonar boolean not null default false;

-- 2) Crear la tabla física con estructura, FKs, RLS base y grants (helper del proyecto).
select public.setup_tabla_puesto('t_136ii', 'Nutibara');

-- 3) Igualar a t_130: FK de auditor + políticas de auditor/afiliado + guardas de horario/sesión.
alter table public.t_136ii drop constraint if exists t_136ii_auditor_id_fkey;
alter table public.t_136ii
  add constraint t_136ii_auditor_id_fkey foreign key (auditor_id) references public.auditores(id) on delete set null;

drop policy if exists pp_sel_aud on public.t_136ii;
create policy pp_sel_aud on public.t_136ii for select to authenticated
  using ((select public.es_auditor()));
drop policy if exists pp_upd_aud on public.t_136ii;
create policy pp_upd_aud on public.t_136ii for update to authenticated
  using ((select public.es_auditor()) and ruta_id = any((select public.rutas_auditor())::bigint[]))
  with check (true);
drop policy if exists pp_sel_afil on public.t_136ii;
create policy pp_sel_afil on public.t_136ii for select to authenticated
  using ((select public.es_afiliado()));

drop policy if exists require_en_horario on public.t_136ii;
create policy require_en_horario on public.t_136ii as restrictive for all to authenticated
  using ((select public.en_horario())) with check ((select public.en_horario()));
drop policy if exists require_sesion_vigente on public.t_136ii;
create policy require_sesion_vigente on public.t_136ii as restrictive for all to authenticated
  using ((select public.es_sesion_vigente())) with check ((select public.es_sesion_vigente()));

-- 4) Registrar la tabla (INACTIVA por ahora; sin_sonar = true). delete+insert (idempotente).
delete from public.tablas_despacho where tabla = 't_136ii';
insert into public.tablas_despacho (tabla, label, puesto, activo, sin_sonar)
values ('t_136ii', '136II', 'Nutibara', false, true);
