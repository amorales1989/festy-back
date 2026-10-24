-- =============================================================================
-- Festy · Migración 13: cuentas de demostración.
--
-- Una cuenta con app_metadata.demo = true (solo lo puede poner un
-- administrador, con la API de administración de GoTrue) no puede cambiar su
-- contraseña ni su email: ni desde la app, ni con "olvidé mi contraseña", ni
-- llamando a GoTrue directamente. Así la demo compartida no se puede secuestrar.
-- Para cambiarle la clave: quitar la marca (admin), cambiarla y volver a marcarla.
-- =============================================================================

create or replace function public.proteger_cuenta_demo()
returns trigger language plpgsql set search_path = '' as $$
begin
  if coalesce(old.raw_app_meta_data->>'demo', '') = 'true'
     and coalesce(new.raw_app_meta_data->>'demo', '') = 'true'
     and (new.encrypted_password is distinct from old.encrypted_password
          or new.email is distinct from old.email
          or new.email_change is distinct from old.email_change
          or new.phone is distinct from old.phone) then
    raise exception 'La cuenta de demostración no permite cambiar la contraseña ni el email.' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger proteger_cuenta_demo before update on auth.users
  for each row execute function public.proteger_cuenta_demo();

revoke execute on function public.proteger_cuenta_demo() from public, anon, authenticated;
