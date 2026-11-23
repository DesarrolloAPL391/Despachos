-- 201: "¿Quién te reemplaza?" muestra primero SOLO las personas de su área (pedido del 23/11/2026):
--   "que pregunte si es de otra area y que lo selecione".
-- La lista ya venía con su área primero (sql/170). Ahora cada persona trae 'm' = es de su misma área,
-- para que la página parta la lista sin adivinar: arriba los de su área y, de última, "Es de otra área…",
-- que abre una segunda lista con las demás (montarReemplazo en config.js).
-- Solo se AGREGA la llave 'm': el orden y lo demás quedan igual, así que las páginas publicadas siguen
-- funcionando sin cambios. Sin área registrada, nadie es "de su área" (m = false) y sale la lista completa.
--
-- Deshacer: volver a la definición de sql/170 (sin la llave 'm').

set lock_timeout = '5s';

create or replace function public._reemplazo_opciones(p_cedula text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object('n', btrim(p.nombre), 'c', p.cargo, 'a', p.area,
                                               'm', coalesce(yo.area is not null and p.area = yo.area, false))
           order by (p.area is not distinct from yo.area) desc, p.area nulls last, btrim(p.nombre)), '[]'::jsonb)
    from public.perfilsociodemografico p
    left join lateral (select area from public.perfilsociodemografico where cedula = p_cedula limit 1) yo on true
   where p.estado = 'ACTIVO' and p.tipo = 'ADMINISTRATIVO' and p.cedula is distinct from p_cedula
     and nullif(btrim(p.nombre), '') is not null;
$function$;
