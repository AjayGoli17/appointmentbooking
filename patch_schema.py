import re

with open('schema_init.sql', 'r') as f:
    content = f.read()

# Fix 1: Outbox CANCELLED transition
cancel_old = """        -- ── CANCELLED transition ──
        -- Queue GCAL_DELETE only if there is a known Calendar event to delete.
        ELSIF OLD.status != 'CANCELLED' AND NEW.status = 'CANCELLED'
              AND OLD.calendar_event_id IS NOT NULL AND OLD.calendar_event_id != '' THEN
            INSERT INTO integration_operations
                (appointment_id, operation_type, status, payload, created_at, updated_at)
            VALUES
                (NEW.appointment_id, 'GCAL_DELETE', 'PENDING', to_jsonb(NEW), NOW(), NOW());"""

cancel_new = """        -- ── CANCELLED transition ──
        -- Always queue GCAL_DELETE. This supersedes any pending GCAL_CREATE.
        -- If calendar_event_id is NULL, Calendar Worker will handle gracefully.
        ELSIF OLD.status != 'CANCELLED' AND NEW.status = 'CANCELLED' THEN
            INSERT INTO integration_operations
                (appointment_id, operation_type, status, payload, created_at, updated_at)
            VALUES
                (NEW.appointment_id, 'GCAL_DELETE', 'PENDING', to_jsonb(NEW), NOW(), NOW());"""

# Fix 2: Outbox TIME CHANGED transition
time_old = """        -- ── TIME CHANGED on active appointment ──
        -- Queue GCAL_UPDATE if times changed and a Calendar event exists.
        ELSIF (OLD.start_time IS DISTINCT FROM NEW.start_time OR OLD.end_time IS DISTINCT FROM NEW.end_time)
              AND NEW.status IN ('CONFIRMED', 'RESCHEDULED')
              AND NEW.calendar_event_id IS NOT NULL AND NEW.calendar_event_id != '' THEN
            INSERT INTO integration_operations
                (appointment_id, operation_type, status, payload, created_at, updated_at)
            VALUES
                (NEW.appointment_id, 'GCAL_UPDATE', 'PENDING', to_jsonb(NEW), NOW(), NOW());"""

time_new = """        -- ── TIME CHANGED on active appointment ──
        ELSIF (OLD.start_time IS DISTINCT FROM NEW.start_time OR OLD.end_time IS DISTINCT FROM NEW.end_time)
              AND NEW.status IN ('CONFIRMED', 'RESCHEDULED') THEN
            IF NEW.calendar_event_id IS NOT NULL AND NEW.calendar_event_id != '' THEN
                INSERT INTO integration_operations
                    (appointment_id, operation_type, status, payload, created_at, updated_at)
                VALUES
                    (NEW.appointment_id, 'GCAL_UPDATE', 'PENDING', to_jsonb(NEW), NOW(), NOW());
            ELSE
                -- Update pending GCAL_CREATE payload to new times
                -- Avoid blindly creating GCAL_UPDATE before Calendar event exists
                UPDATE integration_operations
                SET payload = to_jsonb(NEW), updated_at = NOW()
                WHERE appointment_id = NEW.appointment_id
                  AND operation_type = 'GCAL_CREATE'
                  AND status IN ('PENDING', 'FAILED');
            END IF;"""

if cancel_old in content and time_old in content:
    content = content.replace(cancel_old, cancel_new)
    content = content.replace(time_old, time_new)
    with open('schema_init.sql', 'w') as f:
        f.write(content)
    print("schema_init.sql patched successfully!")
else:
    print("Could not find blocks to patch in schema_init.sql")
