-- 47: Fix "permission denied for function control_laureles".
-- La pantalla "Control Laureles" llama a public.control_laureles(date) (wrapper SECURITY DEFINER
-- que valida auth.uid() y delega en _control_laureles_core). En algún momento estas funciones se
-- recrearon (DROP+CREATE) perdiendo el GRANT a `authenticated`, y el rol de la app dejó de poder
-- ejecutarlas -> "permission denied".
--
-- IMPORTANTE: al recrear cualquiera de estas funciones, incluir SIEMPRE su GRANT (o re-correr esto).
grant execute on function public.control_laureles(date)            to authenticated, service_role;
grant execute on function public._control_laureles_core(date)      to authenticated, service_role;

-- Forzar a PostgREST a recargar el esquema (por si quedó cacheado sin el permiso).
notify pgrst, 'reload schema';
