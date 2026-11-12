-- 184: LAS RUTAS 134 MADRUGADA Y 134Y MADRUGADA A LOS MONITORES DE CONTROL (12/11/2026).
--
-- Ningún monitor tenía esas dos rutas, así que sus despachos (y sus lecturas de QR) solo los veía administración.
-- Decisión del usuario (12/11): se le agregan a los monitores que ya tienen la 134 (→ 134 MADRUGADA) y la 134Y
-- (→ 134Y MADRUGADA). auditores.rutas es texto separado por comas; rutas_auditor() lo cruza con rutas.nombre
-- sin importar mayúsculas. No se toca nada más.

update public.auditores a
   set rutas = btrim(coalesce(a.rutas, '')) || ', 134 MADRUGADA'
 where exists (select 1 from unnest(string_to_array(coalesce(a.rutas, ''), ',')) s(n) where lower(btrim(s.n)) = '134')
   and not exists (select 1 from unnest(string_to_array(coalesce(a.rutas, ''), ',')) s(n) where lower(btrim(s.n)) = '134 madrugada');

update public.auditores a
   set rutas = btrim(coalesce(a.rutas, '')) || ', 134Y MADRUGADA'
 where exists (select 1 from unnest(string_to_array(coalesce(a.rutas, ''), ',')) s(n) where lower(btrim(s.n)) = '134y')
   and not exists (select 1 from unnest(string_to_array(coalesce(a.rutas, ''), ',')) s(n) where lower(btrim(s.n)) = '134y madrugada');
