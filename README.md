# macOS Media Log Stream

A wrapper over the `/usr/bin/log` binary to aid in monitoring application use of the Camera, Microphone, Screen Capture and Location services.  

---

## Suppressing output

Operational messages are output via `stderr`, so they can be silenced or redirected

e.g. `./mediaLogStream 2>/dev/null`

```plain
2024-11-20 13:04:25.456161+1100,newService,screen:quicktime
2024-11-20 13:04:33.012697+1100,newService,mic:Audacity
2024-11-20 13:04:36.617592+1100,expiredService,mic:Audacity
2024-11-20 13:04:43.403033+1100,newService,cam:com.apple.PhotoBooth
2024-11-20 13:04:46.957168+1100,newService,cam:com.raycast.macos
2024-11-20 13:04:48.328433+1100,expiredService,cam:com.raycast.macos
2024-11-20 13:04:51.152805+1100,expiredService,cam:com.apple.PhotoBooth
2024-11-20 13:04:54.595291+1100,expiredService,screen:quicktime
```

---

## Callbacks

A callback program can be supplied to respond to changes in active services.  
This program should read in a line of comma-separated services from `stdin`.

There is no guarantee to the order of these services, and there may exist duplicates.

All output from the callback program is routed to `stderr`.

e.g. `./mediaLogStream "loc:System Services" -- ./callbacks/sample.py`

```plain
--------------------
Ignoring loc:System Services
Callback process starting: { ./callbacks/sample.py }
Observing events...
Ready to listen to stdin
2024-11-20 13:00:36.486785+1100,newService,cam:com.raycast.macos
1 unique services were received!
2024-11-20 13:00:40.512952+1100,newService,screen:com.lwouis.alt-tab-macos
2 unique services were received!
2024-11-20 13:00:40.922329+1100,expiredService,cam:com.raycast.macos
1 unique services were received!
2024-11-20 13:00:44.404867+1100,newService,cam:com.apple.PhotoBooth
2 unique services were received!
```
