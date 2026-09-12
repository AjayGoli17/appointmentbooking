import json

with open('01_WhatsApp_AI_Appointment_Agent.json', 'r') as f:
    wf = json.load(f)

# Add Send_WhatsApp_GCal_Error
new_node = {
  "id": "w1-send-gcal-error",
  "name": "Send_WhatsApp_GCal_Error",
  "type": "n8n-nodes-base.httpRequest",
  "typeVersion": 4.2,
  "position": [3900, 1100],
  "parameters": {
    "method": "POST",
    "url": "https://graph.facebook.com/v20.0/{{ $env.WHATSAPP_PHONE_NUMBER_ID || 'FROM_PHONE_NUMBER_ID' }}/messages",
    "authentication": "genericCredentialType",
    "genericAuthType": "httpHeaderAuth",
    "sendHeaders": True,
    "headerParameters": {
      "parameters": [
        {
          "name": "Content-Type",
          "value": "application/json"
        }
      ]
    },
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": "={{\n{\n  \"messaging_product\": \"whatsapp\",\n  \"recipient_type\": \"individual\",\n  \"to\": $json.phone,\n  \"type\": \"text\",\n  \"text\": {\n    \"preview_url\": false,\n    \"body\": $json.error_msg || \"We are temporarily unable to verify calendar availability. Please try again in a moment.\"\n  }\n}\n}}"
  },
  "credentials": {
    "httpHeaderAuth": {
      "id": "whatsapp_cloud_api_credentials",
      "name": "WhatsApp Cloud API Auth"
    }
  },
  "continueOnFail": True
}

wf['nodes'].append(new_node)

c = wf['connections']

# Hook up If_GCal_Check_Failed (Output 0 -> Send_WhatsApp_GCal_Error)
if 'If_GCal_Check_Failed' not in c:
    c['If_GCal_Check_Failed'] = {'main': [[], []]}
while len(c['If_GCal_Check_Failed']['main']) < 2:
    c['If_GCal_Check_Failed']['main'].append([])
c['If_GCal_Check_Failed']['main'][0].append({"node": "Send_WhatsApp_GCal_Error", "type": "main", "index": 0})

# Hook up If_Reschedule_GCal_Failed (Output 0 -> Send_WhatsApp_GCal_Error)
if 'If_Reschedule_GCal_Failed' not in c:
    c['If_Reschedule_GCal_Failed'] = {'main': [[], []]}
while len(c['If_Reschedule_GCal_Failed']['main']) < 2:
    c['If_Reschedule_GCal_Failed']['main'].append([])
c['If_Reschedule_GCal_Failed']['main'][0].append({"node": "Send_WhatsApp_GCal_Error", "type": "main", "index": 0})

# And Send_WhatsApp_GCal_Error -> Respond_GCal_Error
c['Send_WhatsApp_GCal_Error'] = {'main': [[{"node": "Respond_GCal_Error", "type": "main", "index": 0}]]}

with open('01_WhatsApp_AI_Appointment_Agent.json', 'w') as f:
    json.dump(wf, f, indent=2)

