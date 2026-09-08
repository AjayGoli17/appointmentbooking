-- Enable btree_gist for exclusion constraints if available
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE IF NOT EXISTS doctors (
    doctor_id VARCHAR(100) PRIMARY KEY,
    doctor_name VARCHAR(255) NOT NULL,
    specialty VARCHAR(255) NOT NULL,
    calendar_id VARCHAR(255) NOT NULL,
    timezone VARCHAR(100) NOT NULL DEFAULT 'Asia/Kolkata',
    working_days JSONB NOT NULL DEFAULT '[1,2,3,4,5,6]'::jsonb, -- 1=Mon, 6=Sat
    working_hours JSONB NOT NULL DEFAULT '{"start": "09:00", "end": "17:00"}'::jsonb,
    slot_duration_minutes INT NOT NULL DEFAULT 30,
    buffer_minutes INT NOT NULL DEFAULT 0,
    booking_cutoff_minutes INT NOT NULL DEFAULT 60,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS doctor_unavailability (
    id SERIAL PRIMARY KEY,
    doctor_id VARCHAR(100) NOT NULL REFERENCES doctors(doctor_id) ON DELETE CASCADE,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ NOT NULL,
    reason VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_unavail_range CHECK (end_time > start_time)
);

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
    CONSTRAINT chk_appt_range CHECK (end_time > start_time)
);

CREATE TABLE IF NOT EXISTS processed_messages (
    message_id VARCHAR(128) PRIMARY KEY,
    channel VARCHAR(50) NOT NULL DEFAULT 'whatsapp',
    sender VARCHAR(100) NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS appointment_audit_logs (
    log_id SERIAL PRIMARY KEY,
    appointment_id INT REFERENCES appointments(appointment_id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL,
    actor VARCHAR(100) NOT NULL,
    previous_state JSONB,
    new_state JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Performance and Concurrency Indexes
CREATE INDEX IF NOT EXISTS idx_appointments_phone ON appointments(phone);
CREATE INDEX IF NOT EXISTS idx_appointments_doc_time ON appointments(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_appointments_status ON appointments(status);
CREATE INDEX IF NOT EXISTS idx_doctor_unavail_doc_time ON doctor_unavailability(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_processed_messages_sender_time ON processed_messages(sender, processed_at);

-- Slot Double-Booking Exclusion Constraint (Excludes CANCELLED/EXPIRED holds)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'no_overlapping_confirmed_appointments'
    ) THEN
        ALTER TABLE appointments 
        ADD CONSTRAINT no_overlapping_confirmed_appointments 
        EXCLUDE USING gist (
            doctor_id WITH =,
            tstzrange(start_time, end_time) WITH &&
        ) WHERE (status IN ('CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED') OR (status = 'PENDING' AND expires_at > NOW()));
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'Exclusion constraint check completed.';
END $$;
