-- 58: El AFILIADO ve las preventivas de SUS carros (solo lectura), para saber
-- quién debe ir a revisión y quién no. Se amplía la policy de SELECT de la
-- tabla preventivas (creada en sql/57). El botón de notificar por WhatsApp NO
-- aplica al afiliado (el RPC preventiva_notificada sigue guardado a admin/despachador).

drop policy if exists preventivas_select on public.preventivas;
create policy preventivas_select on public.preventivas
  for select to authenticated
  using (
        (select public.es_admin())
     or (select public.es_despachador())
     or ( (select public.es_afiliado())
          and interno = any((select public.mis_moviles_afiliado())::text[]) )
  );
