#!/usr/bin/python3

print("Ready to listen to stdin")

while True:
    data = input()
    items = set(data.split(','))

    print(f"{len(items)} unique services were received!")
    for item in items:
        if item.startswith("mic:"):
            print("Microphone is active")
            break
