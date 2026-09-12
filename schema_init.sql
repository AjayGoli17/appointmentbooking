-- ==============================================================================
-- Appointment Booking System - Database Initialization & Schema Definition
-- ==============================================================================
-- Prompt 1 Architecture:
--   PostgreSQL   = appointment authority (exclusion constraint decides conflicts)
--   integration_operations = outbox / external Calendar side-effect queue
--   Calendar Worker = ONLY component performing Google Calendar mutations
-- ==============================================================================

-- ──────────────────────────────────────────────────────────────────────────────
-- 1. Enable btree_gist for exclusion constraints
-- ──────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ──────────────────────────────────────────────────────────────────────────────
-- 2. Doctors Registry
-- ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS doctors (
    doctor_id              VARCHAR(100)  PRIMARY KEY,
    doctor_name            VARCHAR(255)  NOT NULL,
    specialty              VARCHAR(255)  NOT NULL,
    -- calendar_id must be non-empty; shared calendars are explicitly allowed.
    -- Multiple doctors may share one calendar_id if the clinic operates that way.
    calendar_id            VARCHAR(255)  NOT NULL CHECK (length(trim(calendar_id)) > 0),
    -- IANA timezone string – validated at application layer; DB enforces non-empty.
    timezone               VARCHAR(100)  NOT NULL DEFAULT 'Asia/Kolkata'
                               CHECK (length(trim(timezone)) > 0),
    -- working_days: JSON array of ISO weekday integers 0 (Sun) – 6 (Sat).
    -- DB enforces: must be an array, each element in [0,6], no duplicates enforced at DB (app validates).
    working_days           JSONB         NOT NULL DEFAULT '[1,2,3,4,5,6]'::jsonb
                               CHECK (jsonb_typeof(working_days) = 'array'),
    -- working_hours: JSON object {start:"HH:MM", end:"HH:MM"} with start < end.
    -- DB enforces: must be object with both keys present, start strictly before end.
    working_hours          JSONB         NOT NULL DEFAULT '{"start": "09:00", "end": "17:00"}'::jsonb
                               CHECK (
                                   jsonb_typeof(working_hours) = 'object'
                                   AND working_hours ? 'start'
                                   AND working_hours ? 'end'
                                   AND (working_hours->>'start') ~ '^([01]\d|2[0-3]):[0-5]\d$'
                                   AND (working_hours->>'end')   ~ '^([01]\d|2[0-3]):[0-5]\d$'
                                   AND (working_hours->>'start') < (working_hours->>'end')
                               ),
    -- slot_duration_minutes: the canonical booking unit. All appointments must
    -- align to multiples of this value relative to working_hours.start.
    -- The PostgreSQL exclusion constraint enforces the actual blocked interval
    -- (start_time to end_time), which the application must set to
    -- start_time + slot_duration_minutes + buffer_minutes for effective blocking.
    slot_duration_minutes  INT           NOT NULL DEFAULT 30  CHECK (slot_duration_minutes > 0),
    -- buffer_minutes: dead time added AFTER the appointment slot.
    -- The exclusion range stored in appointments must be
    --   [start_time, start_time + slot_duration_minutes + buffer_minutes)
    -- so that the buffer is DB-enforced, not just application-enforced.
    buffer_minutes         INT           NOT NULL DEFAULT 0   CHECK (buffer_minutes >= 0),
    booking_cutoff_minutes INT           NOT NULL DEFAULT 60  CHECK (booking_cutoff_minutes >= 0),
    is_active              BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Seed default doctors if table is freshly created
INSERT INTO doctors (
    doctor_id, doctor_name, specialty, calendar_id, timezone,
    working_days, working_hours, slot_duration_minutes, buffer_minutes,
    booking_cutoff_minutes, is_active
)
VALUES
    ('dr_smith',  'Dr. John Smith',     'Cardiology',        'dr_smith@apexhealth.example.com',  'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, TRUE),
    ('dr_emily',  'Dr. Emily Davis',    'Pediatrics',        'dr_emily@apexhealth.example.com',  'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, TRUE),
    ('dr_robert', 'Dr. Robert Wilson',  'General Medicine',  'dr_robert@apexhealth.example.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, TRUE)
ON CONFLICT (doctor_id) DO NOTHING;

-- ──────────────────────────────────────────────────────────────────────────────
-- 3. Doctor Leave & Unavailability
-- ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS doctor_unavailability (
    id          SERIAL        PRIMARY KEY,
    doctor_id   VARCHAR(100)  NOT NULL REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    start_time  TIMESTAMPTZ   NOT NULL,
    end_time    TIMESTAMPTZ   NOT NULL,
    reason      VARCHAR(255),
    created_at  TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_unavail_range CHECK (end_time > start_time)
);

-- ──────────────────────────────────────────────────────────────────────────────
-- 4. Appointments Table
-- ──────────────────────────────────────────────────────────────────────────────
-- APPOINTMENT SOURCE ENUM (finding #62)
-- Records the origin channel of the appointment.
-- Values: WHATSAPP (patient via WhatsApp AI agent)
--         DASHBOARD (receptionist via web dashboard)
--         API (external system via REST)
--         SYSTEM (automated/internal, e.g. import)
--         IMPORT (bulk data migration)
-- Source is informational; it does NOT substitute for authenticated actor identity.
-- Authentication/authorization is handled separately (Prompt 4).
CREATE TABLE IF NOT EXISTS appointments (
    appointment_id    SERIAL        PRIMARY KEY,
    customer_name     VARCHAR(255)  NOT NULL,
    phone             VARCHAR(50)   NOT NULL,
    doctor_id         VARCHAR(100)  NOT NULL REFERENCES doctors(doctor_id) ON DELETE RESTRICT,
    service           VARCHAR(255)  NOT NULL,
    -- Appointment time semantics (finding #84, #85, #86):
    --   start_time: exact start of patient appointment
    --   end_time:   start_time + slot_duration_minutes + buffer_minutes
    --               The buffer is stored inside end_time so the DB exclusion
    --               constraint enforces the full blocked interval automatically.
    -- Example: 30-min slot + 10-min buffer → end_time = start_time + 40 min.
    -- This means "next bookable slot" = end_time, not end_time + buffer.
    -- Application MUST compute end_time = start_time + (slot_duration + buffer).
    start_time        TIMESTAMPTZ   NOT NULL,
    end_time          TIMESTAMPTZ   NOT NULL,
    -- STATUS STATE MACHINE (finding #101–108):
    -- Legal transitions are enforced by validate_appointment_state_transition().
    -- See that function for the transition table.
    -- RESCHEDULED semantic: appointment retains CONFIRMED after reschedule.
    -- RESCHEDULED is a transient signal state only — it transitions immediately
    -- back to CONFIRMED when the new time is saved. The DB stores CONFIRMED;
    -- any workflow setting RESCHEDULED must immediately follow with CONFIRMED.
    -- This resolves the ambiguity: active rescheduled appointments ARE CONFIRMED.
    status            VARCHAR(50)   NOT NULL DEFAULT 'PENDING'
                          CHECK (status IN ('PENDING','CONFIRMED','RESCHEDULED','ARRIVED','COMPLETED','NO_SHOW','CANCELLED','EXPIRED')),
    -- calendar_event_id: set by Calendar Worker ONLY after successful GCal CREATE.
    -- Never set directly by business workflows.
    -- Partial unique constraint ensures same GCal event cannot map to 2 appointments.
    calendar_event_id VARCHAR(255),
    -- appointment_source: stable origin of this appointment (finding #62)
    appointment_source VARCHAR(50)  NOT NULL DEFAULT 'WHATSAPP'
                          CHECK (appointment_source IN ('WHATSAPP','DASHBOARD','API','SYSTEM','IMPORT')),
    expires_at        TIMESTAMPTZ,
    reminder_3d_sent         BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_1d_sent         BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_4h_sent         BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_1h_sent         BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_3d_claimed_at   TIMESTAMPTZ,
    reminder_1d_claimed_at   TIMESTAMPTZ,
    reminder_4h_claimed_at   TIMESTAMPTZ,
    reminder_1h_claimed_at   TIMESTAMPTZ,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_appt_range   CHECK (end_time > start_time),
    CONSTRAINT chk_appt_expires CHECK (status != 'PENDING' OR expires_at IS NOT NULL)
);

COMMENT ON COLUMN appointments.end_time IS
  'Stores start_time + slot_duration + buffer_minutes. The buffer is encoded in end_time so the DB exclusion constraint enforces the full blocked interval (slot + buffer).';
COMMENT ON COLUMN appointments.status IS
  'State machine: PENDING→CONFIRMED→(ARRIVED|CANCELLED|RESCHEDULED→CONFIRMED). See validate_appointment_state_transition() for allowed transitions.';
COMMENT ON COLUMN appointments.calendar_event_id IS
  'Set ONLY by Calendar Worker after successful GCAL_CREATE. Business workflows must never write this column directly.';
COMMENT ON COLUMN appointments.appointment_source IS
  'Origin channel: WHATSAPP, DASHBOARD, API, SYSTEM, IMPORT. Informational only; not a security identity claim.';
COMMENT ON COLUMN appointments.reminder_3d_sent IS 'TRUE = WhatsApp API accepted the 3-day reminder. Not guaranteed patient delivery.';
COMMENT ON COLUMN appointments.reminder_1d_sent IS 'TRUE = WhatsApp API accepted the 1-day reminder. Not guaranteed patient delivery.';
COMMENT ON COLUMN appointments.reminder_4h_sent IS 'TRUE = WhatsApp API accepted the 4-hour reminder. Not guaranteed patient delivery.';
COMMENT ON COLUMN appointments.reminder_1h_sent IS 'TRUE = WhatsApp API accepted the 1-hour reminder. Not guaranteed patient delivery.';

-- Add appointment_source column to existing tables without breaking them
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'appointments' AND column_name = 'appointment_source'
    ) THEN
        ALTER TABLE appointments
            ADD COLUMN appointment_source VARCHAR(50) NOT NULL DEFAULT 'WHATSAPP'
            CHECK (appointment_source IN ('WHATSAPP','DASHBOARD','API','SYSTEM','IMPORT'));
    END IF;
END $$;

-- ──────────────────────────────────────────────────────────────────────────────
-- 5. Webhook Inbound Message Deduplication & Rate Limiting
-- ──────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS processed_messages (
    message_id   VARCHAR(128) PRIMARY KEY,
    channel      VARCHAR(50)  NOT NULL DEFAULT 'whatsapp',
    sender       VARCHAR(100) NOT NULL,
    processed_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ──────────────────────────────────────────────────────────────────────────────
-- 6. Appointment State Audit Logging (finding #58, #59, #60)
-- ──────────────────────────────────────────────────────────────────────────────
-- appointment_id uses ON DELETE SET NULL to preserve audit history when an
-- appointment is deleted. Audit history must survive the appointment record.
CREATE TABLE IF NOT EXISTS appointment_audit_logs (
    log_id          SERIAL        PRIMARY KEY,
    appointment_id  INT           REFERENCES appointments(appointment_id) ON DELETE SET NULL,
    action          VARCHAR(100)  NOT NULL,
    actor           VARCHAR(100)  NOT NULL,
    -- Actor establishment semantics (finding #58):
    --   System/background workers call: SET LOCAL app.current_actor = 'system:<worker_name>';
    --   Dashboard operations will use server-side session identity (Prompt 4).
    --   DO NOT trust client-supplied identity headers as proof of identity.
    --   The 'system:' prefix is reserved for internal actors.
    previous_state  JSONB,
    new_state       JSONB,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE appointment_audit_logs IS
  'Audit log of business-significant appointment changes. appointment_id = NULL means the appointment was hard-deleted (unusual; preserved for forensics).';
COMMENT ON COLUMN appointment_audit_logs.actor IS
  'Authenticated or system-declared actor. System workers set app.current_actor = ''system:<worker>''. Dashboard will set server-side session identity (Prompt 4).';

-- ──────────────────────────────────────────────────────────────────────────────
-- 7. Performance & Query Indexes
-- ──────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_appointments_phone           ON appointments(phone);
CREATE INDEX IF NOT EXISTS idx_appointments_doc_time        ON appointments(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_appointments_status          ON appointments(status);
CREATE INDEX IF NOT EXISTS idx_appointments_pending_exp     ON appointments(status, expires_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_appointments_source          ON appointments(appointment_source);
CREATE INDEX IF NOT EXISTS idx_doctor_unavail_doc_time      ON doctor_unavailability(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_processed_messages_sender_time ON processed_messages(sender, processed_at);
CREATE INDEX IF NOT EXISTS idx_appointment_audit_appt       ON appointment_audit_logs(appointment_id);
CREATE INDEX IF NOT EXISTS idx_appointment_audit_created    ON appointment_audit_logs(created_at);

-- ──────────────────────────────────────────────────────────────────────────────
-- 8. Partial Unique Index for calendar_event_id (finding #56)
-- ──────────────────────────────────────────────────────────────────────────────
-- Ensures one GCal event cannot be associated with two appointments.
-- NULL calendar_event_id is allowed (appointment not yet synced to Calendar).
-- Note: calendar_id uniqueness is NOT enforced here because the system explicitly
-- supports a shared-calendar model (multiple doctors can share one calendar_id).
-- Shared-calendar support is preserved intentionally.
CREATE UNIQUE INDEX IF NOT EXISTS uidx_appointments_cal_event_id
    ON appointments(calendar_event_id)
    WHERE calendar_event_id IS NOT NULL;

-- ──────────────────────────────────────────────────────────────────────────────
-- 9. Authoritative PostgreSQL Booking Exclusion Constraint (finding #2, #84–86)
-- ──────────────────────────────────────────────────────────────────────────────
-- This constraint IS the final booking lock. Google Calendar is NOT involved.
--
-- Slot + Buffer semantics:
--   end_time = start_time + slot_duration_minutes + buffer_minutes
--   The exclusion range is [start_time, end_time), which covers the full
--   blocked interval (slot + buffer). No separate buffer arithmetic needed.
--
-- The WHERE clause excludes terminal states so that CANCELLED/EXPIRED/COMPLETED
-- appointments do not block future bookings for the same slot.
--
-- Concurrency guarantee: btree_gist + EXCLUDE prevents two simultaneous INSERTs
-- from both succeeding. One will get a PostgreSQL constraint violation error.
-- The application must handle that error and return a conflict message.
DO $$
BEGIN
    -- Remove old constraint name if it exists (migration safety)
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

-- ──────────────────────────────────────────────────────────────────────────────
-- 10. Slot Alignment Validation Function (finding #84–86)
-- ──────────────────────────────────────────────────────────────────────────────
-- Validates that a requested time aligns to the slot cadence for a doctor.
-- Called by workflow BEFORE INSERT/UPDATE; also enforced by the
-- enforce_slot_alignment trigger below for belt-and-suspenders assurance.
CREATE OR REPLACE FUNCTION validate_slot_alignment(
    p_doctor_id     VARCHAR(100),
    p_start_time    TIMESTAMPTZ,
    p_end_time      TIMESTAMPTZ
) RETURNS TEXT AS $$
-- Returns NULL if valid, error message string if invalid.
DECLARE
    v_doc           doctors%ROWTYPE;
    v_open_min      INT;
    v_close_min     INT;
    v_slot_total    INT;  -- slot_duration + buffer = total blocked minutes
    v_req_start_min INT;  -- minutes since midnight in doctor's LOCAL timezone
    v_offset_min    INT;  -- minutes since working_hours.start
BEGIN
    SELECT * INTO v_doc FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RETURN 'Doctor not found: ' || p_doctor_id;
    END IF;

    -- Parse working_hours
    v_open_min  := (split_part(v_doc.working_hours->>'start', ':', 1)::INT * 60)
                 + split_part(v_doc.working_hours->>'start', ':', 2)::INT;
    v_close_min := (split_part(v_doc.working_hours->>'end', ':', 1)::INT * 60)
                 + split_part(v_doc.working_hours->>'end', ':', 2)::INT;

    v_slot_total := v_doc.slot_duration_minutes + v_doc.buffer_minutes;

    -- Duration check: end_time must equal start_time + (slot_duration + buffer) minutes exactly.
    IF extract(epoch FROM (p_end_time - p_start_time)) / 60 != v_slot_total THEN
        RETURN format(
            'end_time must be exactly start_time + %s minutes (slot_duration=%s + buffer=%s). Got %s minutes.',
            v_slot_total,
            v_doc.slot_duration_minutes,
            v_doc.buffer_minutes,
            extract(epoch FROM (p_end_time - p_start_time)) / 60
        );
    END IF;

    -- Slot alignment check: extract the LOCAL hour and minute of the start time
    -- using the doctor's IANA timezone (e.g. 'Asia/Kolkata').
    -- Correct for any timezone including half-hour offsets (IST +5:30, NST +5:45, etc.).
    -- Previous implementation used UTC extraction which was incorrect for non-UTC timezones.
    v_req_start_min := (extract(hour   FROM p_start_time AT TIME ZONE v_doc.timezone)::INT * 60)
                     + extract(minute  FROM p_start_time AT TIME ZONE v_doc.timezone)::INT;
    v_offset_min := (v_req_start_min - v_open_min + 1440) % 1440;

    IF (v_offset_min % v_slot_total) != 0 THEN
        RETURN format(
            'Requested time does not align to %s-minute slot cadence for %s. Times must align to multiples of %s minutes after %s.',
            v_slot_total, v_doc.doctor_name, v_slot_total, v_doc.working_hours->>'start'
        );
    END IF;

    RETURN NULL;  -- valid
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION validate_slot_alignment IS
  'Returns NULL if slot is valid, or an error string. Checks: (1) duration = slot_duration+buffer_minutes exactly, (2) start_time aligns to slot cadence relative to working_hours.start in the doctor''s local timezone (not UTC). Application calls this before INSERT; exclusion constraint is the ultimate race-safety authority.';



-- ──────────────────────────────────────────────────────────────────────────────
-- 10b. Enforce Slot Alignment Trigger (belt-and-suspenders, finding #84–86)
-- ──────────────────────────────────────────────────────────────────────────────
-- Calls validate_slot_alignment() BEFORE INSERT or UPDATE of start_time/end_time.
-- This means the DB boundary rejects unaligned slots even if the application
-- layer forgets to call validate_slot_alignment() explicitly.
-- Fires only for PENDING/CONFIRMED/RESCHEDULED inserts and relevant updates.
-- Does not fire for terminal state rows (CANCELLED/EXPIRED/COMPLETED/NO_SHOW)
-- to allow admin cleanup without alignment constraints.
CREATE OR REPLACE FUNCTION enforce_slot_alignment()
RETURNS TRIGGER AS $$
DECLARE
    v_err TEXT;
BEGIN
    -- Only validate on INSERT, or on UPDATE when times changed.
    IF TG_OP = 'UPDATE' AND
       NEW.start_time IS NOT DISTINCT FROM OLD.start_time AND
       NEW.end_time   IS NOT DISTINCT FROM OLD.end_time THEN
        RETURN NEW;  -- no time change; skip
    END IF;

    -- Skip validation for terminal states (admin operations).
    IF NEW.status IN ('CANCELLED', 'EXPIRED', 'COMPLETED', 'NO_SHOW') THEN
        RETURN NEW;
    END IF;

    v_err := validate_slot_alignment(NEW.doctor_id, NEW.start_time, NEW.end_time);
    IF v_err IS NOT NULL THEN
        RAISE EXCEPTION 'Slot alignment error: %', v_err;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION enforce_slot_alignment IS
  'Trigger function: calls validate_slot_alignment() before INSERT/UPDATE. Ensures DB boundary rejects unaligned slots. Skips terminal states and rows where times did not change.';

DROP TRIGGER IF EXISTS trg_enforce_slot_alignment ON appointments;
CREATE TRIGGER trg_enforce_slot_alignment
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION enforce_slot_alignment();

-- ──────────────────────────────────────────────────────────────────────────────
-- 11. Appointment State Transition Guard (finding #101–108)

-- ──────────────────────────────────────────────────────────────────────────────
-- ALL workflows must use this function / call transitions through this guard.
-- Returns NULL if transition is allowed, error message if not.
--
-- Legal transition table:
--   PENDING   -> CONFIRMED   (patient confirms hold)
--   PENDING   -> EXPIRED     (automatic expiry via maintenance job)
--   PENDING   -> CANCELLED   (patient or staff cancels before confirming)
--   CONFIRMED -> ARRIVED     (patient checked in)
--   CONFIRMED -> RESCHEDULED (transition state; must be followed by CONFIRMED)
--   CONFIRMED -> CANCELLED   (patient or staff cancels confirmed booking)
--   CONFIRMED -> NO_SHOW     (patient did not arrive)
--   CONFIRMED -> COMPLETED   (appointment concluded without ARRIVED step)
--   RESCHEDULED -> CONFIRMED (rescheduled to new time; becomes CONFIRMED)
--   RESCHEDULED -> CANCELLED (cancelled during reschedule)
--   ARRIVED   -> COMPLETED   (appointment finished)
--   ARRIVED   -> NO_SHOW     (edge case: marked arrived then absent)
--   ARRIVED   -> CANCELLED   (cancellation after arrival, rare)
--   COMPLETED -> (none)      terminal state
--   NO_SHOW   -> (none)      terminal state
--   CANCELLED -> (none)      terminal state
--   EXPIRED   -> (none)      terminal state
--
-- RESCHEDULED semantics clarification (finding #101):
--   RESCHEDULED is a TRANSIENT state used only to signal a reschedule operation
--   in the audit log and integration_operations trigger. After rescheduling,
--   the appointment MUST be in CONFIRMED status. Business workflows should
--   atomically move CONFIRMED → CONFIRMED (at new time) and only ever write
--   RESCHEDULED as an intermediate step in a single transaction if needed.
--   The canonical post-reschedule state stored in the DB is CONFIRMED.
CREATE OR REPLACE FUNCTION validate_appointment_state_transition(
    p_from_status VARCHAR(50),
    p_to_status   VARCHAR(50)
) RETURNS TEXT AS $$
BEGIN
    -- Same state is always allowed (idempotent updates)
    IF p_from_status = p_to_status THEN
        RETURN NULL;
    END IF;

    CASE p_from_status
        WHEN 'PENDING' THEN
            IF p_to_status IN ('CONFIRMED', 'EXPIRED', 'CANCELLED') THEN
                RETURN NULL;
            END IF;
        WHEN 'CONFIRMED' THEN
            IF p_to_status IN ('ARRIVED', 'RESCHEDULED', 'CANCELLED', 'NO_SHOW', 'COMPLETED') THEN
                RETURN NULL;
            END IF;
        WHEN 'RESCHEDULED' THEN
            IF p_to_status IN ('CONFIRMED', 'CANCELLED') THEN
                RETURN NULL;
            END IF;
        WHEN 'ARRIVED' THEN
            IF p_to_status IN ('COMPLETED', 'NO_SHOW', 'CANCELLED') THEN
                RETURN NULL;
            END IF;
        WHEN 'COMPLETED'  THEN NULL;  -- terminal
        WHEN 'NO_SHOW'    THEN NULL;  -- terminal
        WHEN 'CANCELLED'  THEN NULL;  -- terminal
        WHEN 'EXPIRED'    THEN NULL;  -- terminal
        ELSE NULL;
    END CASE;

    RETURN format(
        'Invalid appointment state transition: %s -> %s. See validate_appointment_state_transition() for allowed transitions.',
        p_from_status,
        p_to_status
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION validate_appointment_state_transition IS
  'Central state machine guard. Returns NULL if allowed, error string if not. All workflows must respect these transitions.';

-- Trigger that enforces state transitions at the DB level
CREATE OR REPLACE FUNCTION enforce_appointment_state_transition()
RETURNS TRIGGER AS $$
DECLARE
    v_err TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
        v_err := validate_appointment_state_transition(OLD.status, NEW.status);
        IF v_err IS NOT NULL THEN
            RAISE EXCEPTION '%', v_err;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_state_transition ON appointments;
CREATE TRIGGER trg_enforce_state_transition
BEFORE UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION enforce_appointment_state_transition();

-- ──────────────────────────────────────────────────────────────────────────────
-- 12. Automatic Updated_At Timestamp Trigger
-- ──────────────────────────────────────────────────────────────────────────────
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

-- ──────────────────────────────────────────────────────────────────────────────
-- 13. Audit Logging Trigger (finding #58, #59, #60)
-- ──────────────────────────────────────────────────────────────────────────────
-- Improved audit trigger:
--  - Records full previous and new row for business-significant changes
--  - Skips "metadata churn" updates (only updated_at / reminder_claimed_at changed)
--    to reduce audit volume while preserving important changes
--  - Actor is set via SET LOCAL app.current_actor = 'system:<name>' or
--    SET LOCAL app.current_actor = 'dashboard:<session_id>'  (Prompt 4 will
--    wire the dashboard session identity server-side; Prompt 1 establishes the
--    mechanism so the DB is compatible).
CREATE OR REPLACE FUNCTION log_appointment_audit()
RETURNS TRIGGER AS $$
DECLARE
    v_actor  VARCHAR(100);
    v_action VARCHAR(100);
    v_is_metadata_only BOOLEAN;
BEGIN
    -- Actor resolution (finding #58):
    -- Workflows and workers set app.current_actor at the session level.
    -- System workers use 'system:<worker_name>' convention.
    -- Fallback to 'system:unknown' rather than empty string for clarity.
    v_actor := COALESCE(
        NULLIF(trim(current_setting('app.current_actor', true)), ''),
        'system:unknown'
    );

    IF TG_OP = 'INSERT' THEN
        v_action := 'CREATE_' || NEW.status;
        INSERT INTO appointment_audit_logs
            (appointment_id, action, actor, previous_state, new_state, created_at)
        VALUES
            (NEW.appointment_id, v_action, v_actor, NULL, to_jsonb(NEW), NOW());
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        -- Determine action type
        IF OLD.status IS DISTINCT FROM NEW.status THEN
            v_action := 'STATUS_' || OLD.status || '_TO_' || NEW.status;
        ELSIF OLD.start_time IS DISTINCT FROM NEW.start_time
           OR OLD.end_time   IS DISTINCT FROM NEW.end_time THEN
            v_action := 'TIME_CHANGED';
        ELSIF OLD.calendar_event_id IS DISTINCT FROM NEW.calendar_event_id THEN
            v_action := 'CALENDAR_EVENT_SYNCED';
        ELSE
            v_action := 'UPDATE';
        END IF;

        -- Skip metadata-only updates (finding #59, #60):
        -- If the ONLY columns that changed are: updated_at, reminder_*_claimed_at
        -- then this is a maintenance/heartbeat update with no business significance.
        v_is_metadata_only := (
            OLD.status              = NEW.status                AND
            OLD.start_time          = NEW.start_time            AND
            OLD.end_time            = NEW.end_time              AND
            OLD.customer_name       = NEW.customer_name         AND
            OLD.phone               = NEW.phone                 AND
            OLD.doctor_id           = NEW.doctor_id             AND
            OLD.service             = NEW.service               AND
            OLD.calendar_event_id IS NOT DISTINCT FROM NEW.calendar_event_id AND
            OLD.appointment_source  = NEW.appointment_source    AND
            OLD.expires_at          IS NOT DISTINCT FROM NEW.expires_at AND
            OLD.reminder_3d_sent    = NEW.reminder_3d_sent      AND
            OLD.reminder_1d_sent    = NEW.reminder_1d_sent      AND
            OLD.reminder_4h_sent    = NEW.reminder_4h_sent      AND
            OLD.reminder_1h_sent    = NEW.reminder_1h_sent
        );

        -- Always log business-significant changes; skip pure metadata churn.
        -- Reminder *_sent flag changes ARE business-significant (reminder was sent).
        -- Reminder *_claimed_at changes alone are metadata churn (skip).
        IF NOT v_is_metadata_only THEN
            -- For STATUS changes and time changes, record full rows.
            -- For CALENDAR_EVENT_SYNCED, record only the calendar_event_id delta.
            IF v_action = 'CALENDAR_EVENT_SYNCED' THEN
                INSERT INTO appointment_audit_logs
                    (appointment_id, action, actor, previous_state, new_state, created_at)
                VALUES (
                    NEW.appointment_id, v_action, v_actor,
                    jsonb_build_object('calendar_event_id', OLD.calendar_event_id),
                    jsonb_build_object('calendar_event_id', NEW.calendar_event_id),
                    NOW()
                );
            ELSE
                INSERT INTO appointment_audit_logs
                    (appointment_id, action, actor, previous_state, new_state, created_at)
                VALUES
                    (NEW.appointment_id, v_action, v_actor, to_jsonb(OLD), to_jsonb(NEW), NOW());
            END IF;
        END IF;
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO appointment_audit_logs
            (appointment_id, action, actor, previous_state, new_state, created_at)
        VALUES
            (OLD.appointment_id, 'DELETE', v_actor, to_jsonb(OLD), NULL, NOW());
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appointment_audit ON appointments;
CREATE TRIGGER trg_appointment_audit
AFTER INSERT OR UPDATE OR DELETE ON appointments
FOR EACH ROW EXECUTE FUNCTION log_appointment_audit();

-- ──────────────────────────────────────────────────────────────────────────────
-- 14. Phone Normalization Trigger
-- ──────────────────────────────────────────────────────────────────────────────
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

-- ──────────────────────────────────────────────────────────────────────────────
-- 15. Prevent Historical Appointments Trigger
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION prevent_past_appointments()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
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

-- ──────────────────────────────────────────────────────────────────────────────
-- 16. Integration Operations (Outbox) Table (finding #14, #15, #16–20)
-- ──────────────────────────────────────────────────────────────────────────────
-- This table is the SOLE mechanism for scheduling external Calendar operations.
-- Business workflows (WhatsApp agent, Dashboard) NEVER call Google Calendar directly.
-- They only modify PostgreSQL. The DB trigger queues integration_operations entries.
-- The Calendar Worker (Workflow 04) claims, executes, and marks operations.
--
-- HISTORY RETENTION (finding #14):
--   appointment_id uses ON DELETE SET NULL, NOT CASCADE.
--   This preserves integration history (proof that Calendar was synced) even
--   when an appointment is hard-deleted (unusual case).
--   The operation row becomes an orphan (appointment_id = NULL) which is
--   intentional — it shows Calendar events were created/deleted for that slot.
CREATE TABLE IF NOT EXISTS integration_operations (
    operation_id      SERIAL        PRIMARY KEY,
    appointment_id    INT           REFERENCES appointments(appointment_id) ON DELETE SET NULL,
    operation_type    VARCHAR(50)   NOT NULL,
    -- Status values (finding #15):
    --   PENDING          = waiting to be claimed by a worker
    --   IN_PROGRESS      = claimed; lease expires at lease_expires_at
    --   SUCCESS          = completed successfully
    --   FAILED           = failed; will retry if attempt_count < max_attempts
    --   PERMANENTLY_FAILED = max retries exceeded; requires manual intervention
    --   SUPERSEDED       = a newer operation for same appointment makes this obsolete
    status            VARCHAR(50)   NOT NULL DEFAULT 'PENDING',
    -- Lease semantics (finding #15):
    --   When a worker claims an operation it sets:
    --     status = IN_PROGRESS
    --     lease_expires_at = NOW() + INTERVAL '10 minutes'  (configurable)
    --     last_attempt_at = NOW()
    --     attempt_count = attempt_count + 1
    --   A crashed worker strands the operation in IN_PROGRESS.
    --   Recovery query: status = 'IN_PROGRESS' AND lease_expires_at < NOW()
    --   treats it as claimable again (safe because lease expired = worker dead).
    lease_expires_at  TIMESTAMPTZ,
    attempt_count     INT           NOT NULL DEFAULT 0,
    max_attempts      INT           NOT NULL DEFAULT 5,
    last_attempt_at   TIMESTAMPTZ,
    next_retry_at     TIMESTAMPTZ,
    error_details     JSONB,
    payload           JSONB,
    -- idempotency_key (finding #16, #17):
    --   For GCAL_CREATE: set to '<appointment_id>:GCAL_CREATE:<attempt_nonce>'
    --   where attempt_nonce is set when the CREATE is about to be attempted.
    --   The Calendar Worker stores this as the GCal event's extendedProperties.privateProperties.idempotencyKey.
    --   On retry: Worker first searches GCal for an event with this key before creating.
    --   If found: marks operation SUCCESS with existing event_id.
    --   If not found: creates new event with this key.
    --   This ensures exactly-one Calendar event per appointment even across crashes.
    idempotency_key   VARCHAR(255),
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE integration_operations IS
  'Outbox for external Calendar operations. Only the Calendar Worker (Workflow 04) reads and executes these. Business workflows never call Google Calendar directly.';
COMMENT ON COLUMN integration_operations.appointment_id IS
  'ON DELETE SET NULL: history is preserved when appointment is deleted. NULL = orphaned history (appointment was hard-deleted).';
COMMENT ON COLUMN integration_operations.lease_expires_at IS
  'Set to NOW()+10min when claimed. Expired leases (IN_PROGRESS + lease_expires_at < NOW()) are recoverable by any worker.';
COMMENT ON COLUMN integration_operations.idempotency_key IS
  'For GCAL_CREATE: a deterministic key stored in the GCal event. Used to detect duplicate creates after worker crash. Format: <appointment_id>:GCAL_CREATE.';

-- Migrate existing table: add missing columns safely
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='integration_operations' AND column_name='lease_expires_at') THEN
        ALTER TABLE integration_operations ADD COLUMN lease_expires_at TIMESTAMPTZ;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='integration_operations' AND column_name='max_attempts') THEN
        ALTER TABLE integration_operations ADD COLUMN max_attempts INT NOT NULL DEFAULT 5;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='integration_operations' AND column_name='idempotency_key') THEN
        ALTER TABLE integration_operations ADD COLUMN idempotency_key VARCHAR(255);
    END IF;
END $$;

-- Fix ON DELETE behavior if it was CASCADE (migration safety)
DO $$
DECLARE
    v_confdeltype CHAR;
BEGIN
    SELECT confdeltype INTO v_confdeltype
    FROM pg_constraint c
    JOIN pg_class rel ON rel.oid = c.conrelid
    WHERE c.conname = 'integration_operations_appointment_id_fkey'
      AND rel.relname = 'integration_operations';

    IF FOUND AND v_confdeltype = 'c' THEN  -- 'c' = CASCADE
        ALTER TABLE integration_operations
            DROP CONSTRAINT integration_operations_appointment_id_fkey;
        ALTER TABLE integration_operations
            ADD CONSTRAINT integration_operations_appointment_id_fkey
            FOREIGN KEY (appointment_id)
            REFERENCES appointments(appointment_id)
            ON DELETE SET NULL;
    END IF;
END $$;

-- Status constraint
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_integration_op_status'
    ) THEN
        ALTER TABLE integration_operations
        ADD CONSTRAINT chk_integration_op_status
        CHECK (status IN ('PENDING','IN_PROGRESS','SUCCESS','FAILED','PERMANENTLY_FAILED','SUPERSEDED'));
    END IF;
END $$;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_integration_ops_appt        ON integration_operations(appointment_id);
CREATE INDEX IF NOT EXISTS idx_integration_ops_appt_status ON integration_operations(appointment_id, status, operation_id);
-- Primary work queue index: PENDING and FAILED-retryable
CREATE INDEX IF NOT EXISTS idx_integration_ops_pending
    ON integration_operations(status, next_retry_at)
    WHERE status IN ('PENDING', 'FAILED');
-- Recovery index: stale IN_PROGRESS operations with expired leases
CREATE INDEX IF NOT EXISTS idx_integration_ops_recovery
    ON integration_operations(status, lease_expires_at)
    WHERE status = 'IN_PROGRESS';
-- Idempotency lookup
CREATE INDEX IF NOT EXISTS idx_integration_ops_idempotency
    ON integration_operations(idempotency_key)
    WHERE idempotency_key IS NOT NULL;

-- Updated_at trigger
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

-- ──────────────────────────────────────────────────────────────────────────────
-- 17. Outbox Trigger: Queue Calendar Integration Operations (finding #1)
-- ──────────────────────────────────────────────────────────────────────────────
-- This trigger is the SOLE mechanism that queues Calendar operations.
-- It fires AFTER business workflows update PostgreSQL.
-- Business workflows (WhatsApp, Dashboard) must NEVER call Google Calendar directly.
--
-- GCAL_CREATE semantics (finding #16, #17 — idempotency):
--   Queued whenever appointment transitions to CONFIRMED (from any prior state).
--   idempotency_key = '<appointment_id>:GCAL_CREATE'
--   The Calendar Worker MUST:
--     1. Search GCal for an event with this idempotency key before creating.
--     2. If found: use existing event_id (mark SUCCESS, no new event created).
--     3. If not found: create new event, store key in extendedProperties.
--   This ensures exactly one Calendar event per appointment across retries.
--
-- GCAL_UPDATE semantics (finding #18):
--   Queued when time changes on a CONFIRMED/RESCHEDULED appointment that has
--   a calendar_event_id. Idempotent: repeated execution updates to correct time.
--
-- GCAL_DELETE semantics (finding #19):
--   Queued when appointment is CANCELLED and had a calendar_event_id.
--   Calendar Worker treats HTTP 404 as success (event already deleted = desired state).
--
-- NOTE: This trigger does NOT fire for the Calendar Worker's own update to
-- calendar_event_id column — only status and time changes matter here.
CREATE OR REPLACE FUNCTION queue_calendar_integration_ops()
RETURNS TRIGGER AS $$
DECLARE
    v_idempotency_key VARCHAR(255);
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- New appointment inserted as CONFIRMED (e.g. dashboard manual create):
        -- Queue GCAL_CREATE immediately.
        IF NEW.status = 'CONFIRMED' THEN
            v_idempotency_key := NEW.appointment_id::TEXT || ':GCAL_CREATE';
            INSERT INTO integration_operations
                (appointment_id, operation_type, status, idempotency_key, payload, created_at, updated_at)
            VALUES
                (NEW.appointment_id, 'GCAL_CREATE', 'PENDING', v_idempotency_key, to_jsonb(NEW), NOW(), NOW());
        END IF;

    ELSIF TG_OP = 'UPDATE' THEN

        -- ── CONFIRMED transition (PENDING → CONFIRMED, or any → CONFIRMED) ──
        -- This is the primary path: patient confirms a hold → PENDING → CONFIRMED.
        -- The outbox trigger fires here; the business workflow does NOT touch Calendar.
        IF OLD.status != 'CONFIRMED' AND NEW.status = 'CONFIRMED' THEN
            v_idempotency_key := NEW.appointment_id::TEXT || ':GCAL_CREATE';
            -- Only queue GCAL_CREATE if no calendar event exists yet.
            -- If calendar_event_id is already set (e.g. manual create → CONFIRMED),
            -- a previous GCAL_CREATE succeeded. No duplicate create needed.
            IF NEW.calendar_event_id IS NULL OR NEW.calendar_event_id = '' THEN
                INSERT INTO integration_operations
                    (appointment_id, operation_type, status, idempotency_key, payload, created_at, updated_at)
                VALUES
                    (NEW.appointment_id, 'GCAL_CREATE', 'PENDING', v_idempotency_key, to_jsonb(NEW), NOW(), NOW());
            END IF;

        -- ── CANCELLED transition ──
        -- Queue GCAL_DELETE only if there is a known Calendar event to delete.
        ELSIF OLD.status != 'CANCELLED' AND NEW.status = 'CANCELLED'
              AND OLD.calendar_event_id IS NOT NULL AND OLD.calendar_event_id != '' THEN
            INSERT INTO integration_operations
                (appointment_id, operation_type, status, payload, created_at, updated_at)
            VALUES
                (NEW.appointment_id, 'GCAL_DELETE', 'PENDING', to_jsonb(NEW), NOW(), NOW());

        -- ── TIME CHANGED on active appointment ──
        -- Queue GCAL_UPDATE if times changed and a Calendar event exists.
        ELSIF (OLD.start_time IS DISTINCT FROM NEW.start_time OR OLD.end_time IS DISTINCT FROM NEW.end_time)
              AND NEW.status IN ('CONFIRMED', 'RESCHEDULED')
              AND NEW.calendar_event_id IS NOT NULL AND NEW.calendar_event_id != '' THEN
            INSERT INTO integration_operations
                (appointment_id, operation_type, status, payload, created_at, updated_at)
            VALUES
                (NEW.appointment_id, 'GCAL_UPDATE', 'PENDING', to_jsonb(NEW), NOW(), NOW());

        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_queue_calendar_ops ON appointments;
CREATE TRIGGER trg_queue_calendar_ops
AFTER INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION queue_calendar_integration_ops();

-- ──────────────────────────────────────────────────────────────────────────────
-- 18. Claim Integration Operation (finding #15 — safe lease semantics)
-- ──────────────────────────────────────────────────────────────────────────────
-- Workers call this function to atomically claim operations using
-- SELECT ... FOR UPDATE SKIP LOCKED to prevent concurrent claim races.
--
-- Returns the claimed operation row (or nothing if nothing available).
-- The caller (Calendar Worker) should use this result to process the operation.
--
-- Supersession logic:
--   If a newer GCAL_DELETE exists for the same appointment, older PENDING/FAILED
--   operations are marked SUPERSEDED. If a newer GCAL_UPDATE exists, older
--   PENDING/FAILED GCAL_UPDATEs for the same appointment are SUPERSEDED.
--   GCAL_CREATE is never superseded by UPDATE (CREATE must succeed first).
--
-- Lease duration: 10 minutes (configurable via p_lease_minutes parameter).
CREATE OR REPLACE FUNCTION claim_integration_operations(
    p_batch_size   INT     DEFAULT 10,
    p_lease_minutes INT    DEFAULT 10
) RETURNS SETOF integration_operations AS $$
DECLARE
    v_op_ids INT[];
BEGIN
    -- Step 1: Supersede stale operations
    WITH superseded AS (
        UPDATE integration_operations io
        SET status = 'SUPERSEDED', updated_at = NOW()
        FROM integration_operations newer
        WHERE io.appointment_id = newer.appointment_id
          AND io.operation_id   < newer.operation_id
          AND io.status IN ('PENDING', 'FAILED')
          AND newer.status IN ('PENDING', 'IN_PROGRESS', 'FAILED')
          AND (
              newer.operation_type = 'GCAL_DELETE'
              OR (newer.operation_type = io.operation_type AND newer.operation_type = 'GCAL_UPDATE')
          )
        RETURNING io.operation_id
    )
    SELECT array_agg(operation_id) INTO v_op_ids FROM superseded;

    -- Step 2: Mark already-satisfied operations as SUCCESS
    -- (e.g. GCAL_CREATE PENDING but appointment already has calendar_event_id)
    WITH already_done AS (
        UPDATE integration_operations io
        SET status = 'SUCCESS', updated_at = NOW()
        FROM appointments a
        WHERE io.appointment_id = a.appointment_id
          AND io.status = 'PENDING'
          AND (
              (io.operation_type = 'GCAL_CREATE' AND a.calendar_event_id IS NOT NULL AND a.calendar_event_id != '')
              OR (io.operation_type = 'GCAL_DELETE' AND (a.calendar_event_id IS NULL OR a.calendar_event_id = ''))
          )
        RETURNING io.operation_id
    )
    SELECT array_agg(operation_id) || COALESCE(v_op_ids, '{}') INTO v_op_ids FROM already_done;

    -- Step 3: Claim claimable operations with FOR UPDATE SKIP LOCKED
    RETURN QUERY
    WITH claimable AS (
        SELECT io.operation_id
        FROM integration_operations io
        WHERE (
            io.status = 'PENDING'
            OR (io.status = 'FAILED'       AND io.next_retry_at <= NOW()   AND io.attempt_count < io.max_attempts)
            OR (io.status = 'IN_PROGRESS'  AND io.lease_expires_at < NOW() AND io.attempt_count < io.max_attempts)
        )
        AND (v_op_ids IS NULL OR io.operation_id != ALL(v_op_ids))
        ORDER BY
            CASE io.status WHEN 'IN_PROGRESS' THEN 0 WHEN 'PENDING' THEN 1 ELSE 2 END,
            io.created_at
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    )
    UPDATE integration_operations io
    SET
        status          = 'IN_PROGRESS',
        last_attempt_at = NOW(),
        lease_expires_at = NOW() + (p_lease_minutes || ' minutes')::INTERVAL,
        attempt_count   = CASE WHEN io.status = 'IN_PROGRESS'
                               THEN io.attempt_count     -- recovery: don't double-count
                               ELSE io.attempt_count + 1
                          END,
        updated_at      = NOW()
    FROM claimable c
    WHERE io.operation_id = c.operation_id
    RETURNING io.*;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION claim_integration_operations IS
  'Atomically claims pending/recoverable integration operations using FOR UPDATE SKIP LOCKED. Sets lease_expires_at for crash recovery. Call from Calendar Worker only.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 19. Maintenance Functions (finding #109, #110)
-- ──────────────────────────────────────────────────────────────────────────────
-- PENDING appointment expiration is now a standalone maintenance function.
-- It must NOT be called inside customer-facing request processing.
-- A dedicated scheduled job (n8n schedule or pg_cron) calls this independently.
CREATE OR REPLACE FUNCTION expire_stale_pending_appointments()
RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    -- Set actor for audit trail
    PERFORM set_config('app.current_actor', 'system:maintenance', true);

    UPDATE appointments
    SET status = 'EXPIRED', updated_at = NOW()
    WHERE status = 'PENDING'
      AND expires_at <= NOW();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION expire_stale_pending_appointments IS
  'Expires stale PENDING appointments. Must be called from a scheduled maintenance job, NOT from customer request paths. Returns count of appointments expired.';

-- Processed message cleanup (finding #110)
-- Moved out of customer context query. Call from maintenance scheduler.
CREATE OR REPLACE FUNCTION cleanup_old_processed_messages(
    p_retention_days INT DEFAULT 7
) RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    DELETE FROM processed_messages
    WHERE processed_at < NOW() - (p_retention_days || ' days')::INTERVAL;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_old_processed_messages IS
  'Deletes processed_messages older than p_retention_days (default 7). Call from scheduled maintenance job, NOT customer request paths.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 20. Reconciliation View (finding #20)
-- ──────────────────────────────────────────────────────────────────────────────
-- Detects DB↔Calendar discrepancies for operator review.
-- MISSING_CALENDAR_EVENT: appointment is active but no Calendar event queued/created.
--   Repair: insert GCAL_CREATE integration_operation manually.
-- CANCELLED_WITH_ACTIVE_CALENDAR_ID: appointment cancelled but calendar_event_id still set.
--   Repair: insert GCAL_DELETE integration_operation manually.
-- STALE_PENDING_HOLD: expired pending appointment not yet cleaned up.
--   Repair: call expire_stale_pending_appointments().
-- CALENDAR_EVENT_PENDING: healthy but Calendar operation not yet processed (expected).
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
    a.appointment_source,
    d.calendar_id,
    d.doctor_name,
    -- Pending integration operations for this appointment
    (SELECT string_agg(io.operation_type || ':' || io.status, ', ' ORDER BY io.operation_id)
     FROM integration_operations io
     WHERE io.appointment_id = a.appointment_id
       AND io.status IN ('PENDING', 'IN_PROGRESS', 'FAILED')
    ) AS pending_operations,
    CASE
        WHEN a.status IN ('CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED')
             AND (a.calendar_event_id IS NULL OR a.calendar_event_id = '')
             AND NOT EXISTS (
                 SELECT 1 FROM integration_operations io
                 WHERE io.appointment_id = a.appointment_id
                   AND io.operation_type = 'GCAL_CREATE'
                   AND io.status IN ('PENDING', 'IN_PROGRESS', 'FAILED')
             )
        THEN 'MISSING_CALENDAR_EVENT'
        WHEN a.status = 'CANCELLED'
             AND a.calendar_event_id IS NOT NULL AND a.calendar_event_id != ''
             AND NOT EXISTS (
                 SELECT 1 FROM integration_operations io
                 WHERE io.appointment_id = a.appointment_id
                   AND io.operation_type = 'GCAL_DELETE'
                   AND io.status IN ('PENDING', 'IN_PROGRESS')
             )
        THEN 'CANCELLED_WITH_ACTIVE_CALENDAR_ID'
        WHEN a.status = 'PENDING' AND a.expires_at <= NOW()
        THEN 'STALE_PENDING_HOLD'
        WHEN a.status IN ('CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED')
             AND (a.calendar_event_id IS NULL OR a.calendar_event_id = '')
             AND EXISTS (
                 SELECT 1 FROM integration_operations io
                 WHERE io.appointment_id = a.appointment_id
                   AND io.operation_type = 'GCAL_CREATE'
                   AND io.status IN ('PENDING', 'IN_PROGRESS', 'FAILED')
             )
        THEN 'CALENDAR_EVENT_PENDING'
        ELSE 'HEALTHY'
    END AS sync_status,
    a.updated_at
FROM appointments a
JOIN doctors d ON a.doctor_id = d.doctor_id;

COMMENT ON VIEW vw_appointment_reconciliation IS
  'Shows discrepancies between PostgreSQL appointment state and Google Calendar sync status. Use pending_operations column to see what Calendar Worker will do next.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 21. Reconciliation Repair Functions (finding #20)
-- ──────────────────────────────────────────────────────────────────────────────
-- These functions queue repair operations into integration_operations.
-- They are deterministic, idempotent, and logged.
-- They do NOT directly call Google Calendar.
CREATE OR REPLACE FUNCTION reconcile_queue_missing_calendar_create(
    p_appointment_id INT
) RETURNS TEXT AS $$
DECLARE
    v_appt   appointments%ROWTYPE;
    v_key    VARCHAR(255);
    v_exists BOOLEAN;
BEGIN
    SELECT * INTO v_appt FROM appointments WHERE appointment_id = p_appointment_id;
    IF NOT FOUND THEN
        RETURN 'ERROR: Appointment ' || p_appointment_id || ' not found.';
    END IF;

    IF v_appt.calendar_event_id IS NOT NULL AND v_appt.calendar_event_id != '' THEN
        RETURN 'SKIPPED: Appointment already has calendar_event_id = ' || v_appt.calendar_event_id;
    END IF;

    IF v_appt.status NOT IN ('CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED') THEN
        RETURN 'SKIPPED: Appointment status ' || v_appt.status || ' does not require Calendar event.';
    END IF;

    v_key := p_appointment_id::TEXT || ':GCAL_CREATE';

    -- Check if already queued
    SELECT EXISTS (
        SELECT 1 FROM integration_operations
        WHERE appointment_id = p_appointment_id
          AND operation_type = 'GCAL_CREATE'
          AND status IN ('PENDING', 'IN_PROGRESS', 'FAILED')
    ) INTO v_exists;

    IF v_exists THEN
        RETURN 'SKIPPED: GCAL_CREATE already queued for appointment ' || p_appointment_id;
    END IF;

    INSERT INTO integration_operations
        (appointment_id, operation_type, status, idempotency_key, payload, created_at, updated_at)
    VALUES
        (p_appointment_id, 'GCAL_CREATE', 'PENDING', v_key, to_jsonb(v_appt), NOW(), NOW());

    RETURN 'QUEUED: GCAL_CREATE for appointment ' || p_appointment_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION reconcile_queue_stale_calendar_delete(
    p_appointment_id INT
) RETURNS TEXT AS $$
DECLARE
    v_appt   appointments%ROWTYPE;
    v_exists BOOLEAN;
BEGIN
    SELECT * INTO v_appt FROM appointments WHERE appointment_id = p_appointment_id;
    IF NOT FOUND THEN
        RETURN 'ERROR: Appointment ' || p_appointment_id || ' not found.';
    END IF;

    IF v_appt.status != 'CANCELLED' THEN
        RETURN 'SKIPPED: Appointment status is ' || v_appt.status || ', not CANCELLED.';
    END IF;

    IF v_appt.calendar_event_id IS NULL OR v_appt.calendar_event_id = '' THEN
        RETURN 'SKIPPED: No calendar_event_id to delete.';
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM integration_operations
        WHERE appointment_id = p_appointment_id
          AND operation_type = 'GCAL_DELETE'
          AND status IN ('PENDING', 'IN_PROGRESS')
    ) INTO v_exists;

    IF v_exists THEN
        RETURN 'SKIPPED: GCAL_DELETE already queued for appointment ' || p_appointment_id;
    END IF;

    INSERT INTO integration_operations
        (appointment_id, operation_type, status, payload, created_at, updated_at)
    VALUES
        (p_appointment_id, 'GCAL_DELETE', 'PENDING', to_jsonb(v_appt), NOW(), NOW());

    RETURN 'QUEUED: GCAL_DELETE for appointment ' || p_appointment_id;
END;
$$ LANGUAGE plpgsql;

-- ──────────────────────────────────────────────────────────────────────────────
-- 22. Operational Monitoring Views
-- ──────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW v_permanently_failed_operations AS
SELECT
    io.operation_id,
    io.appointment_id,
    io.operation_type,
    io.status,
    io.attempt_count,
    io.last_attempt_at,
    io.error_details,
    io.idempotency_key,
    io.created_at,
    a.customer_name,
    a.phone,
    a.status AS appt_status,
    a.calendar_event_id,
    d.doctor_name
FROM integration_operations io
LEFT JOIN appointments a ON io.appointment_id = a.appointment_id
LEFT JOIN doctors d ON a.doctor_id = d.doctor_id
WHERE io.status IN ('PERMANENTLY_FAILED', 'SUPERSEDED')
ORDER BY io.last_attempt_at DESC;

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
    a.status AS appt_status,
    CASE WHEN io.lease_expires_at < NOW() THEN TRUE ELSE FALSE END AS lease_expired
FROM integration_operations io
LEFT JOIN appointments a ON io.appointment_id = a.appointment_id
WHERE io.status = 'IN_PROGRESS'
  AND io.last_attempt_at < NOW() - INTERVAL '10 minutes'
ORDER BY io.last_attempt_at;

-- ──────────────────────────────────────────────────────────────────────────────
-- 23. Concurrency Test Function (finding test scenarios 1–8)
-- ──────────────────────────────────────────────────────────────────────────────
-- Test scenario 1: concurrent bookings for same doctor/time
-- This function documents the expected PostgreSQL behavior.
-- Run in separate sessions to verify exclusion constraint works.
CREATE OR REPLACE FUNCTION test_concurrent_booking_scenario()
RETURNS TABLE(scenario TEXT, result TEXT) AS $$
BEGIN
    -- Scenario 1: Verify exclusion constraint protects concurrent slots
    RETURN QUERY SELECT
        'EXCLUSION_CONSTRAINT_PRESENT'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_constraint WHERE conname = 'no_overlapping_active_appointments'
        ) THEN 'PASS: no_overlapping_active_appointments constraint exists'
        ELSE 'FAIL: exclusion constraint missing'
        END::TEXT;

    -- Scenario 2: Verify btree_gist is enabled
    RETURN QUERY SELECT
        'BTREE_GIST_EXTENSION'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_extension WHERE extname = 'btree_gist'
        ) THEN 'PASS: btree_gist extension installed'
        ELSE 'FAIL: btree_gist not installed'
        END::TEXT;

    -- Scenario 3: Verify integration_operations FK is SET NULL not CASCADE
    RETURN QUERY SELECT
        'INTEGRATION_OPS_FK_BEHAVIOR'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_constraint c
            JOIN pg_class rel ON rel.oid = c.conrelid
            WHERE c.conname = 'integration_operations_appointment_id_fkey'
              AND rel.relname = 'integration_operations'
              AND c.confdeltype = 'n'  -- 'n' = SET NULL
        ) THEN 'PASS: integration_operations FK is ON DELETE SET NULL'
        ELSE 'FAIL or NOT YET MIGRATED: check FK confdeltype'
        END::TEXT;

    -- Scenario 4: Verify partial unique index on calendar_event_id
    RETURN QUERY SELECT
        'CALENDAR_EVENT_ID_UNIQUENESS'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE tablename = 'appointments'
              AND indexname = 'uidx_appointments_cal_event_id'
        ) THEN 'PASS: partial unique index on calendar_event_id exists'
        ELSE 'FAIL: uidx_appointments_cal_event_id missing'
        END::TEXT;

    -- Scenario 5: Verify state transition trigger
    RETURN QUERY SELECT
        'STATE_TRANSITION_TRIGGER'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_trigger
            WHERE tgname = 'trg_enforce_state_transition'
        ) THEN 'PASS: state transition trigger installed'
        ELSE 'FAIL: trg_enforce_state_transition missing'
        END::TEXT;

    -- Scenario 6: Verify appointment_source column
    RETURN QUERY SELECT
        'APPOINTMENT_SOURCE_COLUMN'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'appointments' AND column_name = 'appointment_source'
        ) THEN 'PASS: appointment_source column exists'
        ELSE 'FAIL: appointment_source column missing'
        END::TEXT;

    -- Scenario 7: Verify idempotency_key column on integration_operations
    RETURN QUERY SELECT
        'IDEMPOTENCY_KEY_COLUMN'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'integration_operations' AND column_name = 'idempotency_key'
        ) THEN 'PASS: idempotency_key column exists'
        ELSE 'FAIL: idempotency_key column missing'
        END::TEXT;

    -- Scenario 8: Verify outbox trigger exists
    RETURN QUERY SELECT
        'OUTBOX_TRIGGER'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_trigger WHERE tgname = 'trg_queue_calendar_ops'
        ) THEN 'PASS: trg_queue_calendar_ops trigger installed'
        ELSE 'FAIL: outbox trigger missing'
        END::TEXT;

    -- Scenario 9: Verify slot alignment enforcement trigger exists
    RETURN QUERY SELECT
        'SLOT_ALIGNMENT_TRIGGER'::TEXT,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_trigger WHERE tgname = 'trg_enforce_slot_alignment'
        ) THEN 'PASS: trg_enforce_slot_alignment trigger installed'
        ELSE 'FAIL: trg_enforce_slot_alignment missing'
        END::TEXT;

END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION test_concurrent_booking_scenario IS
  'Structural test suite. Returns PASS/FAIL for each architectural requirement. Run after schema migration to verify.';

-- ──────────────────────────────────────────────────────────────────────────────
-- 24. Schema version marker
-- ──────────────────────────────────────────────────────────────────────────────
COMMENT ON SCHEMA public IS
  'Appointment Booking System — Prompt 1 Architecture. PostgreSQL = booking authority. integration_operations = Calendar outbox. Calendar Worker = only Calendar mutator.';
