-- =============================================================================
-- Festy · Migración 9: disparo de notificaciones push.
-- Cada minuto, si hay notificaciones sin enviar por push, se llama a la Edge
-- Function "enviar-push". La URL y el secreto se guardan en Supabase Vault:
--   select vault.create_secret('https://<proyecto>.supabase.co/functions/v1/enviar-push', 'festy_push_url');
--   select vault.create_secret('<secreto largo>', 'festy_push_secreto');
-- Sin esos secretos la función no hace nada (entorno local o push no configurado).
-- =============================================================================
create extension if not exists pg_net with schema extensions;

create or replace function public.disparar_push()
returns void language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secreto text;
begin
  if not exists (select 1 from public.notificaciones where push_enviada_at is null and creado_at > now() - interval '2 days') then
    return;
  end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'festy_push_url';
  select decrypted_secret into v_secreto from vault.decrypted_secrets where name = 'festy_push_secreto';
  if v_url is null or v_secreto is null then return; end if;
  perform net.http_post(url := v_url, headers := jsonb_build_object('Content-Type', 'application/json', 'x-festy-secreto', v_secreto), body := '{}'::jsonb);
end $$;
revoke execute on function public.disparar_push() from public, anon, authenticated;

do $$
begin
  perform cron.schedule('festy_push', '* * * * *', 'select public.disparar_push()');
exception when others then
  raise warning 'pg_cron no disponible (%): programar disparar_push externamente.', sqlerrm;
end $$;
