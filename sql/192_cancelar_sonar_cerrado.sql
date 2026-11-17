-- 192: con sql/191 la cancelacion pasa al monitor (cancelar_despacho). Aqui se cierra la puerta vieja: ningun usuario con
-- sesion puede llamar directo a cancelar_sonar (la usa solo cancelar_despacho, que corre como su dueno).
-- Se aplica AL PUBLICAR la version de la app que ya usa cancelar_despacho: la version anterior llama a cancelar_sonar
-- directo y desde ese momento recibira "permiso denegado" (que es justo lo que se busca para el despachador).
set lock_timeout = '5s';
revoke execute on function public.cancelar_sonar(text, text, text) from public, anon, authenticated;
