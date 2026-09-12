import json
with open('01_WhatsApp_AI_Appointment_Agent.json', 'r') as f:
    wf = json.load(f)

c = wf['connections']
if 'If_Reschedule_DB_Success' in c:
    while len(c['If_Reschedule_DB_Success']['main']) < 2:
        c['If_Reschedule_DB_Success']['main'].append([])
    c['If_Reschedule_DB_Success']['main'][1].append({"node": "Send_WhatsApp_DB_Error", "type": "main", "index": 0})

with open('01_WhatsApp_AI_Appointment_Agent.json', 'w') as f:
    json.dump(wf, f, indent=2)
