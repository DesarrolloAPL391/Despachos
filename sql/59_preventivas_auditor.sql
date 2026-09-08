-- 59: El AUDITOR ve TODAS las preventivas (solo lectura) para auditar si el
-- despachador ya notificó al conductor (notificado_por / notificado_en). No se
-- limita por ruta a propósito: la etiqueta preventivas.ruta agrupa varias rutas
-- y el objetivo es que "auditen todo". El botón de notificar NO aplica al auditor
-- (el RPC preventiva_notificada sigue guardado a admin/despachador).

drop policy if exists preventivas_select on public.preventivas;
create policy preventivas_select on public.preventivas
  for select to authenticated
  using (
        (select public.es_admin())
     or (select public.es_despachador())
     or (select public.es_auditor())
     or ( (select public.es_afiliado())
          and interno = any((select public.mis_moviles_afiliado())::text[]) )
  );
