#!/usr/bin/python3

HOMEASSISTANT_BASE_URL = "http://homeassistant.local:8123"
TOKEN = ""
ENTITY_ID = "light.on_air_light"

import urllib.request
import json

def mediaEvent(state: bool):
    try:
        method = 'on' if state else 'off'
        url = f"{HOMEASSISTANT_BASE_URL}/api/services/light/turn_{method}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}, data=json.dumps({"entity_id": ENTITY_ID}).encode("utf-8"))
        urllib.request.urlopen(req)
    except:
        print("Failed to send event to Home Assistant")

###

print("Reading stdin for events")

while True:
    data = input()
    items = set(data.split(','))

    isMediaActive = False
    for item in items:
        if item.startswith("cam:") or item.startswith("mic:"):
            isMediaActive = True
            break
    
    if isMediaActive:
        print("Media is active")
    else:
        print("Media is not active")

    mediaEvent(isMediaActive)