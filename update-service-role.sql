-- Handshake update: let the notify function read the database.
-- This project doesn't give new tables to any role automatically, so the notify function's
-- server key (service_role) got "permission denied for table predictions" and no
-- notification ever went out. Safe to re-run.
grant usage on schema public to service_role;
grant select, insert, update, delete on
  public.profiles, public.predictions, public.prediction_invites, public.push_subscriptions,
  public.app_push_devices, public.settlements, public.settlement_requests
to service_role;
