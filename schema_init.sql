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
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS appointments (
    appointment_id SERIAL PRIMARY KEY,
    customer_name VARCHAR(255) NOT NULL,
    phone VARCHAR(50) NOT NULL,
    doctor_id VARCHAR(100) NOT NULL REFERENCES doctors(doctor_id) ON UPDATE CASCADE,
    service VARCHAR(255) NOT NULL,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'CONFIRMED', 'CANCELLED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED', 'NO_SHOW')),
    calendar_event_id VARCHAR(255),
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    reminder_3d_sent BOOLEAN DEFAULT FALSE,
    reminder_1d_sent BOOLEAN DEFAULT FALSE,
    reminder_4h_sent BOOLEAN DEFAULT FALSE,
    reminder_1h_sent BOOLEAN DEFAULT FALSE,
    reminder_3d_claimed_at TIMESTAMP WITH TIME ZONE,
    reminder_1d_claimed_at TIMESTAMP WITH TIME ZONE,
    reminder_4h_claimed_at TIMESTAMP WITH TIME ZONE,
    reminder_1h_claimed_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT chk_start_end CHECK (start_time < end_time),
    CONSTRAINT no_overlapping_appointments EXCLUDE USING gist (
        doctor_id WITH =,
        tstzrange(start_time, end_time) WITH &&
    ) WHERE (status IN ('PENDING', 'CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED'))
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'no_overlapping_appointments'
    ) THEN
        ALTER TABLE appointments ADD CONSTRAINT no_overlapping_appointments
        EXCLUDE USING gist (
            doctor_id WITH =,
            tstzrange(start_time, end_time) WITH &&
        ) WHERE (status IN ('PENDING', 'CONFIRMED', 'RESCHEDULED', 'ARRIVED', 'COMPLETED'));
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS doctor_unavailability (
    id SERIAL PRIMARY KEY,
    doctor_id VARCHAR(100) NOT NULL REFERENCES doctors(doctor_id) ON UPDATE CASCADE,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE NOT NULL,
    reason VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT chk_unavail_start_end CHECK (start_time < end_time)
);

CREATE TABLE IF NOT EXISTS audit_logs (
    id SERIAL PRIMARY KEY,
    correlation_id VARCHAR(100) NOT NULL,
    operation VARCHAR(100) NOT NULL,
    appointment_id INT,
    doctor_id VARCHAR(100),
    result VARCHAR(50) NOT NULL,
    error_code VARCHAR(100),
    details JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Indices for high performance & concurrency lookups
CREATE INDEX IF NOT EXISTS idx_doctors_active ON doctors(doctor_id) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_appointments_doc_time ON appointments(doctor_id, start_time, end_time);
CREATE INDEX IF NOT EXISTS idx_appointments_phone_status ON appointments(phone, status);
CREATE INDEX IF NOT EXISTS idx_appointments_status_start ON appointments(status, start_time);
CREATE INDEX IF NOT EXISTS idx_appointments_expires ON appointments(expires_at) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS idx_doctor_unavailability_lookup ON doctor_unavailability(doctor_id, start_time, end_time);

-- Seed initial doctors if empty
INSERT INTO doctors (doctor_id, doctor_name, specialty, calendar_id, timezone, working_days, working_hours, slot_duration_minutes, buffer_minutes, booking_cutoff_minutes, is_active)
VALUES 
('dr_smith', 'Dr. John Smith', 'General Physician', 'dr_smith@clinic.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, true),
('dr_emily', 'Dr. Emily Davis', 'Dental Specialist', 'dr_emily@clinic.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, true),
('dr_robert', 'Dr. Robert Wilson', 'Cardiologist', 'dr_robert@clinic.com', 'Asia/Kolkata', '[1,2,3,4,5,6]'::jsonb, '{"start": "09:00", "end": "17:00"}'::jsonb, 30, 0, 60, true)
ON CONFLICT (doctor_id) DO UPDATE SET
  doctor_name = EXCLUDED.doctor_name,
  specialty = EXCLUDED.specialty,
  calendar_id = EXCLUDED.calendar_id,
  timezone = EXCLUDED.timezone,
  working_days = EXCLUDED.working_days,
  working_hours = EXCLUDED.working_hours,
  slot_duration_minutes = EXCLUDED.slot_duration_minutes,
  buffer_minutes = EXCLUDED.buffer_minutes,
  booking_cutoff_minutes = EXCLUDED.booking_cutoff_minutes,
  is_active = EXCLUDED.is_active;
