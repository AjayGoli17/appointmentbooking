-- ============================================================================
-- Healthcare Appointment System — PostgreSQL Schema
-- Component 1 deliverable. PostgreSQL is the source of truth.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gist; -- equality support inside GiST EXCLUDE constraints

-- ----------------------------------------------------------------------------
-- Shared trigger: maintain updated_at
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 1. PATIENTS
-- ============================================================================
CREATE TABLE patients (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  whatsapp_phone  TEXT NOT NULL UNIQUE,
  full_name       TEXT NOT NULL,
  date_of_birth   DATE NULL,
  email           TEXT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- Normalized E.164-style form, e.g. +919876543210
  CONSTRAINT chk_patients_phone_format CHECK (whatsapp_phone ~ '^\+[1-9][0-9]{6,14}$'),
  -- Rejects NULL (already covered by NOT NULL), empty strings, whitespace-only
  -- values, and unreasonably long values, while deliberately using no
  -- ASCII-only or character-set restriction so legitimate Indian/international
  -- names with non-ASCII characters remain valid. full_name = btrim(full_name)
  -- requires the stored value to already be trimmed - callers (register_patient)
  -- are responsible for trimming before insert, so this constraint rejects any
  -- write path that forgets to.
  CONSTRAINT chk_patients_full_name_valid CHECK (
    length(btrim(full_name)) > 0
    AND length(btrim(full_name)) <= 200
    AND full_name = btrim(full_name)
  )
);

CREATE INDEX idx_patients_whatsapp_phone ON patients (whatsapp_phone);

CREATE TRIGGER trg_patients_updated_at
BEFORE UPDATE ON patients
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 2. DOCTORS
-- ============================================================================
CREATE TABLE doctors (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name       TEXT NOT NULL,
  specialization  TEXT NOT NULL,
  calendar_id     TEXT NOT NULL,   -- each doctor has their OWN Google Calendar id
  timezone        TEXT NOT NULL DEFAULT 'Asia/Kolkata',
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_doctors_calendar_id UNIQUE (calendar_id)
);

CREATE INDEX idx_doctors_active ON doctors (active) WHERE active = TRUE;

CREATE TRIGGER trg_doctors_updated_at
BEFORE UPDATE ON doctors
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 3. SERVICES
-- ============================================================================
CREATE TABLE services (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name              TEXT NOT NULL,
  description       TEXT NULL,
  duration_minutes  INTEGER NOT NULL,
  buffer_minutes    INTEGER NOT NULL DEFAULT 0,
  active            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_services_duration_positive CHECK (duration_minutes > 0),
  CONSTRAINT chk_services_buffer_non_negative CHECK (buffer_minutes >= 0)
);

-- Case-insensitive uniqueness on service name
CREATE UNIQUE INDEX uq_services_name_lower ON services (lower(name));
CREATE INDEX idx_services_active ON services (active) WHERE active = TRUE;

CREATE TRIGGER trg_services_updated_at
BEFORE UPDATE ON services
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 4. DOCTOR_SERVICES
-- ============================================================================
CREATE TABLE doctor_services (
  doctor_id   UUID NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  service_id  UUID NOT NULL REFERENCES services(id) ON DELETE CASCADE,
  active      BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (doctor_id, service_id)
);

CREATE INDEX idx_doctor_services_service_id ON doctor_services (service_id);
CREATE INDEX idx_doctor_services_active ON doctor_services (doctor_id, service_id) WHERE active = TRUE;

-- ============================================================================
-- 5. DOCTOR_SCHEDULES (split shifts allowed: multiple rows per doctor/day)
-- ============================================================================
CREATE TABLE doctor_schedules (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id    UUID NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  day_of_week  INTEGER NOT NULL,  -- 0 = Sunday ... 6 = Saturday
  start_time   TIME NOT NULL,
  end_time     TIME NOT NULL,
  active       BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_doctor_schedules_day CHECK (day_of_week BETWEEN 0 AND 6),
  CONSTRAINT chk_doctor_schedules_time_order CHECK (end_time > start_time)
);

CREATE INDEX idx_doctor_schedules_doctor_day ON doctor_schedules (doctor_id, day_of_week) WHERE active = TRUE;

CREATE TRIGGER trg_doctor_schedules_updated_at
BEFORE UPDATE ON doctor_schedules
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 6. DOCTOR_LEAVE (overrides normal schedule; blocks availability)
-- ============================================================================
CREATE TABLE doctor_leave (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doctor_id   UUID NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  starts_at   TIMESTAMPTZ NOT NULL,
  ends_at     TIMESTAMPTZ NOT NULL,
  reason      TEXT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_doctor_leave_time_order CHECK (ends_at > starts_at)
);

-- GiST index to efficiently check "does requested slot overlap this doctor's leave"
CREATE INDEX idx_doctor_leave_doctor_range
  ON doctor_leave USING gist (doctor_id, tstzrange(starts_at, ends_at, '[)'));

CREATE TRIGGER trg_doctor_leave_updated_at
BEFORE UPDATE ON doctor_leave
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- TIMESTAMPTZ arithmetic is STABLE (timezone-dependent), not IMMUTABLE, so
-- blocking_range cannot be a GENERATED column. This trigger keeps it in
-- sync on INSERT/UPDATE instead, running before the EXCLUDE constraint
-- (below) evaluates. It also derives buffer_minutes from the service
-- (rather than trusting an app-supplied value) and rejects any requested
-- time range that does not match the service's duration_minutes, so
-- duration/buffer semantics stay consistent with the services table.
CREATE OR REPLACE FUNCTION set_appointment_computed_fields()
RETURNS TRIGGER AS $$
DECLARE
  v_duration_minutes INTEGER;
  v_buffer_minutes INTEGER;
BEGIN
  SELECT duration_minutes, buffer_minutes
    INTO v_duration_minutes, v_buffer_minutes
    FROM services
   WHERE id = NEW.service_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service % does not exist', NEW.service_id;
  END IF;

  IF (NEW.ends_at - NEW.starts_at) <> (v_duration_minutes * interval '1 minute') THEN
    RAISE EXCEPTION
      'Appointment duration (%) does not match service duration (% minutes)',
      (NEW.ends_at - NEW.starts_at), v_duration_minutes;
  END IF;

  -- buffer_minutes is always derived from the service, never trusted from
  -- the caller, so the blocking_range/exclusion-constraint math below can't
  -- drift from the service definition.
  NEW.buffer_minutes = v_buffer_minutes;

  NEW.blocking_range = tstzrange(
    NEW.starts_at,
    NEW.ends_at + (v_buffer_minutes * interval '1 minute'),
    '[)'
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 7. APPOINTMENTS
-- ============================================================================
CREATE TABLE appointments (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  patient_id                UUID NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  doctor_id                 UUID NOT NULL REFERENCES doctors(id) ON DELETE RESTRICT,
  service_id                UUID NOT NULL REFERENCES services(id) ON DELETE RESTRICT,
  starts_at                 TIMESTAMPTZ NOT NULL,
  ends_at                   TIMESTAMPTZ NOT NULL,
  -- Snapshot of the service's buffer_minutes at booking time, derived
  -- automatically by trg_appointments_computed_fields (never trusted from
  -- the caller). Kept as a real column (not looked up via join) so the
  -- overlap/blocking exclusion constraint below can use it directly.
  -- Slot cadence itself is driven by service duration (starts_at/ends_at only);
  -- buffer_minutes only affects the blocking range, never the cadence.
  buffer_minutes            INTEGER NOT NULL DEFAULT 0,
  status                    TEXT NOT NULL DEFAULT 'SCHEDULED',
  notes                     TEXT NULL,
  google_calendar_event_id  TEXT NULL,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  cancelled_at              TIMESTAMPTZ NULL,

  -- Monotonic per-appointment mutation counter, incremented by exactly 1 in
  -- the same UPDATE statement that reschedules an appointment (Workflow 01's
  -- reschedule_appointment tool). This gives Workflow 01 a deterministic,
  -- database-generated (never random) value to build a distinct
  -- integration_outbox idempotency key per successful reschedule - keying
  -- solely on (appointment_id, new_start_time) is insufficient because the
  -- same appointment can legitimately be moved back to a previously-used
  -- time (e.g. 10:00 -> 11:00 -> 10:00 -> 11:00), and each such move must
  -- still produce its own outbox event for Workflow 04 to process.
  revision                  INTEGER NOT NULL DEFAULT 0,

  CONSTRAINT chk_appointments_status CHECK (
    status IN ('SCHEDULED', 'ARRIVED', 'COMPLETED', 'NO_SHOW', 'CANCELLED')
  ),
  CONSTRAINT chk_appointments_time_order CHECK (ends_at > starts_at),
  CONSTRAINT chk_appointments_buffer_non_negative CHECK (buffer_minutes >= 0),
  CONSTRAINT chk_appointments_revision_non_negative CHECK (revision >= 0),

  -- Blocking range = [starts_at, ends_at + buffer_minutes). Used only for
  -- overlap protection, never for cadence. TIMESTAMPTZ arithmetic is not
  -- IMMUTABLE in PostgreSQL, so this cannot be a GENERATED column; it is
  -- populated by the trg_appointments_blocking_range trigger below instead.
  blocking_range tstzrange NOT NULL,

  -- DATABASE-LEVEL CONCURRENCY PROTECTION:
  -- Two overlapping bookings for the same doctor cannot both succeed.
  -- Cancelled appointments are excluded from the predicate, so they no
  -- longer block the slot.
  CONSTRAINT exc_appointments_no_doctor_overlap
    EXCLUDE USING gist (doctor_id WITH =, blocking_range WITH &&)
    WHERE (status <> 'CANCELLED')
);

CREATE INDEX idx_appointments_doctor_starts_at ON appointments (doctor_id, starts_at);
CREATE INDEX idx_appointments_patient_starts_at ON appointments (patient_id, starts_at);
CREATE INDEX idx_appointments_status ON appointments (status);
CREATE INDEX idx_appointments_google_event_id ON appointments (google_calendar_event_id)
  WHERE google_calendar_event_id IS NOT NULL;

CREATE TRIGGER trg_appointments_updated_at
BEFORE UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- PostgreSQL fires same-timing (BEFORE ROW) triggers in name order. This
-- must run before trg_appointments_leave_check (needs NEW.blocking_range)
-- and 'blocking' < 'leave' alphabetically, so ordering is correct.
CREATE TRIGGER trg_appointments_blocking_range
BEFORE INSERT OR UPDATE OF starts_at, ends_at, service_id ON appointments
FOR EACH ROW EXECUTE FUNCTION set_appointment_computed_fields();

-- DATABASE-LEVEL LEAVE ENFORCEMENT:
-- A doctor's leave must actually block availability, not merely be
-- indexable for an application-side check (checking-then-inserting alone
-- is race-prone, the same class of problem the booking EXCLUDE constraint
-- above solves). Runs after trg_appointments_blocking_range so
-- NEW.blocking_range is already populated.
CREATE OR REPLACE FUNCTION enforce_appointment_not_during_leave()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'CANCELLED' THEN
    RETURN NEW;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM doctor_leave dl
     WHERE dl.doctor_id = NEW.doctor_id
       AND tstzrange(dl.starts_at, dl.ends_at, '[)') && NEW.blocking_range
  ) THEN
    RAISE EXCEPTION 'Doctor % is on leave during the requested slot', NEW.doctor_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_leave_check
BEFORE INSERT OR UPDATE OF starts_at, ends_at, service_id, doctor_id ON appointments
FOR EACH ROW EXECUTE FUNCTION enforce_appointment_not_during_leave();

-- DATABASE-LEVEL SCHEDULE ENFORCEMENT (also closes the midnight-crossing
-- gap): doctor_schedules rows are always same-day (chk_doctor_schedules_time_order
-- requires end_time > start_time, so overnight/split-midnight shifts are not
-- representable), so a valid appointment's full blocking period (service
-- duration + buffer) must start and end within the SAME Asia/Kolkata local
-- calendar date as its start, anchored to one active schedule row for that
-- date. Both bounds are compared as full local timestamps
-- (date_trunc('day', local_start) + sch.start_time/end_time) rather than by
-- truncating to ::time - a ::time-only comparison silently wraps a
-- past-midnight instant back into an early-morning-looking value (e.g.
-- 00:30) and can incorrectly compare as "before closing time", which is
-- exactly the bug this trigger closes. Because a same-day schedule's
-- end_time can be at most 23:59:59.999999 on v_day_start, any blocking_end
-- that has actually crossed into the next calendar date is automatically
-- greater than v_day_start + sch.end_time and is rejected - no separate
-- "did this cross midnight" check is needed. Runs after
-- trg_appointments_blocking_range (needs NEW.blocking_range) and
-- 'schedule' > 'blocking' alphabetically, so same-timing trigger firing
-- order is correct.
CREATE OR REPLACE FUNCTION enforce_appointment_within_schedule()
RETURNS TRIGGER AS $$
DECLARE
  v_local_start     TIMESTAMP;
  v_local_block_end TIMESTAMP;
  v_day_start       TIMESTAMP;
  v_day_of_week     INTEGER;
BEGIN
  IF NEW.status = 'CANCELLED' THEN
    RETURN NEW;
  END IF;

  v_local_start     := NEW.starts_at AT TIME ZONE 'Asia/Kolkata';
  v_local_block_end := upper(NEW.blocking_range) AT TIME ZONE 'Asia/Kolkata';
  v_day_start       := date_trunc('day', v_local_start);
  v_day_of_week     := EXTRACT(DOW FROM v_local_start)::int;

  IF NOT EXISTS (
    SELECT 1
      FROM doctor_schedules sch
     WHERE sch.doctor_id = NEW.doctor_id
       AND sch.active = TRUE
       AND sch.day_of_week = v_day_of_week
       AND v_local_start     >= v_day_start + sch.start_time
       AND v_local_block_end <= v_day_start + sch.end_time
  ) THEN
    RAISE EXCEPTION
      'Appointment for doctor % does not fit within a single active same-day schedule window (Asia/Kolkata); overnight/midnight-crossing appointments are not supported',
      NEW.doctor_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_schedule_check
BEFORE INSERT OR UPDATE OF starts_at, ends_at, service_id, doctor_id ON appointments
FOR EACH ROW EXECUTE FUNCTION enforce_appointment_within_schedule();

-- Enforce the ONLY valid status transitions from the project brief:
--   SCHEDULED -> ARRIVED | CANCELLED | NO_SHOW
--   ARRIVED   -> COMPLETED
CREATE OR REPLACE FUNCTION enforce_appointment_status_transition()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.status = 'SCHEDULED' AND NEW.status IN ('ARRIVED', 'CANCELLED', 'NO_SHOW'))
    OR (OLD.status = 'ARRIVED' AND NEW.status = 'COMPLETED')
  ) THEN
    RAISE EXCEPTION 'Invalid appointment status transition: % -> %', OLD.status, NEW.status;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_status_transition
BEFORE UPDATE OF status ON appointments
FOR EACH ROW EXECUTE FUNCTION enforce_appointment_status_transition();

-- REVISION INTEGRITY (defense-in-depth for optimistic concurrency):
-- appointments.revision is the counter reschedule_appointment uses for
-- optimistic-concurrency conflict detection (see reschedule_appointment in
-- Workflow 01). This trigger guarantees, at the database level, that no
-- update path - however it is written in the future - can decrease the
-- counter or jump it by more than one, regardless of what any application
-- layer does or forgets to do:
--   * revision must never decrease.
--   * revision may only advance by exactly one per UPDATE (a normal
--     versioned mutation), never be reset or bumped arbitrarily.
-- INSERTs are unaffected (initial revision 0, or any non-negative starting
-- value per chk_appointments_revision_non_negative, remains valid); this
-- trigger only fires when an UPDATE actually touches the revision column.
CREATE OR REPLACE FUNCTION enforce_appointment_revision_integrity()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.revision < OLD.revision THEN
    RAISE EXCEPTION
      'appointments.revision cannot decrease (id=%, old=%, new=%)',
      OLD.id, OLD.revision, NEW.revision;
  END IF;

  IF NEW.revision > OLD.revision + 1 THEN
    RAISE EXCEPTION
      'appointments.revision must advance by exactly 1 per update (id=%, old=%, new=%)',
      OLD.id, OLD.revision, NEW.revision;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_revision_integrity
BEFORE UPDATE OF revision ON appointments
FOR EACH ROW EXECUTE FUNCTION enforce_appointment_revision_integrity();

-- ============================================================================
-- 8. INTEGRATION_OUTBOX (Workflow 04 crash-safe Calendar sync)
-- ============================================================================
CREATE TABLE integration_outbox (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_type   TEXT NOT NULL,          -- e.g. 'APPOINTMENT' (polymorphic, no FK)
  aggregate_id     UUID NOT NULL,
  operation        TEXT NOT NULL,
  payload          JSONB NOT NULL,
  status           TEXT NOT NULL DEFAULT 'PENDING',
  attempts         INTEGER NOT NULL DEFAULT 0,
  available_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  locked_at        TIMESTAMPTZ NULL,
  processed_at     TIMESTAMPTZ NULL,
  last_error       TEXT NULL,
  idempotency_key  TEXT NOT NULL UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chk_outbox_operation CHECK (operation IN ('CREATE', 'UPDATE', 'DELETE')),
  CONSTRAINT chk_outbox_status CHECK (status IN ('PENDING', 'PROCESSING', 'COMPLETED', 'FAILED'))
);

-- Supports Workflow 04 claiming the next batch of ready jobs, e.g.:
-- SELECT ... WHERE status = 'PENDING' AND available_at <= now()
--   ORDER BY available_at FOR UPDATE SKIP LOCKED LIMIT n;
CREATE INDEX idx_outbox_ready_jobs ON integration_outbox (available_at)
  WHERE status = 'PENDING';
CREATE INDEX idx_outbox_aggregate ON integration_outbox (aggregate_type, aggregate_id);
-- Supports reaping jobs stuck in PROCESSING after a worker crash, e.g.:
-- SELECT ... WHERE status = 'PROCESSING' AND locked_at < now() - interval '5 minutes';
CREATE INDEX idx_outbox_stuck_processing ON integration_outbox (locked_at)
  WHERE status = 'PROCESSING';

CREATE TRIGGER trg_outbox_updated_at
BEFORE UPDATE ON integration_outbox
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 9. REMINDER_LOG (Workflow 02, deterministic, idempotent)
-- ============================================================================
CREATE TABLE reminder_log (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  appointment_id UUID NOT NULL REFERENCES appointments(id) ON DELETE RESTRICT,
  reminder_type  TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'PENDING',
  scheduled_for  TIMESTAMPTZ NOT NULL,
  sent_at        TIMESTAMPTZ NULL,
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chk_reminder_type CHECK (
    reminder_type IN ('THREE_DAY', 'ONE_DAY', 'FOUR_HOUR', 'ONE_HOUR')
  ),
  CONSTRAINT chk_reminder_status CHECK (
    status IN ('PENDING', 'SENT', 'FAILED', 'SKIPPED')
  ),
  -- IDEMPOTENCY: one row per (appointment, reminder_type) — the same
  -- reminder cannot be created/sent twice even if the workflow re-runs.
  CONSTRAINT uq_reminder_appointment_type UNIQUE (appointment_id, reminder_type)
);

CREATE INDEX idx_reminder_log_due ON reminder_log (scheduled_for)
  WHERE status = 'PENDING';

CREATE TRIGGER trg_reminder_log_updated_at
BEFORE UPDATE ON reminder_log
FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================================
-- 10. AUDIT_LOG
-- ============================================================================
CREATE TABLE audit_log (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_type   TEXT NOT NULL,
  actor_id     UUID NULL,
  action       TEXT NOT NULL,   -- free-form, intentionally not CHECK-constrained
  entity_type  TEXT NOT NULL,   -- polymorphic (e.g. 'APPOINTMENT', 'DOCTOR_LEAVE'), no FK
  entity_id    UUID NULL,
  metadata     JSONB NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT chk_audit_actor_type CHECK (
    actor_type IN ('PATIENT', 'RECEPTIONIST', 'DOCTOR', 'SYSTEM', 'AI_AGENT')
  )
);

CREATE INDEX idx_audit_log_entity ON audit_log (entity_type, entity_id, created_at);
CREATE INDEX idx_audit_log_action_time ON audit_log (action, created_at);

-- ============================================================================
-- 11. WHATSAPP_MESSAGE_DEDUP (Workflow 01 crash-safe, concurrency-safe
--     idempotency gate - a WhatsApp webhook retry of the same message must
--     never reach the AI Agent, or send a reply, twice)
-- ============================================================================
CREATE TABLE whatsapp_message_dedup (
  -- The WhatsApp Business Cloud API's own per-message id. This is the
  -- idempotency key: PRIMARY KEY gives it a unique index, so two concurrent
  -- deliveries of the same message can both attempt the claim upsert below
  -- and Postgres guarantees only one of them ever gets a row back via
  -- RETURNING - the other gets zero rows, which is how Workflow 01 stops a
  -- duplicate before it reaches the Appointment Agent or sends a second reply.
  wa_message_id     TEXT PRIMARY KEY,
  normalized_phone  TEXT NOT NULL,
  -- PROCESSING = claimed and not yet known to have completed successfully.
  -- COMPLETED  = the corresponding reply was actually produced/sent; this
  --              message must never be processed again.
  -- A row is only ever moved PROCESSING -> COMPLETED by Workflow 01's
  -- "Mark ... Processed" step, which runs only on the success path (after
  -- the Appointment Agent/reply flow finished without error). If processing
  -- fails after the claim but before that step, the row is left PROCESSING
  -- so the same message can be safely retried once claimed_at goes stale -
  -- see the claim upsert pattern used by Workflow 01's dedup nodes:
  --   INSERT INTO whatsapp_message_dedup (wa_message_id, normalized_phone, status, claimed_at)
  --   VALUES ($1, $2, 'PROCESSING', now())
  --   ON CONFLICT (wa_message_id) DO UPDATE
  --     SET claimed_at = now(), status = 'PROCESSING'
  --   WHERE whatsapp_message_dedup.status = 'PROCESSING'
  --     AND whatsapp_message_dedup.claimed_at < now() - interval '2 minutes'
  --   RETURNING wa_message_id;
  -- This single atomic statement covers every required case:
  --   * brand-new message                -> INSERT succeeds, 1 row returned, proceed.
  --   * already COMPLETED                -> WHERE is false, 0 rows, treated as duplicate, dropped.
  --   * PROCESSING and still fresh       -> WHERE is false, 0 rows, dropped (protects
  --                                          against two concurrent webhook deliveries
  --                                          both proceeding at once).
  --   * PROCESSING and stale (crashed/   -> WHERE is true, row is reclaimed
  --     failed previous attempt)            (claimed_at bumped), 1 row returned, retried.
  status            TEXT NOT NULL DEFAULT 'PROCESSING',
  received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at      TIMESTAMPTZ NULL,

  CONSTRAINT chk_whatsapp_message_dedup_status CHECK (status IN ('PROCESSING', 'COMPLETED'))
);

-- Supports a periodic external cleanup job (not part of Workflow 01) purging
-- rows older than some retention window, e.g.:
-- DELETE FROM whatsapp_message_dedup WHERE received_at < now() - interval '30 days';
CREATE INDEX idx_whatsapp_message_dedup_received_at ON whatsapp_message_dedup (received_at);

-- Lets an operator eyeball currently in-flight/stuck claims; the claim
-- upsert above is self-healing (no separate reaper job is required), this
-- index just makes those rows cheap to inspect.
CREATE INDEX idx_whatsapp_message_dedup_processing ON whatsapp_message_dedup (claimed_at)
  WHERE status = 'PROCESSING';