-- Re-applies the LISTEN/NOTIFY triggers that browseterm-db's init.py autogenerate drops.
-- Powers live container-status → SSE and save-status → SSE in browseterm-server.

-- 1) container status changes
CREATE OR REPLACE FUNCTION notify_container_status_change() RETURNS TRIGGER AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM pg_notify('container_status_change', json_build_object(
      'id', NEW.id, 'user_id', NEW.user_id, 'name', NEW.name,
      'old_status', OLD.status, 'new_status', NEW.status, 'updated_at', NEW.updated_at)::text);
  END IF; RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS container_status_change_trigger ON containers;
CREATE TRIGGER container_status_change_trigger AFTER UPDATE ON containers
  FOR EACH ROW EXECUTE FUNCTION notify_container_status_change();

-- 2) save/snapshot status changes
CREATE OR REPLACE FUNCTION notify_container_save_status_change() RETURNS TRIGGER AS $$
BEGIN
  IF OLD.save_status IS DISTINCT FROM NEW.save_status THEN
    PERFORM pg_notify('container_save_status_change', json_build_object(
      'id', NEW.id, 'user_id', NEW.user_id, 'name', NEW.name,
      'save_status', NEW.save_status, 'saved_image', NEW.saved_image,
      'save_error', NEW.save_error, 'updated_at', NEW.updated_at)::text);
  END IF; RETURN NEW;
END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS container_save_status_change_trigger ON containers;
CREATE TRIGGER container_save_status_change_trigger AFTER UPDATE ON containers
  FOR EACH ROW EXECUTE FUNCTION notify_container_save_status_change();
