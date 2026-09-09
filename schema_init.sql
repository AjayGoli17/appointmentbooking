-- ==============================================================================
-- Appointment Booking System - Database Initialization & Schema Definition
-- ==============================================================================

-- 1. Enable btree_gist for exclusion constraints
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 2. Doctors Registry
CREATE TABLE IF NOT EXISTS doctors (
    doctor_id VARCHAR(100) PRIMARY KEY,
    doctor_name VARCHAR(255) NOT NULL,
    specialty VARCHAR(255) NOT NULL,
    calendar_id VARCHAR(255) NOT NULL,
    timezone VARCHAR(100) NOT NULL DEFAULT 'Asia/Kolkata',
    working_days JSONB NOT NULL DEFAULT '[1,2,3,4,5,6]'::jsonb, -- 1=Mon, 6=Sat
    working_hours JSONB NOT NULL DEFAULT '{"start": "09:00", "end": "17:00"}'::jsonb,
    slot_duration_minutes INT NOT NULL DEFAULT 30 CHECK (slot_duration_minutes > 0),
    buffer_minutes INT NOT NULL DEFAULT 0 CHECK (buffer_minutes >= 0),
    booking_cutoff_minutes INT NOT NULL DEFAULT 60 CHECK (booking_cutoff_minutes >= 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed default doctors if table is freshly created
INSERT INTO doctors (doctor_id, doctor_name, specialty, calendar_id, timezone, working_days, working_hours, slot_duration_minutes, buffer_minutes, booking_cutoff_minutes, is_active)
VALUES 
    ('dr_smith', 'Dr. John Smith', 'Cardiology', 'dr_smith@apexhealth.example.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, TRUE),
    ('dr_emily', 'Dr. Emily Davis', 'Pediatrics', 'dr_emily@apexhealth.example.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, TRUE),
    ('dr_robert', 'Dr. Robert Wilson', 'General Medicine', 'dr_robert@apexhealth.example.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, TRUE)
ON CONFLICT (doctor_id) DO NOTHING;

-- 3. Doctor Leave & Unavailability
CREATE TABLE IF NOT EXISTS doctor_unavailability (
    id SERIAL PRIMARY KEY,
    doctor_id VARCHAR(100) NOT NULL REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    reason VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_unavail_range CHECK (end_time > start_time)
);

-- 4. Appointments Table
CREATE TABLE IF NOT EXISTS appointments (
    appointment_id SERIAL PRIMARY KEY,
    customer_name VARCHAR(255) NOT NULL,
    phone VARCHAR(50) NOT NULL,
    doctor_id VARCHAR(100) NOT NULL REFERENCES doctors(doctor_id) ON DELETE RESTRICT,
    service VARCHAR(255) NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED', 'NO_SHOW', 'CANCELLED', 'EXPIRED')),
    calendar_event_id VARCHAR(255),
    expires_at TIMESTAMPTZ,
    reminder_3d_sent BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_1d_sent BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_4h_sent BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_1h_sent BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_3d_claimed_at TIMESTAMPTZ,
    reminder_1d_claimed_at TIMESTAMPTZ,
    reminder_4h_claimed_at TIMESTAMPTZ,
    reminder_1h_claimed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_appt_range CHECK (end_time > start_time),
    CONSTRAINT chk_appt_expires CHECK (status != 'PENDING' OR expires_at IS NOT NULL)
);

-- 5. Webhook Inbound Message Deduplication & Rate Limiting
CREATE TABLE IF NOT EXISTS processed_messages (
    message_id VARCHAR(128) PRIMARY KEY,
    channel VARCHAR(50) NOT NULL DEFAULT 'whatsapp',
    sender VARCHAR(100) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 6. Appointment State Audit Logging
CREATE TABLE IF NOT EXISTS appointment_audit_logs (
    log_id SERIAL PRIMARY KEY,
    appointment_id INT REFERENCES appointments(appointment_id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL,
    actor VARCHAR(100) NOT NULL,
    previous_state JSONB,
    new_state JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. Performance & Query Indexes
CREATE INDEX IF NOT EXISTS idx_appointments_phone ON appointments(phone);
CREATE INDEX IF NOT EXISTS idx_appointments_doc_time ON appointments(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_appointments_status ON appointments(status);
CREATE INDEX IF NOT EXISTS idx_appointments_pending_exp ON appointments(status, expires_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_appointments_cal_event ON appointments(calendar_event_id) WHERE calendar_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_doctor_unavail_doc_time ON doctor_unavailability(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_processed_messages_sender_time ON processed_messages(sender, processed_at);
CREATE INDEX IF NOT EXISTS idx_appointment_audit_appt ON appointment_audit_logs(appointment_id);

-- 8. Authoritative Active Appointment Overlap Exclusion Constraint (Bug #1, #2)
-- Excludes all active bookings. Expired pending holds are transitioned to EXPIRED so they do not block new bookings.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'no_overlapping_confirmed_appointments'
    ) THEN
        ALTER TABLE appointments DROP CONSTRAINT no_overlapping_confirmed_appointments;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'no_overlapping_active_appointments'
    ) THEN
        ALTER TABLE appointments 
        ADD CONSTRAINT no_overlapping_active_appointments 
        EXCLUDE USING gist (
            doctor_id WITH =,
            tstzrange(start_time, end_time) WITH &&
        ) WHERE (status IN ('PENDING', 'CONFIRMED', 'RESCHEDULED', 'ARRIVED'));
    END IF;
END $$;

-- 9. Automatic Audit Logging Trigger (Bug #20, #21)
CREATE OR REPLACE FUNCTION log_appointment_audit()
RETURNS TRIGGER AS $$
DECLARE
    v_actor VARCHAR(100);
    v_action VARCHAR(50);
BEGIN
    v_actor := COALESCE(current_setting('app.current_actor', true), 'system');
    
    IF TG_OP = 'INSERT' THEN
        v_action := 'CREATE_' || NEW.status;
        INSERT INTO appointment_audit_logs (appointment_id, action, actor, previous_state, new_state, created_at)
        VALUES (NEW.appointment_id, v_action, v_actor, NULL, to_jsonb(NEW), NOW());
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status IS DISTINCT FROM NEW.status THEN
            v_action := 'STATUS_' || OLD.status || '_TO_' || NEW.status;
        ELSIF OLD.start_time IS DISTINCT FROM NEW.start_time OR OLD.end_time IS DISTINCT FROM NEW.end_time THEN
            v_action := 'RESCHEDULED';
        ELSE
            v_action := 'UPDATE';
        END IF;
        INSERT INTO appointment_audit_logs (appointment_id, action, actor, previous_state, new_state, created_at)
        VALUES (NEW.appointment_id, v_action, v_actor, to_jsonb(OLD), to_jsonb(NEW), NOW());
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO appointment_audit_logs (appointment_id, action, actor, previous_state, new_state, created_at)
        VALUES (OLD.appointment_id, 'DELETE', v_actor, to_jsonb(OLD), NULL, NOW());
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appointment_audit ON appointments;
CREATE TRIGGER trg_appointment_audit
AFTER INSERT OR UPDATE OR DELETE ON appointments
FOR EACH ROW EXECUTE FUNCTION log_appointment_audit();

-- 10. Automatic Updated At Timestamp Trigger
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appointments_updated_at ON appointments;
CREATE TRIGGER trg_appointments_updated_at
BEFORE UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 11. Maintenance Helper Functions for Cleanup & Retention (Bug #10, #30, #60)
CREATE OR REPLACE FUNCTION expire_stale_pending_appointments()
RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    UPDATE appointments
    SET status = 'EXPIRED', updated_at = NOW()
    WHERE status = 'PENDING' AND expires_at <= NOW();
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- 12. PostgreSQL vs Google Calendar Reconciliation View (Bug #8)
CREATE OR REPLACE VIEW vw_appointment_reconciliation AS
SELECT 
    a.appointment_id,
    a.customer_name,
    a.phone,
    a.doctor_id,
    a.status,
    a.start_time,
    a.end_time,
    a.calendar_event_id,
    d.calendar_id,
    d.doctor_name,
    CASE 
        WHEN a.status IN ('CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED') AND (a.calendar_event_id IS NULL OR a.calendar_event_id = '') THEN 'MISSING_CALENDAR_EVENT'
        WHEN a.status = 'CANCELLED' AND a.calendar_event_id IS NOT NULL AND a.calendar_event_id != '' THEN 'CANCELLED_WITH_ACTIVE_CALENDAR_ID'
        WHEN a.status = 'PENDING' AND a.expires_at <= NOW() THEN 'STALE_PENDING_HOLD'
        ELSE 'HEALTHY'
    END AS sync_status,
    a.updated_at
FROM appointments a
JOIN doctors d ON a.doctor_id = d.doctor_id;

-- 13. Durable Integration Operations Tracking
CREATE TABLE IF NOT EXISTS integration_operations (
    operation_id SERIAL PRIMARY KEY,
    appointment_id INT REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    operation_type VARCHAR(50) NOT NULL, -- e.g., 'GCAL_CREATE', 'GCAL_UPDATE', 'GCAL_DELETE', 'WHATSAPP_SEND'
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING', -- 'PENDING', 'SUCCESS', 'FAILED'
    attempt_count INT NOT NULL DEFAULT 0,
    last_attempt_at TIMESTAMPTZ,
    next_retry_at TIMESTAMPTZ,
    error_details JSONB,
    payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_integration_ops_status_retry ON integration_operations(status, next_retry_at) WHERE status = 'FAILED';
CREATE INDEX IF NOT EXISTS idx_integration_ops_appt ON integration_operations(appointment_id);

CREATE OR REPLACE FUNCTION set_integration_op_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_integration_ops_updated_at ON integration_operations;
CREATE TRIGGER trg_integration_ops_updated_at
BEFORE UPDATE ON integration_operations
FOR EACH ROW EXECUTE FUNCTION set_integration_op_updated_at();

-- 14. Outbox Pattern for Calendar Operations
CREATE OR REPLACE FUNCTION queue_calendar_integration_ops()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Queue GCAL_CREATE only when status=CONFIRMED and no event_id yet (direct create may not have run)
        IF NEW.status = 'CONFIRMED' AND (NEW.calendar_event_id IS NULL OR NEW.calendar_event_id = '') THEN
            INSERT INTO integration_operations (appointment_id, operation_type, status, payload)
            VALUES (NEW.appointment_id, 'GCAL_CREATE', 'PENDING', to_jsonb(NEW));
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        -- CANCELLED: queue GCAL_DELETE only if there was a calendar event to delete
        IF OLD.status != 'CANCELLED' AND NEW.status = 'CANCELLED'
           AND OLD.calendar_event_id IS NOT NULL AND OLD.calendar_event_id != '' THEN
            INSERT INTO integration_operations (appointment_id, operation_type, status, payload)
            VALUES (NEW.appointment_id, 'GCAL_DELETE', 'PENDING', to_jsonb(NEW));
        -- Time changed: queue GCAL_UPDATE only if a calendar event exists
        ELSIF (OLD.start_time IS DISTINCT FROM NEW.start_time OR OLD.end_time IS DISTINCT FROM NEW.end_time)
              AND NEW.status IN ('CONFIRMED', 'RESCHEDULED')
              AND NEW.calendar_event_id IS NOT NULL AND NEW.calendar_event_id != '' THEN
            INSERT INTO integration_operations (appointment_id, operation_type, status, payload)
            VALUES (NEW.appointment_id, 'GCAL_UPDATE', 'PENDING', to_jsonb(NEW));
        -- PENDING->CONFIRMED and no event_id: queue GCAL_CREATE (direct create may have failed)
        ELSIF OLD.status = 'PENDING' AND NEW.status = 'CONFIRMED'
              AND (NEW.calendar_event_id IS NULL OR NEW.calendar_event_id = '') THEN
            INSERT INTO integration_operations (appointment_id, operation_type, status, payload)
            VALUES (NEW.appointment_id, 'GCAL_CREATE', 'PENDING', to_jsonb(NEW));
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_queue_calendar_ops ON appointments;
CREATE TRIGGER trg_queue_calendar_ops
AFTER INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION queue_calendar_integration_ops();

-- 15. Phone Normalization Trigger
CREATE OR REPLACE FUNCTION normalize_phone_number()
RETURNS TRIGGER AS $$
BEGIN
    NEW.phone = regexp_replace(NEW.phone, '[^0-9]', '', 'g');
    IF length(NEW.phone) = 10 THEN
        NEW.phone = '91' || NEW.phone;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_normalize_phone ON appointments;
CREATE TRIGGER trg_normalize_phone
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION normalize_phone_number();

-- 16. Prevent Historical Appointments Trigger
CREATE OR REPLACE FUNCTION prevent_past_appointments()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Allow a tiny grace period of 5 minutes for latency
        IF NEW.start_time < (NOW() - INTERVAL '5 minutes') THEN
            RAISE EXCEPTION 'Cannot book an appointment in the past: %', NEW.start_time;
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        IF (NEW.start_time != OLD.start_time) AND (NEW.start_time < (NOW() - INTERVAL '5 minutes')) THEN
            RAISE EXCEPTION 'Cannot reschedule an appointment to the past: %', NEW.start_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_past_appts ON appointments;
CREATE TRIGGER trg_prevent_past_appts
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION prevent_past_appointments();


-- 17. Formalize integration_operations status constraint
-- Ensures no unknown status can silently enter the system
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_integration_op_status'
    ) THEN
        ALTER TABLE integration_operations
        ADD CONSTRAINT chk_integration_op_status
        CHECK (status IN ('PENDING', 'IN_PROGRESS', 'SUCCESS', 'FAILED', 'PERMANENTLY_FAILED', 'SUPERSEDED'));
    END IF;
END $$;

-- 18. Add lease_expires_at for deterministic IN_PROGRESS recovery
-- (set when operation is claimed; recovery is safe when NOW() > lease_expires_at)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='integration_operations' AND column_name='lease_expires_at') THEN
        ALTER TABLE integration_operations ADD COLUMN lease_expires_at TIMESTAMPTZ;
    END IF;
END $$;

-- 19. Index for efficient recovery query
CREATE INDEX IF NOT EXISTS idx_integration_ops_recovery
  ON integration_operations(status, last_attempt_at)
  WHERE status = 'IN_PROGRESS';

-- 20. Index for same-appointment supersession
CREATE INDEX IF NOT EXISTS idx_integration_ops_appt_status
  ON integration_operations(appointment_id, status, operation_id);

-- 21. View: permanent failures visible to operators
CREATE OR REPLACE VIEW v_permanently_failed_operations AS
SELECT
    io.operation_id,
    io.appointment_id,
    io.operation_type,
    io.status,
    io.attempt_count,
    io.last_attempt_at,
    io.error_details,
    io.created_at,
    a.customer_name,
    a.phone,
    a.status AS appt_status,
    a.calendar_event_id,
    d.doctor_name
FROM integration_operations io
JOIN appointments a ON io.appointment_id = a.appointment_id
JOIN doctors d ON a.doctor_id = d.doctor_id
WHERE io.status IN ('PERMANENTLY_FAILED', 'SUPERSEDED')
ORDER BY io.last_attempt_at DESC;

-- 22. View: stale IN_PROGRESS (potential crash indicators)
CREATE OR REPLACE VIEW v_stale_in_progress_operations AS
SELECT
    io.operation_id,
    io.appointment_id,
    io.operation_type,
    io.status,
    io.attempt_count,
    io.last_attempt_at,
    io.lease_expires_at,
    io.created_at,
    a.customer_name,
    a.status AS appt_status
FROM integration_operations io
JOIN appointments a ON io.appointment_id = a.appointment_id
WHERE io.status = 'IN_PROGRESS'
  AND io.last_attempt_at < NOW() - INTERVAL '10 minutes'
ORDER BY io.last_attempt_at;

-- 23. Reminder sent fields renamed semantics comment
-- reminder_*_sent = TRUE means: WhatsApp API *accepted* the message (not confirmed delivery)
-- Delivery confirmation requires Meta webhooks (status callbacks)
COMMENT ON COLUMN appointments.reminder_3d_sent IS 'TRUE = WhatsApp API accepted the 3-day reminder. Not guaranteed patient delivery.';
COMMENT ON COLUMN appointments.reminder_1d_sent IS 'TRUE = WhatsApp API accepted the 1-day reminder. Not guaranteed patient delivery.';
COMMENT ON COLUMN appointments.reminder_4h_sent IS 'TRUE = WhatsApp API accepted the 4-hour reminder. Not guaranteed patient delivery.';
COMMENT ON COLUMN appointments.reminder_1h_sent IS 'TRUE = WhatsApp API accepted the 1-hour reminder. Not guaranteed patient delivery.';
