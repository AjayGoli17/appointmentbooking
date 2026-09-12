import json

with open('01_WhatsApp_AI_Appointment_Agent.json', 'r') as f:
    wf = json.load(f)

for node in wf['nodes']:
    if node['name'] == 'Merge_Context_For_AI':
        js = node['parameters']['jsCode']
        js = js.replace(
            "const activeConfirmed = appts.find(a => (a.status === 'CONFIRMED' || a.status === 'RESCHEDULED') && new Date(a.end_time) > now);",
            "const activeConfirmedAppts = appts.filter(a => (a.status === 'CONFIRMED' || a.status === 'RESCHEDULED') && new Date(a.end_time) > now);\nconst activeConfirmed = activeConfirmedAppts[0]; // legacy fallback"
        )
        js = js.replace(
            "active_confirmed: activeConfirmed || null,",
            "active_confirmed: activeConfirmed || null,\n    active_confirmed_appts: activeConfirmedAppts,"
        )
        # We also want to pass doctor_name in appointments if possible, but they might not have it.
        # So we can enrich it
        enrich = """
const activeConfirmedAppts = appts.filter(a => (a.status === 'CONFIRMED' || a.status === 'RESCHEDULED') && new Date(a.end_time) > now).map(a => {
  const d = doctors.find(doc => doc.doctor_id === a.doctor_id);
  if (d) a.doctor_name = d.doctor_name;
  return a;
});
const activeConfirmed = activeConfirmedAppts[0];
"""
        js = js.replace("const activeConfirmedAppts = appts.filter(a => (a.status === 'CONFIRMED' || a.status === 'RESCHEDULED') && new Date(a.end_time) > now);\nconst activeConfirmed = activeConfirmedAppts[0]; // legacy fallback", enrich)
        node['parameters']['jsCode'] = js

    if node['name'] == 'Validate_Cancel_Request':
        node['parameters']['jsCode'] = """
const prev = $input.item.json;
const confirmedAppts = prev.active_confirmed_appts || [];
let target = null;
let errorMsg = "No active appointment was found.";

if (confirmedAppts.length === 0) {
  if (prev.active_pending) {
    target = prev.active_pending;
  }
} else if (confirmedAppts.length === 1) {
  target = confirmedAppts[0];
} else {
  let matches = confirmedAppts;
  if (prev.doctor_id) matches = matches.filter(a => a.doctor_id === prev.doctor_id);
  
  if (matches.length === 1) {
    target = matches[0];
  } else {
    const tz = prev.clinic_timezone || 'Asia/Kolkata';
    let listStr = matches.map((a, i) => {
      const dt = new Intl.DateTimeFormat('en-US', { timeZone: tz, month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'}).format(new Date(a.start_time));
      return `${i+1}. ${a.doctor_name || a.doctor_id} \u2014 ${dt} (${a.service})`;
    }).join('\\n');
    return [{
      json: {
        ...prev,
        has_cancel_target: false,
        error_msg: `You have multiple upcoming appointments:\\n\\n${listStr}\\n\\nWhich appointment would you like to cancel? Please specify the doctor's name, date, or time.`
      }
    }];
  }
}

if (!target) {
  return [{
    json: {
      ...prev,
      has_cancel_target: false,
      error_msg: errorMsg
    }
  }];
}

const doc = prev.active_doctors?.find(d => d.doctor_id === target.doctor_id) || prev.doctor || {};
return [{
  json: {
    ...prev,
    has_cancel_target: true,
    appointment_id: target.appointment_id,
    calendar_id: target.calendar_id || doc.calendar_id,
    calendar_event_id: target.calendar_event_id,
    cancel_start_time: target.start_time
  }
}];
"""

    if node['name'] == 'Validate_Reschedule_Request':
        node['parameters']['jsCode'] = """
function getUtcFromLocal(dateStr, timeStr, timeZone) {
  const [yyyy, mm, dd] = dateStr.split('-').map(Number);
  const [hh, min] = timeStr.split(':').map(Number);
  const testUtc = new Date(Date.UTC(yyyy, mm - 1, dd, hh, min, 0));
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false
  });
  const parts = dtf.formatToParts(testUtc);
  const p = {};
  for (const part of parts) p[part.type] = part.value;
  let partHour = parseInt(p.hour, 10);
  if (partHour === 24) partHour = 0;
  const formattedAsUtc = Date.UTC(parseInt(p.year, 10), parseInt(p.month, 10) - 1, parseInt(p.day, 10), partHour, parseInt(p.minute, 10), parseInt(p.second, 10));
  const offset = formattedAsUtc - testUtc.getTime();
  return new Date(testUtc.getTime() - offset);
}

function getWeekdayFromDate(dateObj, timeZone) {
  const dayStr = new Intl.DateTimeFormat('en-US', { timeZone, weekday: 'short' }).format(dateObj);
  const map = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return map[dayStr];
}

function formatInTimezone(dateObj, timeZone, options) {
  return new Intl.DateTimeFormat('en-US', { timeZone, ...options }).format(dateObj);
}

function isValidDate(dateStr) {
  if (!dateStr || typeof dateStr !== 'string') return false;
  const match = dateStr.match(/^(\\d{4})-(\\d{2})-(\\d{2})$/);
  if (!match) return false;
  const y = Number(match[1]), m = Number(match[2]), d = Number(match[3]);
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  const testDate = new Date(Date.UTC(y, m - 1, d));
  return testDate.getUTCFullYear() === y && testDate.getUTCMonth() === (m - 1) && testDate.getUTCDate() === d;
}

function isValidTime(timeStr) {
  if (!timeStr || typeof timeStr !== 'string') return false;
  return /^([01]\\d|2[0-3]):([0-5]\\d)$/.test(timeStr);
}

const prev = $input.item.json;
const confirmedAppts = prev.active_confirmed_appts || [];
let active = null;
let errorMsg = "No active appointment was found.";

if (confirmedAppts.length === 0) {
  return [{ json: { ...prev, can_reschedule: false, error_msg: errorMsg } }];
} else if (confirmedAppts.length === 1) {
  active = confirmedAppts[0];
} else {
  let matches = confirmedAppts;
  if (prev.doctor_id) matches = matches.filter(a => a.doctor_id === prev.doctor_id);
  if (matches.length === 1) {
    active = matches[0];
  } else {
    const tz = prev.clinic_timezone || 'Asia/Kolkata';
    let listStr = matches.map((a, i) => {
      const dt = new Intl.DateTimeFormat('en-US', { timeZone: tz, month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit'}).format(new Date(a.start_time));
      return `${i+1}. ${a.doctor_name || a.doctor_id} \u2014 ${dt} (${a.service})`;
    }).join('\\n');
    return [{
      json: {
        ...prev,
        can_reschedule: false,
        error_msg: `You have multiple upcoming appointments:\\n\\n${listStr}\\n\\nWhich appointment would you like to reschedule? Please specify the doctor's name, date, or time.`
      }
    }];
  }
}

const doc = prev.active_doctors?.find(d => d.doctor_id === active.doctor_id) || prev.doctor || {};
const tz = doc.timezone || 'Asia/Kolkata';
const wh = doc.working_hours || { start: "09:00", end: "17:00" };
const workingDays = doc.working_days || [1, 2, 3, 4, 5, 6];
const existingDuration = active?.slot_duration_minutes || (active?.start_time && active?.end_time ? Math.round((new Date(active.end_time).getTime() - new Date(active.start_time).getTime()) / 60000) : null);
const slotDuration = existingDuration || doc.slot_duration_minutes || 30;
const cutoffMin = doc.booking_cutoff_minutes || 60;
const unavailList = prev.active_unavailability || [];

if (!isValidDate(prev.requested_date) || !isValidTime(prev.requested_time)) {
  const currentStart = formatInTimezone(new Date(active.start_time), tz, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  return [{
    json: {
      ...prev,
      can_reschedule: false,
      error_msg: `Your current appointment (#${active.appointment_id}) is scheduled for ${currentStart}.\\n\\nPlease reply with your new requested date (YYYY-MM-DD) and time (e.g. 'Reschedule to 2026-09-09 at 14:00').`
    }
  }];
}

const newStartUtc = getUtcFromLocal(prev.requested_date, prev.requested_time, tz);
const newEndUtc = new Date(newStartUtc.getTime() + slotDuration * 60000);

let canResched = true;

const localDayOfWeek = getWeekdayFromDate(newStartUtc, tz);
if (!workingDays.includes(localDayOfWeek)) {
  canResched = false;
  errorMsg = `Sorry, ${doc.doctor_name || 'the doctor'} is closed on that day.`;
} else {
  const [startH, startM] = wh.start.split(':').map(Number);
  const [endH, endM] = wh.end.split(':').map(Number);
  const [reqH, reqM] = prev.requested_time.split(':').map(Number);
  const reqMin = reqH * 60 + reqM;
  if (reqMin < startH * 60 + startM || reqMin + slotDuration > endH * 60 + endM) {
    canResched = false;
    errorMsg = `Operating hours are ${wh.start} to ${wh.end}. The requested time is outside working hours.`;
  }
}

const now = new Date();
if (newStartUtc.getTime() < now.getTime() + cutoffMin * 60000) {
  canResched = false;
  errorMsg = `Rescheduling must be done at least ${cutoffMin} minutes in advance.`;
}

for (const u of unavailList) {
  if (u.doctor_id === doc.doctor_id) {
    const uStart = new Date(u.start_time);
    const uEnd = new Date(u.end_time);
    if (newStartUtc < uEnd && newEndUtc > uStart) {
      canResched = false;
      errorMsg = `Doctor is unavailable on that date (${u.reason || 'Leave'}).`;
      break;
    }
  }
}

return [{
  json: {
    ...prev,
    can_reschedule: canResched,
    error_msg: canResched ? '' : errorMsg,
    appointment_id: active.appointment_id,
    calendar_event_id: active.calendar_event_id,
    calendar_id: doc.calendar_id || active.calendar_id,
    slot_duration_minutes: slotDuration,
    old_start_iso: active.start_time,
    old_end_iso: active.end_time,
    new_start_iso: newStartUtc.toISOString(),
    new_end_iso: newEndUtc.toISOString()
  }
}];
"""

with open('01_WhatsApp_AI_Appointment_Agent.json', 'w') as f:
    json.dump(wf, f, indent=2)

